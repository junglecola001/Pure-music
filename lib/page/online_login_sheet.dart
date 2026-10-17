import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/search_dialog_layout.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/services/online_music/backend_client.dart';
import 'package:pure_music/services/online_music/models.dart' hide OnlinePlayback;
import 'package:pure_music/services/online_music/online_cover.dart';
import 'package:pure_music/services/online_music/online_music_service.dart';

// 打开在线音源登录弹层：扫码登录或导入 Cookie。
Future<void> showOnlineLoginSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (context) {
      final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
      final width = (MediaQuery.sizeOf(context).width - 32).clamp(280.0, 420.0);
      return Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(width: width, child: const _OnlineLoginSheet()),
        ),
      );
    },
  );
}

enum _LoginTab { qr, cookie }

class _OnlineLoginSheet extends StatefulWidget {
  const _OnlineLoginSheet();

  @override
  State<_OnlineLoginSheet> createState() => _OnlineLoginSheetState();
}

class _OnlineLoginSheetState extends State<_OnlineLoginSheet> {
  final OnlineMusicService _service = OnlineMusicService.instance;
  final TextEditingController _cookieController = TextEditingController();

  _LoginTab _tab = _LoginTab.qr;
  OnlineQrSession? _session;
  Uint8List? _qrBytes;
  String _qrHint = '';
  Object? _qrError;
  bool _qrLoading = true;
  bool _qrExpired = false;
  int _qrToken = 0;
  Timer? _pollTimer;
  bool _importing = false;
  bool _loggingOut = false;
  String? _cookieError;

