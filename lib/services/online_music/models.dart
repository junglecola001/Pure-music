// 在线音源数据模型，字段与后端 /api/v1 契约一一对应。

enum OnlineAudioQuality {
  standard('standard', '标准'),
  exhigh('exhigh', '较高'),
  lossless('lossless', '无损'),
  hires('hires', 'Hi-Res'),
  jymaster('jymaster', '超清母带');

  const OnlineAudioQuality(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static OnlineAudioQuality fromName(String? value) {
    for (final quality in OnlineAudioQuality.values) {
      if (quality.name == value) return quality;
    }
    return OnlineAudioQuality.hires;
  }

  // 后端只向下回退，重试顺序按此表。
  List<OnlineAudioQuality> get fallbackChain {
    final index = OnlineAudioQuality.values.indexOf(this);
    return OnlineAudioQuality.values.sublist(0, index + 1).reversed.toList();
  }
}

enum OnlineQrState { waiting, scanned, authorized }

String onlineString(Object? value) => value == null ? '' : '$value';

int onlineInt(Object? value) =>
    value is int ? value : (value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? 0);

double onlineDouble(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;

bool onlineBool(Object? value) => value is bool ? value : '${value ?? ''}' == 'true';

Map<String, dynamic> onlineMap(Object? value) =>
    value is Map ? value.map((key, item) => MapEntry('$key', item)) : <String, dynamic>{};

List<dynamic> onlineList(Object? value) => value is List ? value : const [];

class OnlineArtistRef {
  const OnlineArtistRef({required this.id, required this.name});

  final String id;
  final String name;

  factory OnlineArtistRef.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineArtistRef(id: onlineString(map['id']), name: onlineString(map['name']));
  }
}

class OnlineSong {
  const OnlineSong({
    required this.id,
    required this.name,
    this.artist = '',
    this.artists = const [],
    this.albumId = '',
    this.albumName = '',
    this.cover = '',
    this.durationMs = 0,
    this.fee = 0,
    this.popularity = 0,
  });

  final String id;
  final String name;
  final String artist;
  final List<OnlineArtistRef> artists;
  final String albumId;
  final String albumName;
  final String cover;
  final int durationMs;
  final int fee;
  final int popularity;

  bool get isFree => fee == 0 || fee == 8;

  Duration get duration => Duration(milliseconds: durationMs);

  String get artistText {
    if (artist.trim().isNotEmpty) return artist;
    return artists.map((item) => item.name).where((item) => item.isNotEmpty).join(' / ');
  }

  factory OnlineSong.fromJson(Object? json) {
    final map = onlineMap(json);
    final album = onlineMap(map['album']);
    return OnlineSong(
      id: onlineString(map['id']),
      name: onlineString(map['name']),
      artist: onlineString(map['artist']),
      artists: onlineList(map['artists'])
          .map((item) => OnlineArtistRef.fromJson(item))
          .where((item) => item.name.isNotEmpty)
          .toList(growable: false),
      albumId: onlineString(album['id']),
      albumName: onlineString(album['name']),
      cover: onlineString(map['cover'] ?? album['cover']),
      durationMs: onlineInt(map['durationMs']),
      fee: onlineInt(map['fee']),
      popularity: onlineInt(map['popularity']),
    );
  }
}

class OnlinePlaylist {
  const OnlinePlaylist({
    required this.id,
    required this.name,
    this.cover = '',
    this.description = '',
    this.trackCount = 0,
    this.playCount = 0,
    this.creatorId = '',
    this.creatorName = '',
    this.subscribed = false,
  });

  final String id;
  final String name;
  final String cover;
  final String description;
  final int trackCount;
  final int playCount;
  final String creatorId;
  final String creatorName;
  final bool subscribed;

