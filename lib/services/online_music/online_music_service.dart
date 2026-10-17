import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/online_music/backend_client.dart';
import 'package:pure_music/services/online_music/backend_process.dart';
import 'package:pure_music/services/online_music/models.dart';

// 在线音源统一入口：负责后端就绪、鉴权状态缓存与 API 转发。
class OnlineMusicService {
  OnlineMusicService._();

  static final OnlineMusicService instance = OnlineMusicService._();

  final ValueNotifier<OnlineAuthStatus?> auth = ValueNotifier<OnlineAuthStatus?>(null);
  final ValueNotifier<bool> authLoading = ValueNotifier<bool>(false);

  OnlineBackendClient? _client;
  String _clientBaseUrl = '';
  String _clientToken = '';

  bool get isEnabled => AppSettings.instance.onlineMusicEnabled;

  bool get isReady => OnlineBackendProcess.instance.state == OnlineBackendState.ready;

  bool get isLoggedIn => auth.value?.loggedIn == true;

  OnlineAudioQuality get quality => AppSettings.instance.onlineMusicQuality;

  OnlineBackendClient get client {
    final baseUrl = AppSettings.instance.onlineMusicBaseUrl;
    final token = AppSettings.instance.onlineMusicToken;
    final cached = _client;
    if (cached != null && _clientBaseUrl == baseUrl && _clientToken == token) return cached;
    final created = OnlineBackendClient(baseUrl: baseUrl, apiToken: token);
    _client = created;
    _clientBaseUrl = baseUrl;
    _clientToken = token;
    return created;
  }

  void resetClient() => _client = null;

  Future<void> ensureReady() async {
    if (!isEnabled) {
      throw OnlineApiException(statusCode: 0, code: 'ONLINE_DISABLED', message: '在线音源未启用');
    }
    final ok = await OnlineBackendProcess.instance.ensureStarted();
    if (!ok) {
      throw OnlineApiException(
        statusCode: 0,
        code: 'BACKEND_UNAVAILABLE',
        message: OnlineBackendProcess.instance.lastError ?? '在线音源后端未就绪',
      );
    }
  }

  Future<T> _call<T>(Future<T> Function(OnlineBackendClient client) action) async {
    await ensureReady();
    try {
      return await action(client);
    } on OnlineApiException catch (error) {
      if (error.isSessionChanged) unawaited(refreshAuth());
      rethrow;
    }
  }

  Future<void> refreshAuth() async {
    if (!isEnabled) {
      auth.value = null;
      return;
    }
    authLoading.value = true;
    try {
      final status = await _call((client) => client.authStatus());
      auth.value = status;
    } on OnlineApiException {
      auth.value = null;
    } finally {
      authLoading.value = false;
    }
  }

  Future<OnlinePage<OnlineSong>> search(String keywords, {int limit = 30, int offset = 0}) =>
      _call((client) => client.search(keywords, limit: limit, offset: offset));

  Future<List<OnlineSong>> songs(List<String> ids) => _call((client) => client.songs(ids));

  Future<OnlineSong> song(String id) => _call((client) => client.song(id));

  Future<OnlinePlayback> playback(String id, {OnlineAudioQuality? quality}) =>
      _call((client) => client.playback(id, quality: quality ?? this.quality));

  Future<OnlineLyrics> lyrics(String id) => _call((client) => client.lyrics(id));

  Future<OnlinePlaylist> playlist(String id) => _call((client) => client.playlist(id));

  Future<OnlinePlaylistTracks> playlistTracks(String id, {int limit = 100, int offset = 0}) =>
      _call((client) => client.playlistTracks(id, limit: limit, offset: offset));

  Future<OnlineAlbumDetail> album(String id) => _call((client) => client.album(id));

  Future<OnlineArtistDetail> artist(String id, {int limit = 50, int offset = 0}) =>
      _call((client) => client.artist(id, limit: limit, offset: offset));

  Future<List<OnlinePlaylist>> recommendationPlaylists({int limit = 20}) =>
      _call((client) => client.recommendationPlaylists(limit: limit));

  Future<List<OnlineSong>> dailySongs() => _call((client) => client.dailySongs());

  Future<List<OnlinePlaylist>> personalPlaylists() => _call((client) => client.personalPlaylists());

  Future<OnlinePage<OnlinePlaylist>> myPlaylists({int limit = 50, int offset = 0}) =>
      _call((client) => client.myPlaylists(limit: limit, offset: offset));

  Future<List<String>> myLikes() => _call((client) => client.myLikes());

  Future<OnlineMembership> membership() => _call((client) => client.membership());

  Future<OnlineAuthStatus> importCookie(String cookie) async {
    final status = await _call((client) => client.importCookie(cookie));
    await refreshAuth();
    return status;
  }

  Future<void> logout() async {
    await _call((client) => client.logout());
    auth.value = const OnlineAuthStatus();
  }

  Future<OnlineQrSession> createQr() => _call((client) => client.createQr());

  Future<OnlineQrPoll> pollQr(String sessionId) async {
    final poll = await _call((client) => client.pollQr(sessionId));
    if (poll.state == OnlineQrState.authorized) await refreshAuth();
    return poll;
  }

  Future<void> setLike(String id, bool liked) => _call((client) => client.setLike(id, liked));

  Future<String> mediaTicketUrl(String url, {String kind = 'cover'}) =>
      _call((client) => client.createMediaTicket(url, kind: kind));

  Future<void> startBackend() async {
    await OnlineBackendProcess.instance.ensureStarted();
  }

  Future<void> stopBackend() => OnlineBackendProcess.instance.stop();

  Future<void> restartBackend() async {
    resetClient();
    await OnlineBackendProcess.instance.restart();
    if (isReady) await refreshAuth();
  }
}
