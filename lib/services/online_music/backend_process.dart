import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/online_music/backend_client.dart';

enum OnlineBackendState { disabled, stopped, starting, ready, failed }

// 拉起并守护随播放器运行的在线音源后端（Node.js）。
class OnlineBackendProcess {
  OnlineBackendProcess._();

  static final OnlineBackendProcess instance = OnlineBackendProcess._();

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Future<bool>? _starting;
  bool _external = false;
  final StringBuffer _logTail = StringBuffer();

  OnlineBackendState state = OnlineBackendState.stopped;
  String? lastError;

  final ValueNotifier<OnlineBackendState> stateNotifier =
      ValueNotifier<OnlineBackendState>(OnlineBackendState.stopped);

  bool get isRunning => state == OnlineBackendState.ready;

  // 当前后端不是本进程拉起的（用户手动运行），停止时不去结束别人的进程。
  bool get isExternal => _external;

  String get baseUrl => OnlineBackendClient.normalizeBaseUrl(AppSettings.instance.onlineMusicBaseUrl);

  String get logTail {
    final text = _logTail.toString();
    return text.length > 1600 ? text.substring(text.length - 1600) : text;
  }

  void _setState(OnlineBackendState next, {String? error}) {
    state = next;
    lastError = error;
    stateNotifier.value = next;
  }

  Future<bool> ensureStarted({bool restart = false}) async {
    if (!AppSettings.instance.onlineMusicEnabled) {
      _setState(OnlineBackendState.disabled);
      return false;
    }
    if (restart) await stop();
    if (state == OnlineBackendState.ready) return true;
    final pending = _starting;
    if (pending != null) return pending;
    final future = _start();
    _starting = future;
    try {
      return await future;
    } finally {
      _starting = null;
    }
  }

