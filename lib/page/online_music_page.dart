import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/online_login_sheet.dart';
import 'package:pure_music/page/online_track_tile.dart';
import 'package:pure_music/page/online_widgets.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/online_music/backend_client.dart';
import 'package:pure_music/services/online_music/backend_process.dart';
import 'package:pure_music/services/online_music/models.dart' hide OnlinePlayback;
import 'package:pure_music/services/online_music/online_cover.dart';
import 'package:pure_music/services/online_music/online_music_service.dart';
import 'package:pure_music/services/online_music/online_playback.dart';

// 在线音乐主页：搜索、推荐歌单、每日推荐和我的歌单。
class OnlineMusicPage extends StatefulWidget {
  const OnlineMusicPage({super.key});

  @override
  State<OnlineMusicPage> createState() => _OnlineMusicPageState();
}

class _AsyncSection<T> {
  T? data;
  Object? error;
  bool loading = false;
  int token = 0;

  void reset() {
    data = null;
    error = null;
    loading = false;
    token++;
  }
}

class _OnlineMusicPageState extends State<OnlineMusicPage> {
  static const double _cardWidth = 150;
  static const double _cardHeight = 222;

  final OnlineMusicService _service = OnlineMusicService.instance;
  final OnlineBackendProcess _backend = OnlineBackendProcess.instance;
  final TextEditingController _searchController = TextEditingController();
  final _AsyncSection<List<OnlinePlaylist>> _recommend = _AsyncSection();
  final _AsyncSection<List<OnlineSong>> _daily = _AsyncSection();
  final _AsyncSection<List<OnlinePlaylist>> _myPlaylists = _AsyncSection();
  final _AsyncSection<List<OnlineSong>> _search = _AsyncSection();

  Timer? _searchDebounce;
  String _searchKeyword = '';
  int _searchOffset = 0;
  bool _searchHasMore = false;
  bool _loadingMore = false;
  Object? _loadMoreError;

  bool _bootstrapped = false;
  bool _bootstrapping = false;
  Object? _bootError;
  bool _restarting = false;
  bool _refreshing = false;
  bool _loggedIn = false;
  int _bootstrapToken = 0;

  @override
  void initState() {
    super.initState();
    _loggedIn = _service.isLoggedIn;
    _service.auth.addListener(_handleAuthChanged);
    _backend.stateNotifier.addListener(_handleBackendState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_bootstrap());
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _service.auth.removeListener(_handleAuthChanged);
    _backend.stateNotifier.removeListener(_handleBackendState);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final token = ++_bootstrapToken;
    setState(() {
      _bootstrapping = true;
      _bootError = null;
    });
    try {
      await _service.ensureReady();
      await _service.refreshAuth();
      if (!mounted || token != _bootstrapToken) return;
      setState(() {
        _bootstrapping = false;
        _bootstrapped = true;
      });
      unawaited(_loadRecommend());
      unawaited(_loadDaily());
      unawaited(_loadMyPlaylists());
    } catch (error) {
      if (!mounted || token != _bootstrapToken) return;
      setState(() {
        _bootstrapping = false;
        _bootstrapped = false;
        _bootError = error;
      });
    }
  }

  void _handleAuthChanged() {
    final loggedIn = _service.auth.value?.loggedIn == true;
    if (loggedIn == _loggedIn) return;
    _loggedIn = loggedIn;
    if (!mounted || !_bootstrapped) return;
    setState(() {});
    unawaited(_loadDaily());
    unawaited(_loadMyPlaylists());
  }

  void _handleBackendState() {
    if (!mounted) return;
    final state = _backend.stateNotifier.value;
    if (state == OnlineBackendState.ready &&
        !_bootstrapped &&
        !_bootstrapping &&
        _bootError != null) {
      unawaited(_bootstrap());
      return;
    }
    setState(() {});
  }

