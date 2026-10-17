import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/settings_page/tabs/settings_section_header.dart';
import 'package:pure_music/services/online_music/backend_client.dart';
import 'package:pure_music/services/online_music/backend_process.dart';
import 'package:pure_music/services/online_music/models.dart';
import 'package:pure_music/services/online_music/online_audio_cache.dart';
import 'package:pure_music/services/online_music/online_music_service.dart';

// 在线音源设置：后端进程、连接参数与缓存管理。
class OnlineSourceSettingsPanel extends StatefulWidget {
  const OnlineSourceSettingsPanel({super.key});

  @override
  State<OnlineSourceSettingsPanel> createState() =>
      _OnlineSourceSettingsPanelState();
}

class _OnlineSourceSettingsPanelState extends State<OnlineSourceSettingsPanel> {
  final _baseUrlController = TextEditingController();
  final _tokenController = TextEditingController();
  final _nodePathController = TextEditingController();
  final _backendDirController = TextEditingController();

  late final Timer _logTimer;
  String? _runningAction;
  bool _togglingEnabled = false;
  bool _tokenVisible = false;
  int? _cacheBytes;
  bool _cacheLoading = false;
  bool _cacheClearing = false;
  String? _cacheError;

  OnlineBackendProcess get _process => OnlineBackendProcess.instance;

  bool get _busy => _runningAction != null || _togglingEnabled;

