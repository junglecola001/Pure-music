import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/services/online_music/backend_process.dart';
import 'package:pure_music/services/online_music/online_music_service.dart';

/// 在线封面缓存：内存 LRU 加磁盘文件，供 Audio 封面与列表组件复用。
class OnlineCoverCache {
  OnlineCoverCache._();

  static final OnlineCoverCache instance = OnlineCoverCache._();

  static const int _memoryLimit = 96;
  static const int _maxBytes = 4 * 1024 * 1024;

  final Map<String, ImageProvider> _memory = <String, ImageProvider>{};
  final Map<String, Future<ImageProvider?>> _pending = <String, Future<ImageProvider?>>{};
  String? _dirPath;

  /// 已同步命中的封面，供组件首帧直接显示，避免闪烁。
  ImageProvider? peek(String? url, {int width = 300}) {
    final text = url?.trim() ?? '';
    if (text.isEmpty) return null;
    return _memory['$text|$width'];
  }

  Future<ImageProvider?> imageProvider(String? url, {int width = 300}) async {
    final text = url?.trim() ?? '';
    if (text.isEmpty) return null;
    final key = '$text|$width';
    final cached = _memory.remove(key);
    if (cached != null) {
      _memory[key] = cached;
      return cached;
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final future = _load(text, width);
    _pending[key] = future;
    try {
      final provider = await future;
      if (provider != null) {
        _memory[key] = provider;
        while (_memory.length > _memoryLimit) {
          _memory.remove(_memory.keys.first);
        }
      }
      return provider;
    } finally {
      if (identical(_pending[key], future)) _pending.remove(key)?.ignore();
    }
  }

  Future<void> clear() async {
    _memory.clear();
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

  Future<ImageProvider?> _load(String url, int width) async {
    try {
      final bytes = await _readDisk(url) ?? await _download(url);
      if (bytes == null || bytes.isEmpty) return null;
      return ResizeImage(MemoryImage(bytes), width: width);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _readDisk(String url) async {
    try {
      final file = await _diskFile(url);
      if (!await file.exists() || await file.length() == 0) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _download(String url) async {
    try {
      final service = OnlineMusicService.instance;
      if (!service.isEnabled) return null;
      final ticketUrl = await service.mediaTicketUrl(url, kind: 'cover');
      final bytes = await service.client.fetchBytes(ticketUrl, maxBytes: _maxBytes);
      if (bytes.isEmpty) return null;
      try {
        final file = await _diskFile(url);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      } catch (_) {}
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<File> _diskFile(String url) async {
    final hash = sha1.convert(utf8.encode(url)).toString();
    final dir = await _dir();
    return File(p.join(dir.path, '$hash.img'));
  }

  Future<Directory> _dir() async {
    final known = _dirPath;
    if (known != null) return Directory(known);
    final dir = await OnlineBackendProcess.instance.coverCacheDir();
    _dirPath = dir.path;
    return dir;
  }
}

class OnlineCoverImage extends StatelessWidget {
  const OnlineCoverImage({
    super.key,
    required this.url,
    required this.size,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  final String? url;
  final double size;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final cache = OnlineCoverCache.instance;
    final width = size.ceil();
    final placeholder = _placeholder(context);
    Widget child;
    final cached = cache.peek(url, width: width);
    if (cached != null) {
      child = _image(cached, placeholder);
    } else {
      child = FutureBuilder<ImageProvider?>(
        future: cache.imageProvider(url, width: width),
        builder: (context, snapshot) {
          final provider = snapshot.data;
          if (provider == null) return placeholder;
          return _image(provider, placeholder);
        },
      );
    }
    final radius = borderRadius;
    if (radius != null) child = ClipRRect(borderRadius: radius, child: child);
    return SizedBox(width: size, height: size, child: child);
  }

  Widget _image(ImageProvider provider, Widget placeholder) {
    return Image(
      image: provider,
      width: size,
      height: size,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => placeholder,
    );
  }

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Symbols.music_note,
          size: size * 0.4,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
