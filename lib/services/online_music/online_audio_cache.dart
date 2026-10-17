import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/online_music/backend_client.dart';
import 'package:pure_music/services/online_music/backend_process.dart';
import 'package:pure_music/services/online_music/models.dart';
import 'package:pure_music/services/online_music/online_music_service.dart';

/// 在线音源音频缓存：按曲目与音质落盘，播放器直接当本地文件读取。
class OnlineAudioCache {
  OnlineAudioCache._();

  static final OnlineAudioCache instance = OnlineAudioCache._();

  /// 缓存上限，超出后按最后修改时间清理最旧的文件。
  static const int limitBytes = 2 * 1024 * 1024 * 1024;

  static const int _flacQualityIndex = 2;

  static final RegExp _invalidNameChars = RegExp(r'[^a-z0-9_.]');

  String? _dirPath;
  final Map<String, Future<File>> _inflight = <String, Future<File>>{};

  /// 约定的目标路径，同步返回，供占位曲目提前写好 path。
  String cachePathFor(OnlineSong song) {
    return cachePathForExt(
      song,
      OnlineMusicService.instance.quality,
      _guessExtension(OnlineMusicService.instance.quality),
    );
  }

  /// 指定扩展名的缓存路径；实际扩展名以播放解析结果为准。
  String cachePathForExt(OnlineSong song, OnlineAudioQuality quality, String ext) {
    final dir = _dirPath ?? _guessDirPath();
    return p.join(dir, _fileName(song, quality, ext));
  }

  File? cachedFileSync(OnlineSong song) {
    for (final ext in _candidateExtensions(OnlineMusicService.instance.quality)) {
      final file = File(cachePathForExt(song, OnlineMusicService.instance.quality, ext));
      try {
        if (file.existsSync() && file.lengthSync() > 0) return file;
      } catch (_) {}
    }
    return null;
  }

  Future<File> ensureCached(
    OnlineSong song, {
    void Function(double progress)? onProgress,
    OnlineAudioQuality? quality,
  }) {
    final effective = quality ?? OnlineMusicService.instance.quality;
    final key = '${song.id}|${effective.name}';
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = _download(song, effective, onProgress);
    _inflight[key] = future;
    return future.whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key)?.ignore();
    });
  }

  Future<int> totalBytes() async {
    final files = await _cachedFiles();
    var total = 0;
    for (final file in files) {
      try {
        total += await file.length();
      } catch (_) {}
    }
    return total;
  }

  Future<void> clear() async {
    try {
      final dir = await _dir();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 超过上限或关闭缓存时清理旧文件，正在播放的文件跳过。
  Future<void> enforceLimit() async {
    final keepPath = _playingPath();
    final files = await _cachedFiles();
    final entries = <({File file, int modified, int size})>[];
    var total = 0;
    for (final file in files) {
      try {
        final stat = await file.stat();
        final size = stat.size;
        total += size;
        entries.add((file: file, modified: stat.modified.millisecondsSinceEpoch, size: size));
      } catch (_) {}
    }
    if (total <= limitBytes) return;
    entries.sort((left, right) => left.modified.compareTo(right.modified));
    for (final entry in entries) {
      if (total <= limitBytes) break;
      if (keepPath != null && _samePath(entry.file.path, keepPath)) continue;
      try {
        await entry.file.delete();
        total -= entry.size;
      } catch (_) {}
    }
  }

  Future<File> _download(
    OnlineSong song,
    OnlineAudioQuality quality,
    void Function(double progress)? onProgress,
  ) async {
    final playback = await OnlineMusicService.instance.playback(song.id, quality: quality);
    if (!playback.isPlayable) {
      final message = playback.restriction?.message ?? '';
      throw OnlineApiException(
        statusCode: 404,
        code: 'SONG_UNAVAILABLE',
        message: message.isNotEmpty ? message : '这首歌曲当前不可播放',
      );
    }
    final client = OnlineMusicService.instance.client;
    final url = client.absoluteUrl(playback.proxyUrl ?? playback.url);
    if (url.isEmpty) {
      throw OnlineApiException(
        statusCode: 404,
        code: 'SONG_UNAVAILABLE',
        message: '这首歌曲当前不可播放',
      );
    }
    final dir = await _dir();
    final ext = _effectiveExtension(quality, playback.extension);
    final target = File(p.join(dir.path, _fileName(song, quality, ext)));
    if (await target.exists()) {
      if (await target.length() > 0) return target;
      try {
        await target.delete();
      } catch (_) {}
    }
    final part = File('${target.path}.part');
    try {
      await client.downloadToFile(
        url,
        target,
        onProgress: (received, total) {
          onProgress?.call(total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : 0.0);
        },
      );
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
    onProgress?.call(1.0);
    unawaited(enforceLimit());
    return target;
  }

  Future<List<File>> _cachedFiles() async {
    try {
      final dir = await _dir();
      if (!await dir.exists()) return <File>[];
      final files = <File>[];
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        if (!name.startsWith('ne_') || name.endsWith('.part')) continue;
        files.add(entity);
      }
      return files;
    } catch (_) {
      return <File>[];
    }
  }

  String? _playingPath() {
    try {
      return PlayService.existingPlaybackService?.nowPlaying?.path;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _dir() async {
    final known = _dirPath;
    if (known != null) return Directory(known);
    final dir = await OnlineBackendProcess.instance.audioCacheDir();
    _dirPath = dir.path;
    return dir;
  }

  String _guessDirPath() {
    try {
      final candidates = appDataPathCandidates(
        usePortableData: portableBuild,
        executablePath: Platform.resolvedExecutable,
        environment: Platform.environment,
      );
      final existing = candidates.where((path) => Directory(path).existsSync()).toList();
      final root = existing.isNotEmpty ? existing.first : candidates.first;
      return p.join(root, 'online_music', 'audio');
    } catch (_) {
      return p.join(Directory.systemTemp.path, 'online_music', 'audio');
    }
  }

  String _fileName(OnlineSong song, OnlineAudioQuality quality, String ext) {
    final id = song.id.toLowerCase().replaceAll(_invalidNameChars, '_');
    return 'ne_${id}_${quality.name}$ext';
  }

  /// 无损档位默认 flac，其余默认 mp3；解析结果优先。
  String _guessExtension(OnlineAudioQuality quality) {
    return quality.index >= _flacQualityIndex ? '.flac' : '.mp3';
  }

  String _effectiveExtension(OnlineAudioQuality quality, String? format) {
    switch (format) {
      case 'mp3':
        return '.mp3';
      case 'flac':
        return '.flac';
      case 'm4a':
        return '.m4a';
      case 'ogg':
        return '.ogg';
      case 'wav':
        return '.wav';
    }
    return _guessExtension(quality);
  }

  List<String> _candidateExtensions(OnlineAudioQuality quality) {
    final guess = _guessExtension(quality);
    return <String>[guess, guess == '.flac' ? '.mp3' : '.flac'];
  }

  bool _samePath(String left, String right) => p.equals(p.absolute(left), p.absolute(right));
}