  @override
  void initState() {
    super.initState();
    final settings = AppSettings.instance;
    _baseUrlController.text = settings.onlineMusicBaseUrl;
    _tokenController.text = settings.onlineMusicToken;
    _nodePathController.text = settings.onlineMusicNodePath ?? '';
    _backendDirController.text = settings.onlineMusicBackendDir ?? '';
    _cacheLoading = true;
    unawaited(_loadCacheSize());
    _logTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final state = _process.state;
      if (state == OnlineBackendState.starting ||
          state == OnlineBackendState.ready) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _logTimer.cancel();
    _baseUrlController.dispose();
    _tokenController.dispose();
    _nodePathController.dispose();
    _backendDirController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<OnlineBackendState>(
      valueListenable: _process.stateNotifier,
      builder: (context, state, _) {
        final scheme = Theme.of(context).colorScheme;
        final settings = AppSettings.instance;
        final fieldsEnabled = !_togglingEnabled;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state != OnlineBackendState.ready) ...[
              _setupHintCard(scheme),
              const SizedBox(height: Spacing.lg),
            ],
            const SettingsSectionHeader('连接'),
            const SizedBox(height: Spacing.xs),
            SettingsTile(
              description: '启用在线音源',
              subtitle: '在线搜索、播放与会员音质',
              action: Switch(
                value: settings.onlineMusicEnabled,
                onChanged: _togglingEnabled ? null : _setEnabled,
              ),
            ),
            const SizedBox(height: Spacing.lg),
            _statusCard(context, state),
            const SizedBox(height: Spacing.lg),
            _OnlineTextField(
              label: '后端地址',
              subtitle: '默认 http://127.0.0.1:3000，改后需重启后端',
              controller: _baseUrlController,
              enabled: fieldsEnabled,
              obscure: false,
              onFocusChange: (focused) {
                if (!focused) unawaited(_commitBaseUrl());
              },
            ),
            const SizedBox(height: Spacing.lg),
            _OnlineTextField(
              label: 'API Token',
              subtitle: '后端设置 API_TOKEN 时必填，否则留空',
              controller: _tokenController,
              enabled: fieldsEnabled,
              obscure: !_tokenVisible,
              suffixIcon: IconButton(
                onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _tokenVisible ? Icons.visibility_off : Icons.visibility,
                ),
              ),
              onFocusChange: (focused) {
                if (!focused) unawaited(_commitToken());
              },
            ),
            const SizedBox(height: Spacing.xl),
            const SettingsSectionHeader('播放与缓存'),
            const SizedBox(height: Spacing.xs),
            SettingsTile(
              description: '在线音质',
              subtitle: '实际以平台可用音质为准，会自动回退',
              action: SizedBox(
                width: 200.0,
                child: DropdownButtonFormField<OnlineAudioQuality>(
                  initialValue: settings.onlineMusicQuality,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final quality in OnlineAudioQuality.values)
                      DropdownMenuItem<OnlineAudioQuality>(
                        value: quality,
                        child: Text(quality.label),
                      ),
                  ],
                  onChanged: _busy ? null : _setQuality,
                ),
              ),
            ),
            const SizedBox(height: Spacing.lg),
            SettingsTile(
              description: '保留缓存',
              subtitle: '关闭后不长期保留在线音频缓存',
              action: Switch(
                value: settings.onlineMusicKeepCache,
                onChanged: _setKeepCache,
              ),
            ),
            const SizedBox(height: Spacing.lg),
            SettingsTile(
              description: '缓存管理',
              subtitle: _cacheSubtitle(),
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '刷新缓存大小',
                    onPressed: _cacheLoading || _cacheClearing
                        ? null
                        : _refreshCacheSize,
                    iconSize: 20,
                    icon: const Icon(Icons.refresh),
                  ),
                  const SizedBox(width: Spacing.xs),
                  OutlinedButton(
                    onPressed: _cacheClearing ? null : _clearCache,
                    child: _cacheClearing
                        ? const SizedBox(
                            width: 16.0,
                            height: 16.0,
                            child: CircularProgressIndicator(strokeWidth: 2.0),
                          )
                        : const Text('清理缓存'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.xl),
            const SettingsSectionHeader('运行环境'),
            const SizedBox(height: Spacing.xs),
            _OnlineTextField(
              label: 'Node.js 路径',
              subtitle: _nodePathSubtitle(),
              controller: _nodePathController,
              enabled: fieldsEnabled,
              obscure: false,
              onFocusChange: (focused) {
                if (!focused) unawaited(_commitNodePath());
              },
            ),
            const SizedBox(height: Spacing.lg),
            _OnlineTextField(
              label: '后端目录',
              subtitle: _backendDirSubtitle(),
              controller: _backendDirController,
              enabled: fieldsEnabled,
              obscure: false,
              onFocusChange: (focused) {
                if (!focused) unawaited(_commitBackendDir());
              },
            ),
          ],
        );
      },
    );
  }

  Widget _setupHintCard(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.smCircular,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              '首次使用需要 Node.js 22+ 与后端依赖（npm install），点“安装依赖”可自动处理。',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(BuildContext context, OnlineBackendState state) {
    final scheme = Theme.of(context).colorScheme;
    final error = _process.lastError?.trim() ?? '';
    final log = _process.logTail.trim();
    return Container(
      padding: const EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.mdCircular,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8.0,
                height: 8.0,
                decoration: BoxDecoration(
                  color: _stateColor(scheme, state),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                '后端状态：${_stateLabel(state)}',
                style: TextStyle(
                  fontSize: AppType.subtitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                _process.isRunning ? '进程运行中' : '进程未运行',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            '后端地址：${_process.baseUrl}',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              error,
              style: TextStyle(fontSize: AppType.caption, color: scheme.error),
            ),
          ],
          const SizedBox(height: Spacing.md),
          Text(
            '运行日志',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Container(
            height: 120.0,
            width: double.infinity,
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: AppRadius.smCircular,
            ),
            child: log.isEmpty
                ? Text(
                    '暂无日志',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                : SingleChildScrollView(
                    child: SelectableText(
                      log,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontFamily: 'monospace',
                        height: 1.35,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              _cardButton(
                '启动',
                filled: true,
                loading: _runningAction == 'start',
                onPressed:
                    AppSettings.instance.onlineMusicEnabled &&
                        !_busy &&
                        state != OnlineBackendState.ready &&
                        state != OnlineBackendState.starting
                    ? _startBackend
                    : null,
              ),
              _cardButton(
                '停止',
                loading: _runningAction == 'stop',
                onPressed:
                    !_busy &&
                        (state == OnlineBackendState.ready ||
                            state == OnlineBackendState.starting ||
                            state == OnlineBackendState.failed)
                    ? _stopBackend
                    : null,
              ),
              _cardButton(
                '重启',
                loading: _runningAction == 'restart',
                onPressed: AppSettings.instance.onlineMusicEnabled && !_busy
                    ? _restartBackend
                    : null,
              ),
              _cardButton(
                '安装依赖',
                loading: _runningAction == 'install',
                onPressed: _busy ? null : _installDependencies,
              ),
              _cardButton(
                '检查连接',
                loading: _runningAction == 'check',
                onPressed: AppSettings.instance.onlineMusicEnabled && !_busy
                    ? _checkConnection
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cardButton(
    String label, {
    VoidCallback? onPressed,
    bool loading = false,
    bool filled = false,
  }) {
    final child = loading
        ? const SizedBox(
            width: 16.0,
            height: 16.0,
            child: CircularProgressIndicator(strokeWidth: 2.0),
          )
        : Text(label);
    if (filled) {
      return FilledButton(onPressed: onPressed, child: child);
    }
    return OutlinedButton(onPressed: onPressed, child: child);
  }

  String _stateLabel(OnlineBackendState state) => switch (state) {
    OnlineBackendState.disabled => '已禁用',
    OnlineBackendState.stopped => '已停止',
    OnlineBackendState.starting => '启动中',
    OnlineBackendState.ready => '运行中',
    OnlineBackendState.failed => '失败',
  };

  Color _stateColor(ColorScheme scheme, OnlineBackendState state) =>
      switch (state) {
        OnlineBackendState.ready => scheme.primary,
        OnlineBackendState.starting => scheme.tertiary,
        OnlineBackendState.failed => scheme.error,
        OnlineBackendState.stopped || OnlineBackendState.disabled =>
          scheme.outline,
      };

  String _nodePathSubtitle() {
    final resolved = _process.resolveNodePath();
    if (resolved == null) return '留空自动检测，当前未找到 node.exe';
    return '留空自动检测，当前使用：$resolved';
  }

  String _backendDirSubtitle() {
    final resolved = _process.resolveBackendDir();
    if (resolved == null) return '留空自动查找 exe 同级 backend，当前未找到';
    return '留空自动查找，当前使用：${resolved.path}';
  }

  String _cacheSubtitle() {
    if (_cacheError != null) return _cacheError!;
    final bytes = _cacheBytes;
    if (bytes == null) return '在线音频缓存：读取中';
    return '在线音频缓存：${_formatBytes(bytes)}';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    const double mb = 1024 * 1024;
    const double gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }

  Future<void> _setEnabled(bool value) async {
    if (_togglingEnabled) return;
    setState(() {
      _togglingEnabled = true;
      AppSettings.instance.onlineMusicEnabled = value;
    });
    await AppSettings.instance.saveSettings();
    try {
      if (value) {
        final ok = await _process.ensureStarted();
        if (ok) {
          await OnlineMusicService.instance.refreshAuth();
        } else if (_process.lastError != null) {
          showTextOnSnackBar(
            _process.lastError!,
            variant: ToastVariant.error,
          );
        }
      } else {
        await _process.stop();
      }
    } finally {
      if (mounted) setState(() => _togglingEnabled = false);
    }
  }

  Future<void> _setQuality(OnlineAudioQuality? value) async {
    if (value == null) return;
    setState(() => AppSettings.instance.onlineMusicQuality = value);
    await AppSettings.instance.saveSettings();
  }

  Future<void> _setKeepCache(bool value) async {
    setState(() => AppSettings.instance.onlineMusicKeepCache = value);
    await AppSettings.instance.saveSettings();
  }

  Future<void> _commitBaseUrl() async {
    final raw = _baseUrlController.text.trim();
    final uri = Uri.tryParse(raw);
    final valid =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    if (!valid) {
      _baseUrlController.text = AppSettings.instance.onlineMusicBaseUrl;
      showTextOnSnackBar(
        '后端地址需以 http:// 或 https:// 开头',
        variant: ToastVariant.error,
      );
      return;
    }
    if (raw == AppSettings.instance.onlineMusicBaseUrl) return;
    AppSettings.instance.onlineMusicBaseUrl = raw;
    await AppSettings.instance.saveSettings();
    OnlineMusicService.instance.resetClient();
    showTextOnSnackBar('已保存，重启后端后生效');
  }

  Future<void> _commitToken() async {
    final raw = _tokenController.text.trim();
    if (raw == AppSettings.instance.onlineMusicToken) return;
    AppSettings.instance.onlineMusicToken = raw;
    await AppSettings.instance.saveSettings();
    OnlineMusicService.instance.resetClient();
    showTextOnSnackBar('已保存，重启后端后生效');
  }

  Future<void> _commitNodePath() async {
    final raw = _nodePathController.text.trim();
    final next = raw.isEmpty ? null : raw;
    if (next == AppSettings.instance.onlineMusicNodePath) return;
    AppSettings.instance.onlineMusicNodePath = next;
    await AppSettings.instance.saveSettings();
    if (mounted) setState(() {});
  }

  Future<void> _commitBackendDir() async {
    final raw = _backendDirController.text.trim();
    final next = raw.isEmpty ? null : raw;
    if (next == AppSettings.instance.onlineMusicBackendDir) return;
    AppSettings.instance.onlineMusicBackendDir = next;
    await AppSettings.instance.saveSettings();
    if (mounted) setState(() {});
  }

  Future<void> _run(
    String action,
    Future<void> Function() task, {
    String? successMessage,
  }) async {
    if (_busy) return;
    setState(() => _runningAction = action);
    try {
      await task();
      if (successMessage != null) {
        showTextOnSnackBar(successMessage, variant: ToastVariant.success);
      }
    } catch (error) {
      showTextOnSnackBar(
        error is OnlineApiException ? error.message : '操作失败：$error',
        variant: ToastVariant.error,
      );
    } finally {
      if (mounted) setState(() => _runningAction = null);
    }
  }

  Future<void> _startBackend() => _run('start', () async {
    final ok = await _process.ensureStarted();
    if (!ok) {
      throw OnlineApiException(
        statusCode: 0,
        code: 'BACKEND_UNAVAILABLE',
        message: _process.lastError ?? '在线音源后端启动失败',
      );
    }
    await OnlineMusicService.instance.refreshAuth();
  }, successMessage: '在线音源后端已启动');

  Future<void> _stopBackend() => _run(
    'stop',
    _process.stop,
    successMessage: '在线音源后端已停止',
  );

  Future<void> _restartBackend() => _run('restart', () async {
    OnlineMusicService.instance.resetClient();
    final ok = await _process.restart();
    if (!ok) {
      throw OnlineApiException(
        statusCode: 0,
        code: 'BACKEND_UNAVAILABLE',
        message: _process.lastError ?? '在线音源后端重启失败',
      );
    }
    await OnlineMusicService.instance.refreshAuth();
  }, successMessage: '在线音源后端已重启');

  Future<void> _installDependencies() {
    final backendDir = _process.resolveBackendDir();
    if (backendDir == null) {
      showTextOnSnackBar(
        '未找到后端目录，请先在下方指定',
        variant: ToastVariant.error,
      );
      return Future<void>.value();
    }
    return _run('install', () async {
      final ok = await _process.installDependencies(backendDir: backendDir);
      if (!ok) {
        throw OnlineApiException(
          statusCode: 0,
          code: 'INSTALL_FAILED',
          message: _process.lastError ?? '安装依赖失败，请检查 Node.js 路径',
        );
      }
    }, successMessage: '后端依赖安装完成，可以启动后端了');
  }

  Future<void> _checkConnection() => _run('check', () async {
    await _process.ensureStarted();
    await OnlineMusicService.instance.ensureReady();
  }, successMessage: '在线音源后端连接正常');

  Future<void> _loadCacheSize() async {
    try {
      final bytes = await OnlineAudioCache.instance.totalBytes();
      if (!mounted) return;
      setState(() {
        _cacheBytes = bytes;
        _cacheError = null;
        _cacheLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cacheError = '缓存暂不可用';
        _cacheLoading = false;
      });
    }
  }

  Future<void> _refreshCacheSize() async {
    if (_cacheLoading) return;
    setState(() {
      _cacheLoading = true;
      _cacheError = null;
    });
    await _loadCacheSize();
  }

  Future<void> _clearCache() async {
    if (_cacheClearing) return;
    setState(() => _cacheClearing = true);
    try {
      await OnlineAudioCache.instance.clear();
      if (!mounted) return;
      setState(() {
        _cacheBytes = 0;
        _cacheError = null;
        _cacheLoading = false;
      });
      showTextOnSnackBar('缓存已清理', variant: ToastVariant.success);
    } catch (_) {
      showTextOnSnackBar('清理缓存失败', variant: ToastVariant.error);
    } finally {
      if (mounted) setState(() => _cacheClearing = false);
    }
  }
}

class _OnlineTextField extends StatelessWidget {
  const _OnlineTextField({
    required this.label,
    this.subtitle,
    required this.controller,
    required this.enabled,
    required this.obscure,
    required this.onFocusChange,
    this.suffixIcon,
  });

  final String label;
  final String? subtitle;
  final TextEditingController controller;
  final bool enabled;
  final bool obscure;
  final ValueChanged<bool> onFocusChange;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: label,
      subtitle: subtitle,
      action: SizedBox(
        width: 280.0,
        child: Focus(
          onFocusChange: (focused) {
            HotkeysHelper.onFocusChanges(focused);
            onFocusChange(focused);
          },
          child: TextField(
            controller: controller,
            enabled: enabled,
            obscureText: obscure,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: suffixIcon,
            ),
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
          ),
        ),
      ),
    );
  }
}
