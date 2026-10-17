import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_music/models.dart';
import 'package:pure_music/services/online_music/online_music_service.dart';

/// 把在线歌词写成同名 .lrc 外挂文件，现有歌词加载器直接可用。
class OnlineLyricSidecar {
  OnlineLyricSidecar._();

  static final OnlineLyricSidecar instance = OnlineLyricSidecar._();

  static final RegExp _timeTag = RegExp(r'\[(\d+):(\d+(?:[.:]\d+)?)\]');

  /// 翻译与原文的时间戳允许有偏差，超出这个范围不配对。
  static const int _translationToleranceMs = 400;

  Future<void> writeForAudio(Audio audio) async {
    final id = audio.onlineSongId;
    final audioPath = audio.path;
    if (id == null || audioPath.isEmpty) return;
    final sidecarPath = p.setExtension(audioPath, '.lrc');
    final OnlineLyrics lyrics;
    try {
      lyrics = await OnlineMusicService.instance.lyrics(id);
    } catch (_) {
      return;
    }
    final content = _buildLrc(lyrics);
    if (content.isEmpty) {
      await _deleteIfExists(sidecarPath);
      return;
    }
    await writeTextFileAtomically(sidecarPath, content);
  }

  Future<void> removeForAudio(Audio audio) async {
    final audioPath = audio.path;
    if (audioPath.isEmpty) return;
    await _deleteIfExists(p.setExtension(audioPath, '.lrc'));
  }

  Future<void> _deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  String _buildLrc(OnlineLyrics lyrics) {
    if (lyrics.instrumental) return '';
    final translations = _parseTimedText(lyrics.translated);
    final romanizations = _parseTimedText(lyrics.romanized);
    final buffer = StringBuffer();
    for (final line in lyrics.lines) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      final tag = _formatTime(line.timeMs);
      buffer.writeln('$tag$text');
      final translation = _matchedText(translations, line.timeMs);
      if (translation != null && translation != text) {
        buffer.writeln('$tag$translation');
      }
      final romanization = _matchedText(romanizations, line.timeMs);
      if (romanization != null &&
          romanization != text &&
          romanization != translation) {
        buffer.writeln('$tag$romanization');
      }
    }
    return buffer.toString();
  }

  List<({int timeMs, String text})> _parseTimedText(String raw) {
    final result = <({int timeMs, String text})>[];
    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final matches = _timeTag.allMatches(line).toList(growable: false);
      if (matches.isEmpty) continue;
      final text = line.substring(matches.last.end).trim();
      if (text.isEmpty) continue;
      for (final match in matches) {
        final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
        final seconds = double.tryParse((match.group(2) ?? '').replaceAll(':', '.')) ?? 0;
        result.add((timeMs: minutes * 60000 + (seconds * 1000).round(), text: text));
      }
    }
    return result;
  }

  String? _matchedText(List<({int timeMs, String text})> items, int timeMs) {
    String? best;
    var bestDiff = _translationToleranceMs + 1;
    for (final item in items) {
      final diff = (item.timeMs - timeMs).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = item.text;
      }
    }
    return best;
  }

  String _formatTime(int timeMs) {
    final safe = timeMs < 0 ? 0 : timeMs;
    final minutes = safe ~/ 60000;
    final seconds = ((safe % 60000) / 1000).toStringAsFixed(2).padLeft(5, '0');
    return '[${minutes.toString().padLeft(2, '0')}:$seconds]';
  }
}
