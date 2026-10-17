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

/// 在线艺术家详情：艺术家信息加热门歌曲分页列表。
class OnlineArtistDetailPage extends StatefulWidget {
  const OnlineArtistDetailPage({super.key, required this.artistId});

  final String artistId;

  @override
  State<OnlineArtistDetailPage> createState() =>
      _OnlineArtistDetailPageState();
}

class _OnlineArtistDetailPageState extends State<OnlineArtistDetailPage> {
  static const int _pageSize = 50;
  static const int _maxSongs = 200;
  static const double _loadMoreThreshold = 320;

  final ScrollController _scrollController = ScrollController();

  OnlineArtist? _artist;
  List<OnlineSong> _songs = const [];
  Object? _error;
  Object? _loadMoreError;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _descriptionExpanded = false;
  int? _nextOffset;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OnlineArtistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artistId != widget.artistId) {
      _songs = const [];
      _hasMore = false;
      _nextOffset = null;
      _loadMoreError = null;
      _descriptionExpanded = false;
      _load();
    }
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _error = null;
      _loadingMore = false;
      _loadMoreError = null;
      _hasMore = false;
      _nextOffset = null;
    });
    try {
      final detail = await OnlineMusicService.instance.artist(
        widget.artistId,
        limit: _pageSize,
      );
      if (!mounted || token != _loadToken) return;
      final page = detail.page;
      final songs = List<OnlineSong>.of(page.items);
      setState(() {
        _artist = detail.artist;
        _songs = songs;
        _hasMore = page.hasMore && songs.isNotEmpty && songs.length < _maxSongs;
        _nextOffset = _resolveNextOffset(page, 0);
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

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    if (_songs.length >= _maxSongs) return;
    final nextOffset = _nextOffset;
    if (nextOffset == null) return;
    final token = _loadToken;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final detail = await OnlineMusicService.instance.artist(
        widget.artistId,
        limit: _pageSize,
        offset: nextOffset,
      );
      if (!mounted || token != _loadToken) return;
      final page = detail.page;
      final items = page.items;
      final songs = [..._songs, ...items];
      setState(() {
        _songs = songs;
        _hasMore = page.hasMore && items.isNotEmpty && songs.length < _maxSongs;
        _nextOffset = page.nextOffset > nextOffset
            ? page.nextOffset
            : nextOffset + items.length;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loadMoreError = error;
        _loadingMore = false;
      });
    }
  }

  /// 后端 nextOffset 异常时退回按已加载条数推进，保证 offset 单调递增。
  int _resolveNextOffset(OnlinePage<OnlineSong> page, int offset) {
    if (page.nextOffset > offset) return page.nextOffset;
    return offset + page.items.length;
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - _loadMoreThreshold) {
      unawaited(_loadMore());
    }
  }

  void _playAll() {
    if (_songs.isEmpty) return;
    unawaited(OnlinePlayback.instance.playSongs(_songs));
  }

  void _openAlbum(String albumId) {
    if (albumId.isEmpty) return;
    context.push('${app_paths.ONLINE_PAGE}/album/$albumId');
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
    final artist = _artist;
    if (artist == null) {
      return Center(
        child: OnlineErrorView(error: '艺术家数据为空', onRetry: _load),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Spacing.lg),
        _buildHeader(scheme, artist),
        const SizedBox(height: Spacing.xl),
        OnlineSectionHeader(
          title: '热门歌曲',
          subtitle: _songs.isEmpty ? null : '${_songs.length} 首',
        ),
        const SizedBox(height: Spacing.sm),
        Expanded(child: _buildTrackList(scheme)),
      ],
    );
  }

  Widget _buildHeader(ColorScheme scheme, OnlineArtist artist) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        return compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildAvatar(artist, compact: true),
                  const SizedBox(height: Spacing.lg),
                  _buildHeaderInfo(scheme, artist),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildAvatar(artist, compact: false),
                  const SizedBox(width: Spacing.xl),
                  Expanded(child: _buildHeaderInfo(scheme, artist)),
                ],
              );
      },
    );
  }

  Widget _buildAvatar(OnlineArtist artist, {required bool compact}) {
    final size = compact ? 140.0 : 180.0;
    return OnlineCoverImage(
      url: artist.avatar,
      size: size,
      borderRadius: BorderRadius.circular(size / 2),
    );
  }

  Widget _buildHeaderInfo(ColorScheme scheme, OnlineArtist artist) {
    final meta = <String>[
      if (artist.musicSize > 0) '${artist.musicSize} 首歌曲',
      if (artist.albumSize > 0) '${artist.albumSize} 张专辑',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          artist.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.hero,
            fontWeight: AppType.weightBold,
            color: scheme.onSurface,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
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
        if (artist.description.trim().isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          _buildDescription(scheme, artist.description.trim()),
        ],
        const SizedBox(height: Spacing.lg),
        FilledButton.icon(
          onPressed: _songs.isEmpty ? null : _playAll,
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

  Widget _buildDescription(ColorScheme scheme, String description) {
    final canExpand = description.length > 100;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          description,
          maxLines: _descriptionExpanded ? null : 3,
          overflow: _descriptionExpanded
              ? TextOverflow.visible
              : TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.body,
            height: 1.4,
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (canExpand)
          TextButton(
            onPressed: () => setState(
              () => _descriptionExpanded = !_descriptionExpanded,
            ),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              _descriptionExpanded ? '收起' : '展开',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.primary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTrackList(ColorScheme scheme) {
    if (_songs.isEmpty) {
      return const Center(
        child: OnlineEmptyView(
          icon: Symbols.music_off,
          text: '暂无热门歌曲',
        ),
      );
    }
    final showFooter = _hasMore || _loadingMore || _loadMoreError != null;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
      itemCount: _songs.length + (showFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _songs.length) {
          return _buildFooter(scheme);
        }
        final track = _songs[index];
        return OnlineTrackTile(
          track: track,
          index: index,
          playlist: _songs,
          trailing: track.albumId.isEmpty
              ? null
              : IconButton(
                  onPressed: () => _openAlbum(track.albumId),
                  icon: const Icon(Symbols.album, size: 20),
                  tooltip: '查看专辑',
                ),
        );
      },
    );
  }

  Widget _buildFooter(ColorScheme scheme) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.lg),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Center(
          child: TextButton(
            onPressed: () => unawaited(_loadMore()),
            child: Text(
              '加载失败，重试',
              style: TextStyle(fontSize: AppType.body, color: scheme.primary),
            ),
          ),
        ),
      );
    }
    if (_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Center(
          child: TextButton(
            onPressed: () => unawaited(_loadMore()),
            child: Text(
              '加载更多',
              style: TextStyle(fontSize: AppType.body, color: scheme.primary),
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
