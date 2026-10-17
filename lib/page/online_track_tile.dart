import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/services/online_music/models.dart' hide OnlinePlayback;
import 'package:pure_music/services/online_music/online_cover.dart';
import 'package:pure_music/services/online_music/online_playback.dart';

// 在线歌曲列表行：序号、封面、标题与歌手专辑、时长。
class OnlineTrackTile extends StatelessWidget {
  const OnlineTrackTile({
    super.key,
    required this.track,
    required this.index,
    this.playlist,
    this.trailing,
    this.onTap,
  });

  final OnlineSong track;
  final int index;
  final List<OnlineSong>? playlist;
  final Widget? trailing;
  final VoidCallback? onTap;

  void _play() {
    final tap = onTap;
    if (tap != null) {
      tap();
      return;
    }
    unawaited(
      OnlinePlayback.instance.playSongs(
        playlist ?? <OnlineSong>[track],
        startIndex: index,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _play,
      hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            OnlineCoverImage(
              url: track.cover,
              size: 44,
              fit: BoxFit.cover,
              borderRadius: AppRadius.smCircular,
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.subtitle,
                      fontWeight: AppType.weightMedium,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  _subtitleRow(context, scheme),
                ],
              ),
            ),
            const SizedBox(width: Spacing.md),
            SizedBox(width: 72, child: Align(
              alignment: Alignment.centerRight,
              child: trailing ?? _durationOrProgress(scheme),
            )),
            const SizedBox(width: Spacing.lg),
          ],
        ),
      ),
    );
  }

  String get _subtitle {
    final album = track.albumName.trim();
    if (album.isEmpty) return track.artistText;
    return '${track.artistText} · $album';
  }

  // 歌手名可点进艺术家详情，其余文本保持原样。
  Widget _subtitleRow(BuildContext context, ColorScheme scheme) {
    final style = TextStyle(
      fontSize: AppType.caption,
      color: scheme.onSurfaceVariant,
    );
    final album = track.albumName.trim();
    final artistId = track.artists.isEmpty ? '' : track.artists.first.id;
    if (artistId.isEmpty) {
      return Text(
        _subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return Row(
      children: [
        Flexible(
          child: InkWell(
            onTap: () => context.push(
              '${app_paths.ONLINE_ARTIST_DETAIL_PAGE}/$artistId',
            ),
            child: Text(
              track.artistText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ),
        if (album.isNotEmpty)
          Flexible(
            child: Text(
              ' · $album',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
      ],
    );
  }

  Widget _durationOrProgress(ColorScheme scheme) {
    return ValueListenableBuilder<OnlineSong?>(
      valueListenable: OnlinePlayback.instance.preparing,
      builder: (context, preparing, _) {
        if (preparing?.id == track.id) {
          return const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        }
        return Text(
          track.duration.toStringHMMSS(),
          style: TextStyle(
            fontSize: AppType.caption,
            color: scheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