  Future<void> _refreshAll() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _recommend.reset();
      _daily.reset();
      _myPlaylists.reset();
    });
    try {
      await _service.refreshAuth();
      if (!mounted) return;
      unawaited(_loadRecommend());
      unawaited(_loadDaily());
      unawaited(_loadMyPlaylists());
      if (_searchKeyword.isNotEmpty) unawaited(_startSearch(_searchKeyword));
    } catch (_) {
      // 刷新失败交给各区块自己的错误提示。
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _restartBackend() async {
    if (_restarting) return;
    setState(() => _restarting = true);
    try {
      await _backend.restart();
    } catch (_) {
      // 启动失败时由状态监听和页面错误态提示。
    }
    if (!mounted) return;
    setState(() => _restarting = false);
    unawaited(_bootstrap());
  }

  void _checkEnabled() {
    if (!_service.isEnabled) {
      showTextOnSnackBar('请先到 设置 → 播放 → 在线音源 开启');
      return;
    }
    unawaited(_bootstrap());
  }

  Future<void> _loadRecommend() async {
    final section = _recommend;
    final token = ++section.token;
    setState(() {
      section.loading = true;
      section.error = null;
    });
    try {
      final items = await _service.recommendationPlaylists(limit: 16);
      if (!mounted || token != section.token) return;
      setState(() {
        section.data = items;
        section.loading = false;
      });
    } catch (error) {
      if (!mounted || token != section.token) return;
      setState(() {
        section.error = error;
        section.loading = false;
      });
    }
  }

  Future<void> _loadDaily() async {
    final section = _daily;
    if (!_service.isLoggedIn) {
      section.reset();
      if (mounted) setState(() {});
      return;
    }
    final token = ++section.token;
    setState(() {
      section.loading = true;
      section.error = null;
    });
    try {
      final songs = await _service.dailySongs();
      if (!mounted || token != section.token) return;
      setState(() {
        section.data = songs;
        section.loading = false;
      });
    } catch (error) {
      if (!mounted || token != section.token) return;
      setState(() {
        section.error = error;
        section.loading = false;
      });
    }
  }

  Future<void> _loadMyPlaylists() async {
    final section = _myPlaylists;
    if (!_service.isLoggedIn) {
      section.reset();
      if (mounted) setState(() {});
      return;
    }
    final token = ++section.token;
    setState(() {
      section.loading = true;
      section.error = null;
    });
    try {
      final page = await _service.myPlaylists();
      if (!mounted || token != section.token) return;
      setState(() {
        section.data = page.items;
        section.loading = false;
      });
    } catch (error) {
      if (!mounted || token != section.token) return;
      setState(() {
        section.error = error;
        section.loading = false;
      });
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final keyword = value.trim();
    if (keyword.isEmpty) {
      _clearSearch();
      return;
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_startSearch(keyword)),
    );
  }

  void _onSearchSubmitted(String value) {
    _searchDebounce?.cancel();
    final keyword = value.trim();
    if (keyword.isEmpty) {
      _clearSearch();
      return;
    }
    unawaited(_startSearch(keyword));
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    if (_searchController.text.isNotEmpty) _searchController.clear();
    _search.reset();
    setState(() {
      _searchKeyword = '';
      _searchHasMore = false;
      _loadingMore = false;
      _loadMoreError = null;
    });
  }

  Future<void> _startSearch(String keyword) async {
    final section = _search;
    final token = ++section.token;
    _searchDebounce?.cancel();
    setState(() {
      _searchKeyword = keyword;
      _loadingMore = false;
      _loadMoreError = null;
      section.loading = true;
      section.error = null;
      section.data = null;
    });
    try {
      final page = await _service.search(keyword, limit: 30);
      if (!mounted || token != section.token) return;
      setState(() {
        section.loading = false;
        section.data = page.items;
        _searchOffset = page.nextOffset > 0 ? page.nextOffset : page.items.length;
        _searchHasMore = page.hasMore;
      });
    } catch (error) {
      if (!mounted || token != section.token) return;
      setState(() {
        section.loading = false;
        section.error = error;
      });
    }
  }

  Future<void> _loadMore() async {
    final section = _search;
    final keyword = _searchKeyword;
    if (_loadingMore || !_searchHasMore || keyword.isEmpty || section.loading) {
      return;
    }
    final token = section.token;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final page = await _service.search(
        keyword,
        limit: 30,
        offset: _searchOffset,
      );
      if (!mounted || token != section.token) return;
      setState(() {
        _loadingMore = false;
        section.data = [...?section.data, ...page.items];
        _searchOffset = page.nextOffset > 0
            ? page.nextOffset
            : _searchOffset + page.items.length;
        _searchHasMore = page.hasMore;
      });
    } catch (error) {
      if (!mounted || token != section.token) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = error;
      });
    }
  }

  void _playAllDaily() {
    final songs = _daily.data;
    if (songs == null || songs.isEmpty) return;
    unawaited(OnlinePlayback.instance.playSongs(songs));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<OnlineBackendState>(
      valueListenable: _backend.stateNotifier,
      builder: (context, backendState, _) => PageScaffold(
        title: '在线音乐',
        actions: [
          IconButton.filledTonal(
            icon: const Icon(Symbols.refresh),
            tooltip: '刷新',
            onPressed: (_refreshing || !_bootstrapped)
                ? null
                : () => unawaited(_refreshAll()),
            style: IconButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
            ),
          ),
        ],
        body: _body(scheme, backendState),
      ),
    );
  }

  Widget _body(ColorScheme scheme, OnlineBackendState backendState) {
    if (!_service.isEnabled) {
      return OnlineErrorView(
        error: OnlineApiException(
          statusCode: 0,
          code: 'ONLINE_DISABLED',
          message: '在线音源未启用',
        ),
        onRetry: _checkEnabled,
      );
    }
    if (backendState == OnlineBackendState.starting) return _startingView(scheme);
    if (backendState != OnlineBackendState.ready) {
      return _backendUnavailableView(scheme);
    }
    if (_bootstrapping) return _startingView(scheme);
    if (_bootError != null) {
      return OnlineErrorView(
        error: _bootError!,
        onRetry: () => unawaited(_bootstrap()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchBox(scheme),
        const SizedBox(height: Spacing.md),
        Expanded(child: _scrollBody(scheme)),
      ],
    );
  }

  Widget _backendUnavailableView(ColorScheme scheme) {
    final message = _backend.lastError ?? '无法连接在线音源后端，请确认后端已启动';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.cloud_off, size: 32, color: scheme.onSurfaceVariant),
              const SizedBox(height: Spacing.md),
              Text(
                '在线音源后端不可用',
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
              const SizedBox(height: Spacing.lg),
              FilledButton.tonalIcon(
                onPressed: _restarting
                    ? null
                    : () => unawaited(_restartBackend()),
                icon: const Icon(Symbols.refresh, size: 18),
                label: const Text('重新启动后端'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _startingView(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            _restarting ? '正在重新启动在线音源后端…' : '正在启动在线音源后端…',
            style: TextStyle(
              fontSize: AppType.body,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBox(ColorScheme scheme) {
    return Focus(
      onFocusChange: HotkeysHelper.onFocusChanges,
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        onSubmitted: _onSearchSubmitted,
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          prefixIcon: const Icon(Symbols.search, size: 20),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                tooltip: '清除',
                onPressed: _clearSearch,
                icon: const Icon(Symbols.close, size: 18),
              );
            },
          ),
          hintText: '搜索在线歌曲',
          hintStyle: TextStyle(
            fontSize: AppType.body,
            color: scheme.onSurfaceVariant,
          ),
          border: OutlineInputBorder(
            borderRadius: AppRadius.mdCircular,
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  Widget _scrollBody(ColorScheme scheme) {
    final children = <Widget>[_accountBar(scheme), const SizedBox(height: Spacing.lg)];
    if (_searchKeyword.isNotEmpty) {
      children.add(_searchSection(scheme));
    } else {
      children.add(_recommendSection(scheme));
      children.add(const SizedBox(height: Spacing.xl));
      children.add(_dailySection(scheme));
      children.add(const SizedBox(height: Spacing.xl));
      children.add(_myPlaylistsSection(scheme));
    }
    return ListView(
      padding: const EdgeInsets.only(right: 20, bottom: Spacing.bottomNav),
      children: children,
    );
  }

  Widget _accountBar(ColorScheme scheme) {
    return ValueListenableBuilder<OnlineAuthStatus?>(
      valueListenable: _service.auth,
      builder: (context, auth, _) => ValueListenableBuilder<bool>(
        valueListenable: _service.authLoading,
        builder: (context, loading, _) => _accountContent(scheme, auth, loading),
      ),
    );
  }

  Widget _accountContent(
    ColorScheme scheme,
    OnlineAuthStatus? auth,
    bool loading,
  ) {
    final loggedIn = auth?.loggedIn == true;
    final box = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: AppRadius.mdCircular,
      ),
      child: Row(
        children: [
          if (loggedIn)
            OnlineCoverImage(
              url: auth!.avatar.isEmpty ? null : auth.avatar,
              size: 40,
              fit: BoxFit.cover,
              borderRadius: BorderRadius.circular(20),
            )
          else
            Icon(
              Symbols.account_circle,
              size: 36,
              color: scheme.onSurfaceVariant,
            ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loggedIn
                      ? (auth!.nickname.isEmpty ? '已登录' : auth.nickname)
                      : '未登录',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.body,
                    fontWeight: AppType.weightSemibold,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  loggedIn
                      ? auth!.membership.label
                      : (loading ? '正在获取账号信息…' : '登录后可查看每日推荐和我的歌单'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (!loggedIn && loading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (!loggedIn)
            FilledButton.tonalIcon(
              onPressed: () => unawaited(showOnlineLoginSheet(context)),
              icon: const Icon(Symbols.login, size: 18),
              label: const Text('登录'),
            )
          else
            Icon(Symbols.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
    );
    if (!loggedIn) return box;
    return InkWell(
      borderRadius: AppRadius.mdCircular,
      hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
      onTap: () => unawaited(showOnlineLoginSheet(context)),
      child: box,
    );
  }

  Widget _recommendSection(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OnlineSectionHeader(title: '推荐歌单'),
        const SizedBox(height: Spacing.md),
        _sectionBody<OnlinePlaylist>(
          section: _recommend,
          onRetry: _loadRecommend,
          emptyIcon: Symbols.library_music,
          emptyText: '暂无推荐歌单',
          builder: (items) => SizedBox(
            height: _cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: Spacing.md),
              itemBuilder: (context, index) => OnlinePlaylistCard(
                playlist: items[index],
                width: _cardWidth,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _dailySection(ColorScheme scheme) {
    final songs = _daily.data ?? const <OnlineSong>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OnlineSectionHeader(
          title: '每日推荐',
          trailing: _service.isLoggedIn && songs.isNotEmpty
              ? TextButton.icon(
                  onPressed: _playAllDaily,
                  icon: const Icon(Symbols.play_arrow, size: 18),
                  label: const Text('播放全部'),
                )
              : null,
        ),
        const SizedBox(height: Spacing.sm),
        if (!_service.isLoggedIn)
          _loginHint(scheme, '登录后查看每天为你推荐的歌曲')
        else
          _sectionBody<OnlineSong>(
            section: _daily,
            onRetry: _loadDaily,
            emptyIcon: Symbols.today,
            emptyText: '今天还没有推荐歌曲',
            loginHintMessage: '登录后查看每天为你推荐的歌曲',
            builder: (items) {
              final visible = items.take(10).toList();
              return Column(
                children: [
                  for (var i = 0; i < visible.length; i++)
                    OnlineTrackTile(
                      track: visible[i],
                      index: i,
                      playlist: items,
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _myPlaylistsSection(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OnlineSectionHeader(title: '我的歌单'),
        const SizedBox(height: Spacing.sm),
        if (!_service.isLoggedIn)
          _loginHint(scheme, '登录后查看我的歌单')
        else
          _sectionBody<OnlinePlaylist>(
            section: _myPlaylists,
            onRetry: _loadMyPlaylists,
            emptyIcon: Symbols.library_music,
            emptyText: '还没有创建或收藏的歌单',
            loginHintMessage: '登录后查看我的歌单',
            builder: (items) => SizedBox(
              height: _cardHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(width: Spacing.md),
                itemBuilder: (context, index) => OnlinePlaylistCard(
                  playlist: items[index],
                  width: _cardWidth,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _searchSection(ColorScheme scheme) {
    final section = _search;
    if (section.loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OnlineSectionHeader(title: '搜索结果', subtitle: '正在搜索“$_searchKeyword”'),
          const SizedBox(height: Spacing.md),
          _sectionLoading(),
        ],
      );
    }
    if (section.error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OnlineSectionHeader(title: '搜索结果'),
          const SizedBox(height: Spacing.md),
          _sectionError(section.error!, () => _startSearch(_searchKeyword)),
        ],
      );
    }
    final items = section.data ?? const <OnlineSong>[];
    if (items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OnlineSectionHeader(title: '搜索结果'),
          const SizedBox(height: Spacing.md),
          OnlineEmptyView(
            icon: Symbols.search_off,
            text: '没有找到与“$_searchKeyword”相关的歌曲',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OnlineSectionHeader(title: '搜索结果', subtitle: '“$_searchKeyword”'),
        const SizedBox(height: Spacing.sm),
        for (var i = 0; i < items.length; i++)
          OnlineTrackTile(track: items[i], index: i, playlist: items),
        if (_loadMoreError != null) _sectionError(_loadMoreError!, _loadMore),
        if (_searchHasMore)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.sm),
            child: Center(
              child: _loadingMore
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: () => unawaited(_loadMore()),
                      child: const Text('加载更多'),
                    ),
            ),
          ),
      ],
    );
  }

  Widget _sectionBody<T>({
    required _AsyncSection<List<T>> section,
    required Future<void> Function() onRetry,
    required IconData emptyIcon,
    required String emptyText,
    String? loginHintMessage,
    required Widget Function(List<T> items) builder,
  }) {
    final items = section.data;
    if (items == null) {
      final error = section.error;
      if (error != null) {
        // 登录失效只影响当前区块，不打断整页。
        if (loginHintMessage != null && _isLoginRequired(error)) {
          return _loginHint(Theme.of(context).colorScheme, loginHintMessage);
        }
        return _sectionError(error, onRetry);
      }
      return _sectionLoading();
    }
    if (items.isEmpty) return OnlineEmptyView(icon: emptyIcon, text: emptyText);
    return builder(items);
  }

  bool _isLoginRequired(Object error) {
    return error is OnlineApiException &&
        (error.isLoginRequired || error.statusCode == 401);
  }

  Widget _sectionLoading() {
    return const SizedBox(
      height: 120,
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _sectionError(Object error, Future<void> Function() onRetry) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.md,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: AppRadius.mdCircular,
      ),
      child: Row(
        children: [
          Icon(Symbols.error, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Text(
              onlineErrorMessage(error),
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(onRetry()),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _loginHint(ColorScheme scheme, String message) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.md,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: AppRadius.mdCircular,
      ),
      child: Row(
        children: [
          Icon(Symbols.lock, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: AppType.body,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(showOnlineLoginSheet(context)),
            child: const Text('登录'),
          ),
        ],
      ),
    );
  }
}
