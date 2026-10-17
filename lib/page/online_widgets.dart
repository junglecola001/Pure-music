import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/services/online_music/backend_client.dart';
import 'package:pure_music/services/online_music/models.dart';
import 'package:pure_music/services/online_music/online_cover.dart';

// 播放量等大数字的紧凑写法：过万用“万”，过亿用“亿”。
String formatOnlineCount(int count) {
  if (count <= 0) return '0';
  if (count >= 100000000) return '${_trimCount(count / 100000000)} 亿';
  if (count >= 10000) return '${_trimCount(count / 10000)} 万';
  return '$count';
}

String _trimCount(double value) {
  final text = value >= 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

class OnlineLoadingView extends StatelessWidget {
  const OnlineLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.xl),
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      ),
    );
  }
}

class OnlineErrorView extends StatelessWidget {
  const OnlineErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return _OnlineStateBody(
      icon: Symbols.cloud_off,
      title: onlineErrorTitle(error),
      message: onlineErrorMessage(error),
      action: onRetry == null
          ? null
          : FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Symbols.refresh, size: 18),
              label: const Text('重试'),
            ),
    );
  }
}

class OnlineEmptyView extends StatelessWidget {
  const OnlineEmptyView({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 28, color: scheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: AppType.body,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OnlineSectionHeader extends StatelessWidget {
  const OnlineSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightBold,
                  color: scheme.onSurface,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: Spacing.md),
          trailing!,
        ],
      ],
    );
  }
}

class OnlinePlaylistCard extends StatelessWidget {
  const OnlinePlaylistCard({
    super.key,
    required this.playlist,
    this.width = 150,
  });

  final OnlinePlaylist playlist;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
        onTap: () =>
            context.push('${app_paths.ONLINE_PLAYLIST_DETAIL_PAGE}/${playlist.id}'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OnlineCoverImage(
              url: playlist.cover,
              size: width,
              fit: BoxFit.cover,
              borderRadius: AppRadius.smCircular,
            ),
            const SizedBox(height: 6),
            Text(
              playlist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.body,
                fontWeight: AppType.weightMedium,
                height: 1.25,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(
                  Symbols.play_arrow,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 2),
                Text(
                  formatOnlineCount(playlist.playCount),
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String onlineErrorTitle(Object error) {
  if (error is OnlineApiException) {
    if (error.code == 'ONLINE_DISABLED') return '在线音源未启用';
    if (error.code == 'BACKEND_UNAVAILABLE' || error.isNetworkError) {
      return '在线音源后端不可用';
    }
  }
  return '加载失败';
}

String onlineErrorMessage(Object error) {
  if (error is OnlineApiException) {
    if (error.code == 'ONLINE_DISABLED') {
      return '在线音源未启用，请到 设置 → 播放 → 在线音源 开启';
    }
    if (error.code == 'BACKEND_UNAVAILABLE' || error.isNetworkError) {
      final detail = error.message.isEmpty ? '无法连接在线音源后端' : error.message;
      return '$detail。请确认后端已启动，或到 设置 → 播放 → 在线音源 重新启动';
    }
    if (error.isLoginRequired) return '登录后即可查看';
    return error.message.isEmpty ? '请求失败（${error.statusCode}）' : error.message;
  }
  final text = '$error';
  return text.isEmpty ? '出现未知错误' : text;
}

class _OnlineStateBody extends StatelessWidget {
  const _OnlineStateBody({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: scheme.onSurfaceVariant),
              const SizedBox(height: Spacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.subtitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.body,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: Spacing.lg),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