  factory OnlinePlaylist.fromJson(Object? json) {
    final map = onlineMap(json);
    final creator = onlineMap(map['creator']);
    return OnlinePlaylist(
      id: onlineString(map['id']),
      name: onlineString(map['name']),
      cover: onlineString(map['cover']),
      description: onlineString(map['description']),
      trackCount: onlineInt(map['trackCount']),
      playCount: onlineInt(map['playCount']),
      creatorId: onlineString(creator['id']),
      creatorName: onlineString(creator['name']),
      subscribed: onlineBool(map['subscribed']),
    );
  }
}

class OnlineAlbum {
  const OnlineAlbum({
    required this.id,
    required this.name,
    this.cover = '',
    this.artists = const [],
    this.publishedAt = 0,
    this.trackCount = 0,
  });

  final String id;
  final String name;
  final String cover;
  final List<OnlineArtistRef> artists;
  final int publishedAt;
  final int trackCount;

  String get artistText => artists.map((item) => item.name).join(' / ');

  factory OnlineAlbum.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineAlbum(
      id: onlineString(map['id']),
      name: onlineString(map['name']),
      cover: onlineString(map['cover']),
      artists: onlineList(map['artists'])
          .map((item) => OnlineArtistRef.fromJson(item))
          .where((item) => item.name.isNotEmpty)
          .toList(growable: false),
      publishedAt: onlineInt(map['publishedAt']),
      trackCount: onlineInt(map['trackCount']),
    );
  }
}

class OnlineArtist {
  const OnlineArtist({
    required this.id,
    required this.name,
    this.avatar = '',
    this.description = '',
    this.musicSize = 0,
    this.albumSize = 0,
  });

  final String id;
  final String name;
  final String avatar;
  final String description;
  final int musicSize;
  final int albumSize;

  factory OnlineArtist.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineArtist(
      id: onlineString(map['id']),
      name: onlineString(map['name']),
      avatar: onlineString(map['avatar']),
      description: onlineString(map['description']),
      musicSize: onlineInt(map['musicSize']),
      albumSize: onlineInt(map['albumSize']),
    );
  }
}

class OnlinePage<T> {
  const OnlinePage({
    required this.items,
    this.total,
    this.limit = 0,
    this.offset = 0,
    this.nextOffset = 0,
    this.hasMore = false,
  });

  final List<T> items;
  final int? total;
  final int limit;
  final int offset;
  final int nextOffset;
  final bool hasMore;

  factory OnlinePage.fromJson(Object? json, T Function(Object?) parse) {
    final map = onlineMap(json);
    final total = map['total'];
    return OnlinePage<T>(
      items: onlineList(map['items']).map(parse).toList(growable: false),
      total: total is num ? total.toInt() : null,
      limit: onlineInt(map['limit']),
      offset: onlineInt(map['offset']),
      nextOffset: onlineInt(map['nextOffset']),
      hasMore: onlineBool(map['hasMore']),
    );
  }
}

class OnlinePlaylistTracks {
  const OnlinePlaylistTracks({
    required this.playlist,
    required this.items,
    this.total,
    this.hasMore = false,
    this.missingIds = const [],
  });

  final OnlinePlaylist playlist;
  final List<OnlineSong> items;
  final int? total;
  final bool hasMore;
  final List<String> missingIds;

  factory OnlinePlaylistTracks.fromJson(Object? json) {
    final map = onlineMap(json);
    final total = map['total'];
    return OnlinePlaylistTracks(
      playlist: OnlinePlaylist.fromJson(map['playlist']),
      items: onlineList(map['items'])
          .map((item) => OnlineSong.fromJson(item))
          .toList(growable: false),
      total: total is num ? total.toInt() : null,
      hasMore: onlineBool(map['hasMore']),
      missingIds: onlineList(map['missingIds'])
          .map((item) => onlineString(item))
          .toList(growable: false),
    );
  }
}

class OnlineAlbumDetail {
  const OnlineAlbumDetail({required this.album, required this.songs});

  final OnlineAlbum album;
  final List<OnlineSong> songs;

  factory OnlineAlbumDetail.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineAlbumDetail(
      album: OnlineAlbum.fromJson(map['album']),
      songs: onlineList(map['songs'])
          .map((item) => OnlineSong.fromJson(item))
          .toList(growable: false),
    );
  }
}

