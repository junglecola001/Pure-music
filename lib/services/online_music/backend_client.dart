import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pure_music/services/online_music/models.dart';

class OnlineApiException implements Exception {
  OnlineApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details,
    this.requestId,
    this.retryAfterSeconds,
  });

  final int statusCode;
  final String code;
  final String message;
  final Object? details;
  final String? requestId;
  final int? retryAfterSeconds;

  bool get isNetworkError => statusCode <= 0;

  bool get isLoginRequired => code == 'LOGIN_REQUIRED';

  bool get isSessionChanged => code == 'SESSION_CHANGED';

  bool get isQrExpired => code == 'QR_EXPIRED';

  bool get isQrBusy => code == 'QR_POLL_BUSY';

  bool get isRateLimited => statusCode == 429 || code == 'RATE_LIMITED';

  bool get isUpstreamFailure => statusCode >= 500;

  @override
  String toString() => 'OnlineApiException($statusCode $code: $message)';
}

class OnlineBackendClient {
  OnlineBackendClient({required String baseUrl, this.apiToken = ''})
      : baseUrl = normalizeBaseUrl(baseUrl),
        _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 8),
            sendTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            validateStatus: (_) => true,
          ),
        );

  final String baseUrl;
  final Dio _dio;
  String apiToken;

  static String normalizeBaseUrl(String value) {
    var text = value.trim();
    if (text.isEmpty) text = 'http://127.0.0.1:3000';
    if (!text.contains('://')) text = 'http://$text';
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  Uri get _origin => Uri.parse(baseUrl);

  Uri resolve(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return Uri.parse(path);
    return _origin.resolve(path);
  }

  String absoluteUrl(String? path) {
    if (path == null || path.isEmpty) return '';
    return resolve(path).toString();
  }

  Map<String, String> get _headers => {
        'accept': 'application/json',
        if (apiToken.isNotEmpty) 'authorization': 'Bearer $apiToken',
      };

  Options get _jsonOptions => Options(headers: _headers, responseType: ResponseType.json);

  Future<Object?> _send(String method, String path, {Map<String, dynamic>? query, Object? body}) async {
    final uri = resolve('/api/v1$path');
    Response<Object?> response;
    try {
      response = await _dio.request<Object?>(
        uri.toString(),
        data: body,
        queryParameters: query,
        options: _jsonOptions.copyWith(method: method),
      );
    } on DioException catch (error) {
      throw OnlineApiException(
        statusCode: 0,
        code: _networkCodeFor(error),
        message: _describeNetworkError(error),
      );
    }
    final status = response.statusCode ?? 0;
    final data = response.data;
    final map = data is Map ? onlineMap(data) : <String, dynamic>{};
    if (status >= 200 && status < 300) {
      if (map['success'] == true) return map['data'];
      return data;
    }
    final error = onlineMap(map['error']);
    throw OnlineApiException(
      statusCode: status,
      code: onlineString(error['code']).isEmpty ? 'HTTP_$status' : onlineString(error['code']),
      message: onlineString(error['message']).isEmpty ? '请求失败（HTTP $status）' : onlineString(error['message']),
      details: error['details'],
      requestId: onlineString(map['requestId']).isEmpty ? null : onlineString(map['requestId']),
      retryAfterSeconds: _retryAfter(response.headers),
    );
  }

  Future<Object?> get(String path, {Map<String, dynamic>? query}) => _send('GET', path, query: query);

  Future<Object?> post(String path, {Object? body, Map<String, dynamic>? query}) =>
      _send('POST', path, body: body, query: query);

  Future<Object?> put(String path, {Object? body}) => _send('PUT', path, body: body);

  Future<Object?> delete(String path, {Object? body}) => _send('DELETE', path, body: body);

  Future<Map<String, dynamic>> health() async {
    final data = await get('/health');
    return onlineMap(data);
  }

  Future<OnlinePage<OnlineSong>> search(String keywords, {int limit = 30, int offset = 0}) async {
    final data = await get('/search', query: {'keywords': keywords, 'limit': limit, 'offset': offset});
    return OnlinePage<OnlineSong>.fromJson(data, OnlineSong.fromJson);
  }

  Future<List<OnlineSong>> songs(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final data = onlineMap(await get('/songs', query: {'ids': ids.join(',')}));
    return onlineList(data['items']).map((item) => OnlineSong.fromJson(item)).toList(growable: false);
  }

  Future<OnlineSong> song(String id) async => OnlineSong.fromJson(await get('/songs/$id'));

  Future<OnlinePlayback> playback(String id, {OnlineAudioQuality? quality}) async {
    final data = await get(
      '/songs/$id/playback',
      query: {'quality': (quality ?? OnlineAudioQuality.hires).apiValue},
    );
    return OnlinePlayback.fromJson(data);
  }

  Future<OnlineLyrics> lyrics(String id) async => OnlineLyrics.fromJson(await get('/songs/$id/lyrics'));

  Future<OnlinePlaylist> playlist(String id) async => OnlinePlaylist.fromJson(await get('/playlists/$id'));

  Future<OnlinePlaylistTracks> playlistTracks(String id, {int limit = 100, int offset = 0}) async {
    final data = await get('/playlists/$id/tracks', query: {'limit': limit, 'offset': offset});
    return OnlinePlaylistTracks.fromJson(data);
  }

  Future<OnlineAlbumDetail> album(String id) async => OnlineAlbumDetail.fromJson(await get('/albums/$id'));

  Future<OnlineArtistDetail> artist(String id, {int limit = 50, int offset = 0}) async {
    final data = await get('/artists/$id', query: {'limit': limit, 'offset': offset});
    return OnlineArtistDetail.fromJson(data);
  }

  Future<List<OnlinePlaylist>> recommendationPlaylists({int limit = 20}) async {
    final data = onlineMap(await get('/recommendations/playlists', query: {'limit': limit}));
    return onlineList(data['items'])
        .map((item) => OnlinePlaylist.fromJson(item))
        .toList(growable: false);
  }

  Future<List<OnlineSong>> dailySongs() async {
    final data = onlineMap(await get('/recommendations/daily'));
    return onlineList(data['items']).map((item) => OnlineSong.fromJson(item)).toList(growable: false);
  }

  Future<List<OnlinePlaylist>> personalPlaylists() async {
    final data = onlineMap(await get('/recommendations/personal-playlists'));
    return onlineList(data['items'])
        .map((item) => OnlinePlaylist.fromJson(item))
        .toList(growable: false);
  }

  Future<OnlinePage<OnlinePlaylist>> myPlaylists({int limit = 50, int offset = 0}) async {
    final data = await get('/me/playlists', query: {'limit': limit, 'offset': offset});
    return OnlinePage<OnlinePlaylist>.fromJson(data, OnlinePlaylist.fromJson);
  }

  Future<List<String>> myLikes() async {
    final data = onlineMap(await get('/me/likes'));
    return onlineList(data['ids']).map((item) => onlineString(item)).toList(growable: false);
  }

  Future<OnlineAuthStatus> authStatus() async => OnlineAuthStatus.fromJson(await get('/auth/status'));

  Future<OnlineMembership> membership() async => OnlineMembership.fromJson(await get('/auth/membership'));

  Future<OnlineAuthStatus> importCookie(String cookie) async {
    final data = await post('/auth/cookie', body: {'cookie': cookie});
    return OnlineAuthStatus.fromJson(data);
  }

  Future<void> logout() async {
    await post('/auth/logout');
  }

  Future<OnlineQrSession> createQr() async => OnlineQrSession.fromJson(await post('/auth/qr'));

  Future<OnlineQrPoll> pollQr(String sessionId) async =>
      OnlineQrPoll.fromJson(await get('/auth/qr/$sessionId'));

  Future<void> setLike(String id, bool liked) async {
    await put('/me/likes/$id', body: {'liked': liked});
  }

  Future<String> createMediaTicket(String url, {String kind = 'cover'}) async {
    final data = onlineMap(await post('/media/tickets', body: {'url': url, 'kind': kind}));
    final proxyUrl = onlineString(data['proxyUrl']);
    if (proxyUrl.isEmpty) throw OnlineApiException(statusCode: 502, code: 'MEDIA_TICKET_MISSING', message: '媒体票据缺失');
    return absoluteUrl(proxyUrl);
  }

  Future<Uint8List> fetchBytes(String url, {int maxBytes = 8 * 1024 * 1024}) async {
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(
          headers: {'accept': 'image/*,*/*'},
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 200 && status < 300) {
        final bytes = response.data ?? const <int>[];
        return Uint8List.fromList(bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes);
      }
      throw OnlineApiException(statusCode: status, code: 'MEDIA_HTTP_$status', message: '媒体下载失败');
    } on DioException catch (error) {
      throw OnlineApiException(statusCode: 0, code: 'NETWORK_ERROR', message: _describeNetworkError(error));
    }
  }

  // 断点续传下载到 part 文件，完成后改名。
  Future<void> downloadToFile(
    String url,
    File target, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final part = File('${target.path}.part');
    await target.parent.create(recursive: true);
    var existing = await part.exists() ? await part.length() : 0;
    final total = TargetLength();
    while (true) {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'accept': '*/*', if (existing > 0) 'range': 'bytes=$existing-'},
          validateStatus: (_) => true,
          receiveTimeout: const Duration(minutes: 10),
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == 416 && existing > 0) {
        await part.rename(target.path);
        return;
      }
      if (status != 200 && status != 206) {
        throw OnlineApiException(statusCode: status, code: 'MEDIA_HTTP_$status', message: '音频下载失败');
      }
      if (status == 200) existing = 0;
      final contentLength = int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
      total.value = contentLength + existing;
      final sink = part.openWrite(mode: existing > 0 ? FileMode.append : FileMode.write);
      var received = existing;
      try {
        await for (final chunk in response.data!.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total.value);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      // 服务器提前结束（网络抖动）时继续用 Range 续传剩余部分。
      if (total.value <= 0 || received >= total.value) break;
      existing = await part.length();
      if (existing >= total.value) break;
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  }

  String _networkCodeFor(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'NETWORK_TIMEOUT';
      case DioExceptionType.cancel:
        return 'NETWORK_CANCELLED';
      default:
        return 'NETWORK_ERROR';
    }
  }

  String _describeNetworkError(DioException error) {
    if (error.type == DioExceptionType.connectionError) {
      return '无法连接在线音源后端，请确认后端地址与端口';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return '在线音源后端响应超时';
    }
    final message = error.message ?? error.error?.toString() ?? '';
    return message.isEmpty ? '网络请求失败' : message;
  }

  int? _retryAfter(Headers headers) {
    final raw = headers.value('retry-after');
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds != null) return seconds;
    final date = DateTime.tryParse(raw.trim());
    if (date == null) return null;
    final diff = date.difference(DateTime.now()).inSeconds;
    return diff < 0 ? 0 : diff;
  }
}

class TargetLength {
  int value = 0;
}