  Future<bool> _start() async {
    _setState(OnlineBackendState.starting);
    final client = OnlineBackendClient(
      baseUrl: baseUrl,
      apiToken: AppSettings.instance.onlineMusicToken,
    );
    // 端口上已有同款后端（例如用户手动启动）时直接复用，避免端口冲突。
    if (await _ping(client)) {
      _external = true;
      _setState(OnlineBackendState.ready);
      return true;
    }
    final backendDir = resolveBackendDir();
    if (backendDir == null) {
      _setState(OnlineBackendState.failed, error: '未找到在线音源后端目录（backend/server.js），请在设置里指定');
      return false;
    }
    final serverEntry = File('${backendDir.path}${Platform.pathSeparator}server.js');
    if (!await serverEntry.exists()) {
      _setState(OnlineBackendState.failed, error: '后端目录缺少 server.js：${backendDir.path}');
      return false;
    }
    final node = resolveNodePath();
    if (node == null) {
      _setState(OnlineBackendState.failed, error: '未找到 Node.js，请安装 Node.js 22+ 或指定 node.exe 路径');
      return false;
    }
    if (!await _dependenciesReady(backendDir)) {
      final installed = await installDependencies(backendDir: backendDir);
      if (!installed) {
        _setState(
          OnlineBackendState.failed,
          error: '后端依赖未安装。请到设置里点“安装依赖”，或在 backend 目录执行 npm install',
        );
        return false;
      }
    }
    final uri = Uri.parse(baseUrl);
    final port = uri.hasPort ? uri.port : 3000;
    final cookieFile = await _cookieFile();
    try {
      final process = await Process.start(
        node,
        ['server.js'],
        workingDirectory: backendDir.path,
        environment: <String, String>{
          ...Platform.environment,
          'PORT': '$port',
          'HOST': '127.0.0.1',
          'COOKIE_FILE': cookieFile,
          'LOG_REQUESTS': 'false',
          if (AppSettings.instance.onlineMusicToken.trim().isNotEmpty)
            'API_TOKEN': AppSettings.instance.onlineMusicToken.trim(),
        },
        mode: ProcessStartMode.detachedWithStdio,
      );
      _process = process;
      _external = false;
      _attachLogs(process);
      unawaited(process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          if (state != OnlineBackendState.stopped) {
            _setState(
              OnlineBackendState.failed,
              error: code == 0 ? '在线音源后端已退出' : '在线音源后端异常退出（code $code）',
            );
          }
        }
      }));
    } catch (error) {
      _process = null;
      _setState(OnlineBackendState.failed, error: '启动在线音源后端失败：$error');
      return false;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (await _ping(client)) {
        _setState(OnlineBackendState.ready);
        return true;
      }
      if (_process == null && state == OnlineBackendState.failed) return false;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    _setState(OnlineBackendState.failed, error: '在线音源后端启动超时。${logTail.isEmpty ? '' : '\n$logTail'}');
    return false;
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    if (process != null) {
      try {
        process.kill();
      } catch (_) {}
    }
    _external = false;
    _logTail.clear();
    _setState(OnlineBackendState.stopped);
  }

  // 设置里的地址/端口/token 改变后需要按新配置重启。
  Future<bool> restart() => ensureStarted(restart: true);

  Future<bool> installDependencies({Directory? backendDir}) async {
    final dir = backendDir ?? resolveBackendDir();
    if (dir == null) return false;
    final npm = await resolveNpmPath();
    if (npm == null) return false;
    _setState(OnlineBackendState.starting);
    try {
      final result = await Process.run(
        npm,
        ['install', '--omit=dev', '--no-audit', '--no-fund'],
        workingDirectory: dir.path,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(minutes: 5));
      if (result.exitCode == 0) {
        _setState(OnlineBackendState.stopped);
        return true;
      }
      _setState(OnlineBackendState.failed, error: '安装后端依赖失败：${result.stderr}');
      return false;
    } catch (error) {
      _setState(OnlineBackendState.failed, error: '安装后端依赖失败：$error');
      return false;
    }
  }

  Directory? resolveBackendDir() {
    final configured = AppSettings.instance.onlineMusicBackendDir?.trim();
    if (configured != null && configured.isNotEmpty) {
      final dir = Directory(configured);
      if (dir.existsSync()) return dir;
    }
    final candidates = <String>[];
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.addAll([
      '$exeDir${Platform.pathSeparator}backend',
      '$exeDir${Platform.pathSeparator}..${Platform.pathSeparator}backend',
      '${Directory.current.path}${Platform.pathSeparator}backend',
    ]);
    // 构建产物在 build/ 深层目录时，向上找仓库根的 backend。
    final anchors = [exeDir, Directory.current.path];
    for (final anchor in anchors) {
      var dir = Directory(anchor);
      for (var depth = 0; depth < 6; depth += 1) {
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
        candidates.add('${dir.path}${Platform.pathSeparator}backend');
      }
    }
    for (final candidate in candidates) {
      final dir = Directory(candidate);
      if (File('${dir.path}${Platform.pathSeparator}server.js').existsSync()) {
        try {
          return dir.absolute;
        } catch (_) {
          return dir;
        }
      }
    }
    return null;
  }

  String? resolveNodePath() {
    final configured = AppSettings.instance.onlineMusicNodePath?.trim();
    if (configured != null && configured.isNotEmpty && File(configured).existsSync()) {
      return configured;
    }
    for (final candidate in _nodeCandidates()) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  Future<String?> resolveNpmPath() async {
    final node = resolveNodePath();
    if (node == null) return null;
    final nodeDir = File(node).parent.path;
    for (final name in ['npm.cmd', 'npm.exe', 'npm']) {
      final candidate = '$nodeDir${Platform.pathSeparator}$name';
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  List<String> _nodeCandidates() {
    final env = Platform.environment;
    final dirs = <String>[
      if (env['ProgramFiles'] != null) '${env['ProgramFiles']}${Platform.pathSeparator}nodejs',
      if (env['ProgramFiles(x86)'] != null) '${env['ProgramFiles(x86)']}${Platform.pathSeparator}nodejs',
      if (env['LOCALAPPDATA'] != null)
        '${env['LOCALAPPDATA']}${Platform.pathSeparator}Programs${Platform.pathSeparator}nodejs',
      if (env['NVM_SYMLINK'] != null) env['NVM_SYMLINK']!,
    ];
    return [
      for (final dir in dirs) '$dir${Platform.pathSeparator}node.exe',
      'node.exe',
      'node',
    ];
  }

  Future<Directory> _cacheDir() async {
    final appData = await getAppDataDir();
    final dir = Directory('${appData.path}${Platform.pathSeparator}online_music');
    await dir.create(recursive: true);
    return dir;
  }

  Future<String> _cookieFile() async {
    final dir = await _cacheDir();
    return '${dir.path}${Platform.pathSeparator}netease.cookie';
  }

  Future<Directory> audioCacheDir() async {
    final dir = Directory('${(await _cacheDir()).path}${Platform.pathSeparator}audio');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> coverCacheDir() async {
    final dir = Directory('${(await _cacheDir()).path}${Platform.pathSeparator}cover');
    await dir.create(recursive: true);
    return dir;
  }

  Future<bool> _dependenciesReady(Directory backendDir) async {
    final modules = Directory('${backendDir.path}${Platform.pathSeparator}node_modules');
    return modules.existsSync() &&
        Directory('${modules.path}${Platform.pathSeparator}express').existsSync();
  }

  Future<bool> _ping(OnlineBackendClient client) async {
    try {
      final data = await client.health().timeout(const Duration(seconds: 2));
      return data['status'] == 'ok' || data['ok'] == true || data.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _attachLogs(Process process) {
    void append(String line) {
      _logTail.write(line);
      if (_logTail.length > 4000) {
        final text = _logTail.toString();
        _logTail
          ..clear()
          ..write(text.substring(text.length - 2000));
      }
    }

    _stdoutSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(append, onError: (_) {});
    _stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(append, onError: (_) {});
  }
}

// 避免在非 Flutter 环境（脚本）里依赖 foundation 的 ValueNotifier。
class ValueNotifierCompat<T> {
  ValueNotifierCompat(this._value);

  T _value;
  final List<void Function()> _listeners = [];

  T get value => _value;

  set value(T next) {
    if (next == _value) return;
    _value = next;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);
}