class OnlineArtistDetail {
  const OnlineArtistDetail({required this.artist, required this.page});

  final OnlineArtist artist;
  final OnlinePage<OnlineSong> page;

  factory OnlineArtistDetail.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineArtistDetail(
      artist: OnlineArtist.fromJson(map['artist']),
      page: OnlinePage<OnlineSong>.fromJson(map, OnlineSong.fromJson),
    );
  }
}

class OnlineRestriction {
  const OnlineRestriction({this.code = '', this.message = '', this.action = ''});

  final String code;
  final String message;
  final String action;

  factory OnlineRestriction.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineRestriction(
      code: onlineString(map['code']),
      message: onlineString(map['message']),
      action: onlineString(map['action']),
    );
  }
}

class OnlinePlayback {
  const OnlinePlayback({
    required this.id,
    this.resolvedId = '',
    this.status = 'unavailable',
    this.playable = false,
    this.trial = false,
    this.requestedQuality,
    this.quality,
    this.url,
    this.proxyUrl,
    this.bitrate,
    this.format,
    this.size,
    this.expiresAt,
    this.verified,
    this.restriction,
    this.matched = false,
  });

  final String id;
  final String resolvedId;
  final String status;
  final bool playable;
  final bool trial;
  final OnlineAudioQuality? requestedQuality;
  final OnlineAudioQuality? quality;
  final String? url;
  final String? proxyUrl;
  final int? bitrate;
  final String? format;
  final int? size;
  final int? expiresAt;
  final bool? verified;
  final OnlineRestriction? restriction;
  final bool matched;

  bool get isPlayable => playable && proxyUrl != null && proxyUrl!.isNotEmpty;

  int? get bitrateKbps => bitrate == null ? null : (bitrate! / 1000).round();

  String? get extension {
    final value = format?.toLowerCase();
    return value == null || value.isEmpty || value == 'null' ? null : value;
  }

  factory OnlinePlayback.fromJson(Object? json) {
    final map = onlineMap(json);
    OnlineAudioQuality? qualityOf(Object? value) {
      final text = onlineString(value);
      if (text.isEmpty || text == 'null') return null;
      return OnlineAudioQuality.fromName(text);
    }

    return OnlinePlayback(
      id: onlineString(map['id']),
      resolvedId: onlineString(map['resolvedId']),
      status: onlineString(map['status']),
      playable: onlineBool(map['playable']),
      trial: onlineBool(map['trial']),
      requestedQuality: qualityOf(map['requestedQuality']),
      quality: qualityOf(map['quality']),
      url: _nullableString(map['url']),
      proxyUrl: _nullableString(map['proxyUrl']),
      bitrate: _nullableInt(map['bitrate']),
      format: _nullableString(map['format']),
      size: _nullableInt(map['size']),
      expiresAt: _nullableInt(map['expiresAt']),
      verified: map['verified'] is bool ? map['verified'] as bool : null,
      restriction: map['restriction'] == null
          ? null
          : OnlineRestriction.fromJson(map['restriction']),
      matched: onlineBool(map['matched']),
    );
  }
}

class OnlineLyricLine {
  const OnlineLyricLine({required this.timeMs, required this.text});

  final int timeMs;
  final String text;

  factory OnlineLyricLine.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineLyricLine(timeMs: onlineInt(map['timeMs']), text: onlineString(map['text']));
  }
}

class OnlineLyrics {
  const OnlineLyrics({
    required this.id,
    this.original = '',
    this.translated = '',
    this.romanized = '',
    this.wordByWord = '',
    this.lines = const [],
    this.instrumental = false,
  });

  final String id;
  final String original;
  final String translated;
  final String romanized;
  final String wordByWord;
  final List<OnlineLyricLine> lines;
  final bool instrumental;

  bool get hasContent => lines.isNotEmpty || original.trim().isNotEmpty;

