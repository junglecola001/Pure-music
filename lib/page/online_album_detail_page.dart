import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/online_track_tile.dart';
import 'package:pure_music/page/online_widgets.dart';
import 'package:pure_music/services/online_music/models.dart'
    hide OnlinePlayback;
import 'package:pure_music/services/online_music/online_cover.dart';
import 'package:pure_music/services/online_music/online_music_service.dart';
import 'package:pure_music/services/online_music/online_playback.dart';

/// 在线专辑详情：专辑信息加曲目列表。
class OnlineAlbumDetailPage extends StatefulWidget {
  const OnlineAlbumDetailPage({super.key, required this.albumId});

  final String albumId;

  @override
  State<OnlineAlbumDetailPage> createState() => _OnlineAlbumDetailPageState();
}

class _OnlineAlbumDetailPageState extends State<OnlineAlbumDetailPage> {
  OnlineAlbumDetail? _detail;
  Object? _error;
  bool _loading = true;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OnlineAlbumDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.albumId != widget.albumId) {
      _load();
    }
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await OnlineMusicService.instance.album(widget.albumId);
      if (!mounted || token != _loadToken) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _playAll() {
    final songs = _detail?.songs;
    if (songs == null || songs.isEmpty) return;
    unawaited(OnlinePlayback.instance.playSongs(songs));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      child: _buildContent(scheme),
    );
  }

  Widget _buildContent(ColorScheme scheme) {
    final error = _error;
    if (error != null) {
      return Center(child: OnlineErrorView(error: error, onRetry: _load));
    }
    if (_loading) {
      return const Center(child: OnlineLoadingView());
    }
    final detail = _detail;
    if (detail == null) {
      return Center(child: OnlineErrorView(error: '专辑数据为空', onRetry: _load));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Spacing.lg),
        _buildHeader(scheme, detail),
        const SizedBox(height: Spacing.xl),
        Expanded(child: _buildTrackList(scheme, detail.songs)),
      ],
    );
  }

  Widget _buildHeader(ColorScheme scheme, OnlineAlbumDetail detail) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        final cover = OnlineCoverImage(
          url: detail.album.cover,
          size: compact ? 140 : 180,
          borderRadius: AppRadius.mdCircular,
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cover,
              const SizedBox(height: Spacing.lg),
              _buildHeaderInfo(scheme, detail),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
            const SizedBox(width: Spacing.xl),
            Expanded(child: _buildHeaderInfo(scheme, detail)),
          ],
        );
      },
    );
  }

  Widget _buildHeaderInfo(ColorScheme scheme, OnlineAlbumDetail detail) {
    final album = detail.album;
    final meta = <String>[
      if (album.publishedAt > 0) '${_formatPublishedAt(album.publishedAt)} 发行',
      if (album.trackCount > 0) '${album.trackCount} 首',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          album.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.hero,
            fontWeight: AppType.weightBold,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        _buildArtistText(scheme, album),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: Spacing.xs),
          Text(
            meta.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.body,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        FilledButton.icon(
          onPressed: detail.songs.isEmpty ? null : _playAll,
          icon: const Icon(Symbols.play_arrow, size: 20),
          label: const Text('播放全部'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
          ),
        ),
      ],
    );
  }

  Widget _buildArtistText(ColorScheme scheme, OnlineAlbum album) {
    final text = album.artistText.isEmpty ? '未知艺术家' : album.artistText;
    final style = TextStyle(fontSize: AppType.subtitle, color: scheme.onSurface);
    final artistId = album.artists.isEmpty ? '' : album.artists.first.id;
    if (artistId.isEmpty) {
      return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: style);
    }
    return InkWell(
      onTap: () => context.push('${app_paths.ONLINE_ARTIST_DETAIL_PAGE}/$artistId'),
      child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: style),
    );
  }

  Widget _buildTrackList(ColorScheme scheme, List<OnlineSong> songs) {
    if (songs.isEmpty) {
      return const Center(
        child: OnlineEmptyView(
          icon: Symbols.music_off,
          text: '这张专辑还没有可播放的歌曲',
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        return OnlineTrackTile(
          track: songs[index],
          index: index,
          playlist: songs,
        );
      },
    );
  }
}

String _formatPublishedAt(int millis) {
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${date.year}年${date.month}月${date.day}日';
}
