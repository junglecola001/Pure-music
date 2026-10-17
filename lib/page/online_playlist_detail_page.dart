import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/online_track_tile.dart';
import 'package:pure_music/page/online_widgets.dart';
import 'package:pure_music/services/online_music/models.dart'
    hide OnlinePlayback;
import 'package:pure_music/services/online_music/online_cover.dart';
import 'package:pure_music/services/online_music/online_music_service.dart';
import 'package:pure_music/services/online_music/online_playback.dart';

/// 在线歌单详情：头部信息加上完整曲目列表。
class OnlinePlaylistDetailPage extends StatefulWidget {
  const OnlinePlaylistDetailPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  State<OnlinePlaylistDetailPage> createState() =>
      _OnlinePlaylistDetailPageState();
}

class _OnlinePlaylistDetailPageState extends State<OnlinePlaylistDetailPage> {
  static const int _pageSize = 100;
  static const int _maxTracks = 1000;

  OnlinePlaylist? _playlist;
  List<OnlineSong> _songs = const [];
  List<String> _missingIds = const [];
  Object? _error;
  bool _loading = true;
  bool _descriptionExpanded = false;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OnlinePlaylistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlistId != widget.playlistId) {
      _descriptionExpanded = false;
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
      final results = await Future.wait<Object>([
        OnlineMusicService.instance.playlist(widget.playlistId),
        _loadAllTracks(),
      ]);
      if (!mounted || token != _loadToken) return;
      final playlist = results[0] as OnlinePlaylist;
      final tracks = results[1] as _TrackBatch;
      setState(() {
        _playlist = playlist;
        _songs = tracks.songs;
        _missingIds = tracks.missingIds;
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

  /// 分页拉取全部曲目：每页 100 首，最多 1000 首。
  /// offset 按已返回条数递增，空页直接停止，避免后端 hasMore 异常时死循环。
  Future<_TrackBatch> _loadAllTracks() async {
    final songs = <OnlineSong>[];
    final missingIds = <String>[];
    var offset = 0;
    while (true) {
      final page = await OnlineMusicService.instance.playlistTracks(
        widget.playlistId,
        limit: _pageSize,
        offset: offset,
      );
      songs.addAll(page.items);
      missingIds.addAll(page.missingIds);
      if (!page.hasMore || songs.length >= _maxTracks) break;
      if (page.items.isEmpty) break;
      offset += page.items.length;
    }
    return _TrackBatch(songs: songs, missingIds: missingIds);
  }

  void _playAll() {
    if (_songs.isEmpty) return;
    unawaited(OnlinePlayback.instance.playSongs(_songs));
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
    final playlist = _playlist;
    if (playlist == null) {
      return Center(child: OnlineErrorView(error: '歌单数据为空', onRetry: _load));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Spacing.lg),
        _buildHeader(scheme, playlist),
        const SizedBox(height: Spacing.xl),
        Expanded(child: _buildTrackList(scheme)),
      ],
    );
  }

  Widget _buildHeader(ColorScheme scheme, OnlinePlaylist playlist) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        final cover = OnlineCoverImage(
          url: playlist.cover,
          size: compact ? 140 : 180,
          borderRadius: AppRadius.mdCircular,
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cover,
              const SizedBox(height: Spacing.lg),
              _buildHeaderInfo(scheme, playlist),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
            const SizedBox(width: Spacing.xl),
            Expanded(child: _buildHeaderInfo(scheme, playlist)),
          ],
        );
      },
    );
  }

  Widget _buildHeaderInfo(ColorScheme scheme, OnlinePlaylist playlist) {
    final meta = <String>[
      if (playlist.creatorName.trim().isNotEmpty) playlist.creatorName,
      if (playlist.playCount > 0) '播放 ${_formatCount(playlist.playCount)}',
      if (playlist.trackCount > 0) '${playlist.trackCount} 首',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          playlist.name,
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
        if (playlist.description.trim().isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          _buildDescription(scheme, playlist.description.trim()),
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
    final canExpand = description.length > 80;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          description,
          maxLines: _descriptionExpanded ? null : 2,
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
          text: '这个歌单还没有可播放的歌曲',
        ),
      );
    }
    final showMissing = _missingIds.isNotEmpty;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
      itemCount: _songs.length + (showMissing ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < _songs.length) {
          return OnlineTrackTile(
            track: _songs[index],
            index: index,
            playlist: _songs,
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.md,
          ),
          child: Text(
            '部分歌曲不可用（${_missingIds.length} 首）',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}

/// 分页曲目结果，避免用 dynamic 承载多返回值。
class _TrackBatch {
  const _TrackBatch({required this.songs, required this.missingIds});

  final List<OnlineSong> songs;
  final List<String> missingIds;
}

String _formatCount(int count) {
  if (count >= 100000000) return '${_trimDecimal(count / 100000000)} 亿';
  if (count >= 10000) return '${_trimDecimal(count / 10000)} 万';
  return '$count';
}

String _trimDecimal(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}
