import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/online_music/backend_client.dart';
import 'package:pure_music/services/online_music/models.dart';
import 'package:pure_music/services/online_music/online_audio_cache.dart';
import 'package:pure_music/services/online_music/online_lyric_sidecar.dart';
import 'package:pure_music/services/online_music/online_music_service.dart';

/// 在线曲目播放入口：把 OnlineSong 转成占位 Audio 进播放队列，播放前再下载缓存。
class OnlinePlayback {
  OnlinePlayback._();

  static final OnlinePlayback instance = OnlinePlayback._();

  /// 正在解析或下载的曲目，供界面显示加载态。
  final ValueNotifier<OnlineSong?> preparing = ValueNotifier<OnlineSong?>(null);

  final Map<String, OnlineSong> _songs = <String, OnlineSong>{};
  bool _attached = false;
  bool _prefetching = false;

  Future<void> playTrack(OnlineSong song) => playSongs(<OnlineSong>[song]);

  Future<void> playSongs(List<OnlineSong> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;
    _attach();
    final quality = OnlineMusicService.instance.quality;
    final queue = <Audio>[];
    for (var index = 0; index < songs.length; index++) {
      final song = songs[index];
      _songs[song.id] = song;
      queue.add(_placeholder(song, index + 1, quality));
    }
    final start = startIndex < 0 || startIndex >= queue.length ? 0 : startIndex;
    PlayService.instance.playbackService.play(start, queue);
  }

  /// 插到当前播放的下一首。
  Future<void> playNext(OnlineSong song) async {
    _attach();
    _songs[song.id] = song;
    final playback = PlayService.instance.playbackService;
    if (playback.nowPlaying == null || playback.playlist.value.isEmpty) {
      await playSongs(<OnlineSong>[song]);
      return;
    }
    final audio = _placeholder(
      song,
      (playback.nowPlaying?.track ?? 0) + 1,
      OnlineMusicService.instance.quality,
    );
    playback.addToNext(audio);
  }

  /// 播放前准备：下载音频缓存并写歌词外挂文件。
  Future<void> ensurePrepared(Audio audio) async {
    final id = audio.onlineSongId;
    if (id == null) return;
    _attach();
    final song = _songs[id] ?? _songFromAudio(id, audio);
    preparing.value = song;
    try {
      final file = await OnlineAudioCache.instance.ensureCached(song);
      if (!await file.exists()) {
        throw OnlineApiException(
          statusCode: 404,
          code: 'SONG_UNAVAILABLE',
          message: '在线音源缓存文件缺失',
        );
      }
      audio.path = file.path;
      try {
        final stat = await file.stat();
        audio.modified = stat.modified.millisecondsSinceEpoch ~/ 1000;
      } catch (_) {}
      if (audio.duration <= 0 && song.durationMs > 0) {
        audio.duration = song.duration.inSeconds;
      }
      try {
        await OnlineLyricSidecar.instance.writeForAudio(audio);
      } catch (_) {}
      if (!AppSettings.instance.onlineMusicKeepCache) {
        unawaited(OnlineAudioCache.instance.enforceLimit());
      }
    } finally {
      if (identical(preparing.value, song)) preparing.value = null;
    }
  }

  /// 后台预取，失败静默。
  Future<void> prefetch(OnlineSong song) async {
    if (!OnlineMusicService.instance.isEnabled) return;
    if (OnlineAudioCache.instance.cachedFileSync(song) != null) return;
    try {
      await OnlineAudioCache.instance.ensureCached(song);
    } catch (_) {}
  }

  /// 当前播放的是在线曲目时清空队列。
  void clearQueueIfOnline() {
    try {
      final playback = PlayService.instance.playbackService;
      final current = playback.nowPlaying;
      if (current == null || current.onlineSongId == null) return;
      playback.clearQueue();
    } catch (_) {}
    _songs.clear();
  }

  void _attach() {
    if (_attached) return;
    try {
      PlayService.instance.playbackService.nowPlayingNotifier.addListener(_onNowPlayingChanged);
      _attached = true;
    } catch (_) {}
  }

  void _onNowPlayingChanged() {
    if (_prefetching) return;
    _prefetching = true;
    unawaited(_prefetchAround().whenComplete(() => _prefetching = false));
  }

  Future<void> _prefetchAround() async {
    final playback = PlayService.instance.playbackService;
    final current = playback.nowPlaying;
    if (current == null) return;
    final items = playback.playlist.value;
    var index = items.indexWhere((item) => identical(item, current));
    if (index < 0) index = items.indexWhere((item) => item.path == current.path);
    if (index < 0) return;
    for (var step = 1; step <= 2; step++) {
      final nextIndex = index + step;
      if (nextIndex >= items.length) break;
      final id = items[nextIndex].onlineSongId;
      if (id == null) continue;
      final song = _songs[id];
      if (song != null) await prefetch(song);
    }
  }

  Audio _placeholder(OnlineSong song, int track, OnlineAudioQuality quality) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final artist = song.artistText;
    return Audio(
      song.name,
      artist,
      song.albumName,
      artist.isEmpty ? null : artist,
      track,
      song.duration.inSeconds,
      _bitrateFor(quality),
      44100,
      OnlineAudioCache.instance.cachePathFor(song),
      now,
      now,
      '',
      onlineSongId: song.id,
      onlineCover: song.cover.isEmpty ? null : song.cover,
    );
  }

  OnlineSong _songFromAudio(String id, Audio audio) => OnlineSong(
    id: id,
    name: audio.title,
    artist: audio.artist,
    albumName: audio.album,
    cover: audio.onlineCover ?? '',
    durationMs: audio.duration * 1000,
  );

  int _bitrateFor(OnlineAudioQuality quality) {
    switch (quality) {
      case OnlineAudioQuality.standard:
        return 128;
      case OnlineAudioQuality.exhigh:
        return 320;
      case OnlineAudioQuality.lossless:
        return 900;
      case OnlineAudioQuality.hires:
        return 1500;
      case OnlineAudioQuality.jymaster:
        return 2000;
    }
  }
}