  factory OnlineLyrics.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineLyrics(
      id: onlineString(map['id']),
      original: onlineString(map['original']),
      translated: onlineString(map['translated']),
      romanized: onlineString(map['romanized']),
      wordByWord: onlineString(map['wordByWord']),
      lines: onlineList(map['lines'])
          .map((item) => OnlineLyricLine.fromJson(item))
          .where((line) => line.text.trim().isNotEmpty)
          .toList(growable: false),
      instrumental: onlineBool(map['instrumental']),
    );
  }
}

class OnlineMembership {
  const OnlineMembership({
    this.membership = 'unknown',
    this.isVip,
    this.isSvip,
    this.expiresAt,
    this.source,
    this.errorCode,
  });

  final String membership;
  final bool? isVip;
  final bool? isSvip;
  final int? expiresAt;
  final String? source;
  final String? errorCode;

  String get label {
    switch (membership) {
      case 'vip':
        return '黑胶 VIP';
      case 'svip':
        return '黑胶 SVIP';
      case 'none':
        return '未开通会员';
      default:
        return '会员状态未知';
    }
  }

  factory OnlineMembership.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineMembership(
      membership: onlineString(map['membership']).isEmpty
          ? 'unknown'
          : onlineString(map['membership']),
      isVip: map['isVip'] is bool ? map['isVip'] as bool : null,
      isSvip: map['isSvip'] is bool ? map['isSvip'] as bool : null,
      expiresAt: _nullableInt(map['expiresAt']),
      source: _nullableString(map['source']),
      errorCode: _nullableString(map['errorCode']),
    );
  }
}

class OnlineAuthStatus {
  const OnlineAuthStatus({
    this.loggedIn = false,
    this.hasCookie = false,
    this.userId,
    this.nickname = '',
    this.avatar = '',
    this.membership = const OnlineMembership(),
  });

  final bool loggedIn;
  final bool hasCookie;
  final String? userId;
  final String nickname;
  final String avatar;
  final OnlineMembership membership;

  factory OnlineAuthStatus.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineAuthStatus(
      loggedIn: onlineBool(map['loggedIn']),
      hasCookie: onlineBool(map['hasCookie']),
      userId: _nullableString(map['userId']),
      nickname: onlineString(map['nickname']),
      avatar: onlineString(map['avatar']),
      membership: OnlineMembership.fromJson(map),
    );
  }
}

class OnlineQrSession {
  const OnlineQrSession({
    required this.sessionId,
    required this.expiresAt,
    this.image = '',
    this.url = '',
  });

  final String sessionId;
  final int expiresAt;
  final String image;
  final String url;

  Duration get remaining {
    final left = expiresAt - DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: left < 0 ? 0 : left);
  }

  factory OnlineQrSession.fromJson(Object? json) {
    final map = onlineMap(json);
    return OnlineQrSession(
      sessionId: onlineString(map['sessionId']),
      expiresAt: onlineInt(map['expiresAt']),
      image: onlineString(map['image']),
      url: onlineString(map['url']),
    );
  }
}

class OnlineQrPoll {
  const OnlineQrPoll({
    required this.state,
    this.expiresAt = 0,
    this.account,
    this.retryAfterMs,
  });

  final OnlineQrState state;
  final int expiresAt;
  final OnlineAuthStatus? account;
  final int? retryAfterMs;

  factory OnlineQrPoll.fromJson(Object? json) {
    final map = onlineMap(json);
    final raw = onlineString(map['state']);
    final state = switch (raw) {
      'scanned' => OnlineQrState.scanned,
      'authorized' => OnlineQrState.authorized,
      _ => OnlineQrState.waiting,
    };
    return OnlineQrPoll(
      state: state,
      expiresAt: onlineInt(map['expiresAt']),
      account: map['account'] == null ? null : OnlineAuthStatus.fromJson(map['account']),
      retryAfterMs: _nullableInt(map['retryAfterMs']),
    );
  }
}

String? _nullableString(Object? value) {
  if (value == null) return null;
  final text = '$value';
  return text == 'null' ? null : text;
}

int? _nullableInt(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}