  @override
  void initState() {
    super.initState();
    unawaited(_createQr());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _cookieController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.lg,
            Spacing.lg,
            Spacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _titleRow(scheme),
              const SizedBox(height: Spacing.md),
              _accountBox(scheme),
              const SizedBox(height: Spacing.lg),
              _tabs(),
              const SizedBox(height: Spacing.lg),
              if (_tab == _LoginTab.qr) _qrBody(scheme) else _cookieBody(scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleRow(ColorScheme scheme) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '登录在线音源',
            style: TextStyle(
              fontSize: AppType.sectionTitle,
              fontWeight: AppType.weightBold,
              color: scheme.onSurface,
            ),
          ),
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Symbols.close, size: 20),
        ),
      ],
    );
  }

  Widget _accountBox(ColorScheme scheme) {
    return ValueListenableBuilder<OnlineAuthStatus?>(
      valueListenable: _service.auth,
      builder: (context, auth, _) => ValueListenableBuilder<bool>(
        valueListenable: _service.authLoading,
        builder: (context, loading, _) => _accountRow(scheme, auth, loading),
      ),
    );
  }

  Widget _accountRow(ColorScheme scheme, OnlineAuthStatus? auth, bool loading) {
    final loggedIn = auth?.loggedIn == true;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
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
                  loggedIn ? auth!.membership.label : '扫码或导入 Cookie 登录',
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
          if (loading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (loggedIn)
            TextButton(
              onPressed: _loggingOut ? null : _logout,
              child: const Text('退出登录'),
            ),
        ],
      ),
    );
  }

  Widget _tabs() {
    return Row(
      children: [
        SearchCategoryButton(
          label: '扫码登录',
          icon: Symbols.qr_code_2,
          selected: _tab == _LoginTab.qr,
          onPressed: () => setState(() => _tab = _LoginTab.qr),
        ),
        const SizedBox(width: Spacing.sm),
        SearchCategoryButton(
          label: 'Cookie 导入',
          icon: Symbols.cookie,
          selected: _tab == _LoginTab.cookie,
          onPressed: () => setState(() => _tab = _LoginTab.cookie),
        ),
      ],
    );
  }

  Widget _qrBody(ColorScheme scheme) {
    if (_qrLoading) {
      return const SizedBox(
        height: 260,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    }
    final bytes = _qrBytes;
    final session = _session;
    if (bytes == null || session == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
        child: Column(
          children: [
            Text(
              _qrExpired ? '二维码已过期' : '二维码获取失败',
              style: TextStyle(
                fontSize: AppType.body,
                fontWeight: AppType.weightMedium,
                color: scheme.onSurface,
              ),
            ),
            if (_qrError != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                _describeError(_qrError!),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: Spacing.md),
            FilledButton.tonalIcon(
              onPressed: _createQr,
              icon: const Icon(Symbols.refresh, size: 18),
              label: const Text('重新获取二维码'),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: AppRadius.mdCircular,
          ),
          child: SizedBox(
            width: 208,
            height: 208,
            child: Image.memory(
              bytes,
              width: 208,
              height: 208,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
            ),
          ),
        ),
        const SizedBox(height: Spacing.md),
        Text(
          _qrHint.isEmpty ? '用手机扫码登录' : _qrHint,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
        ),
        if (_qrError != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            _describeError(_qrError!),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.error,
            ),
          ),
        ],
        const SizedBox(height: Spacing.sm),
        TextButton.icon(
          onPressed: _createQr,
          icon: const Icon(Symbols.refresh, size: 16),
          label: const Text('刷新二维码'),
        ),
      ],
    );
  }

  Widget _cookieBody(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Focus(
          onFocusChange: HotkeysHelper.onFocusChanges,
          child: TextField(
            controller: _cookieController,
            minLines: 3,
            maxLines: 6,
            style: TextStyle(fontSize: AppType.body, color: scheme.onSurface),
            decoration: InputDecoration(
              hintText: '粘贴完整 Cookie 字符串',
              hintStyle: TextStyle(
                fontSize: AppType.body,
                color: scheme.onSurfaceVariant,
              ),
              border: const OutlineInputBorder(),
              errorText: _cookieError,
            ),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          '在已登录的网页端复制完整 Cookie，包含全部键值对',
          style: TextStyle(
            fontSize: AppType.caption,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.lg),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _importing ? null : _importCookie,
            child: _importing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('导入'),
          ),
        ),
      ],
    );
  }

  Future<void> _createQr() async {
    _pollTimer?.cancel();
    final token = ++_qrToken;
    setState(() {
      _qrLoading = true;
      _session = null;
      _qrBytes = null;
      _qrError = null;
      _qrExpired = false;
      _qrHint = '正在获取二维码…';
    });
    try {
      final session = await _service.createQr();
      if (!mounted || token != _qrToken) return;
      final bytes = _decodeQrImage(session.image);
      setState(() {
        _qrLoading = false;
        _session = session;
        _qrBytes = bytes;
        _qrHint = bytes == null ? '' : '用手机扫码登录';
        _qrError = bytes == null ? '二维码图片无法显示' : null;
      });
      if (bytes != null) _schedulePoll();
    } catch (error) {
      if (!mounted || token != _qrToken) return;
      setState(() {
        _qrLoading = false;
        _qrError = error;
      });
    }
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer(const Duration(seconds: 2), _pollOnce);
  }

  Future<void> _pollOnce() async {
    final session = _session;
    if (session == null || !mounted) return;
    try {
      final poll = await _service.pollQr(session.sessionId);
      if (!mounted || _session?.sessionId != session.sessionId) return;
      switch (poll.state) {
        case OnlineQrState.authorized:
          _finishLogin();
        case OnlineQrState.scanned:
          setState(() => _qrHint = '已扫码，请在手机上确认');
          _schedulePoll();
        case OnlineQrState.waiting:
          setState(() => _qrHint = '用手机扫码登录');
          _schedulePoll();
      }
    } on OnlineApiException catch (error) {
      if (!mounted || _session?.sessionId != session.sessionId) return;
      if (error.isQrExpired) {
        _pollTimer?.cancel();
        setState(() {
          _session = null;
          _qrBytes = null;
          _qrExpired = true;
          _qrError = null;
          _qrHint = '';
        });
        return;
      }
      if (error.isQrBusy ||
          error.isRateLimited ||
          error.isNetworkError ||
          error.code == 'BACKEND_UNAVAILABLE') {
        final wait = error.retryAfterSeconds != null
            ? Duration(seconds: error.retryAfterSeconds!)
            : const Duration(seconds: 2);
        _pollTimer?.cancel();
        _pollTimer = Timer(wait, _pollOnce);
        return;
      }
      setState(() {
        _qrError = error;
        _qrHint = '';
      });
    } catch (error) {
      if (!mounted || _session?.sessionId != session.sessionId) return;
      setState(() {
        _qrError = error;
        _qrHint = '';
      });
    }
  }

  void _finishLogin() {
    _pollTimer?.cancel();
    if (!mounted) return;
    Navigator.of(context).pop();
    showTextOnSnackBar('登录成功', variant: ToastVariant.success);
  }

  Future<void> _importCookie() async {
    final text = _cookieController.text.trim();
    if (text.isEmpty) {
      setState(() => _cookieError = '请粘贴 Cookie');
      return;
    }
    setState(() {
      _importing = true;
      _cookieError = null;
    });
    try {
      await _service.importCookie(text);
      if (!mounted) return;
      Navigator.of(context).pop();
      showTextOnSnackBar('登录成功', variant: ToastVariant.success);
    } on OnlineApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _cookieError = error.code == 'INVALID_COOKIE'
            ? 'Cookie 无效或已过期'
            : _describeError(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _cookieError = _describeError(error);
      });
    }
  }

  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    try {
      await _service.logout();
      await _service.refreshAuth();
    } catch (_) {
      // 退出失败时保留原状态，弹层里可再次操作。
    }
    if (!mounted) return;
    setState(() => _loggingOut = false);
    showTextOnSnackBar('已退出登录');
  }

  Uint8List? _decodeQrImage(String image) {
    final text = image.trim();
    if (text.isEmpty) return null;
    final index = text.indexOf(',');
    final data = text.startsWith('data:') && index >= 0
        ? text.substring(index + 1)
        : text;
    try {
      return base64Decode(data);
    } catch (_) {
      return null;
    }
  }

  String _describeError(Object error) {
    if (error is OnlineApiException) {
      if (error.code == 'ONLINE_DISABLED') return '在线音源未启用';
      if (error.code == 'BACKEND_UNAVAILABLE' || error.isNetworkError) {
        return '在线音源后端不可用，请确认已启动';
      }
      return error.message.isEmpty ? '请求失败（${error.statusCode}）' : error.message;
    }
    return '$error';
  }
}
