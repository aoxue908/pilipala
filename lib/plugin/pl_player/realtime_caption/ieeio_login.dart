import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'asr_stream.dart';

class IeeioLogin {
  IeeioLogin._();

  static final shared = IeeioLogin._();
  static const _cookies = MethodChannel('pilipala/ieeio_login');
  static const _cookieTimeout = Duration(seconds: 3);
  static bool get supported => true; // 全平台支持（Android / iOS / Windows / macOS / Linux）

  Future<String>? _activeRequest;
  String? _rejectedToken;
  String? _cachedToken;

  /// 清除内存中缓存的 Token，确保用户在网页端重新登录后能立即读取到新 Token
  void clearCachedToken() {
    _cachedToken = null;
    _rejectedToken = null;
  }

  Future<String> loadToken({String? rejectedToken}) async {
    if (rejectedToken != null) {
      _rejectedToken = rejectedToken;
      if (_cachedToken == rejectedToken) _cachedToken = null; // 清掉无效缓存
    }
    // 有有效缓存直接返回
    if (_cachedToken != null && _cachedToken != _rejectedToken) {
      return _cachedToken!;
    }
    final token = await _getOrStart();
    if (token != rejectedToken) return token;
    return _getOrStart();
  }

  Future<String> _getOrStart() =>
      _activeRequest ??= _resolveToken().whenComplete(() {
        _activeRequest = null;
      });

  Future<String> _resolveToken() async {
    // 桌面端（Windows / macOS / Linux）直接使用纯 HTTP 方式极速获取 Demo 会话
    if (!Platform.isAndroid && !Platform.isIOS) {
      return _cachedToken = await _signInWithHttp();
    }
    try {
      final token = await _readStoredToken();
      if (token != null && token != _rejectedToken) return _cachedToken = token;
      if (token != null) {
        await _cookies
            .invokeMethod<void>('clearRejectedLoginToken', token)
            .timeout(_cookieTimeout);
        final replacement = await _readStoredToken();
        if (replacement != null && replacement != _rejectedToken) {
          return _cachedToken = replacement;
        }
      }
      return _cachedToken = await _signInToDemo();
    } on TimeoutException {
      throw const AsrStreamException('读取 QwenASR 会话超时', retryable: true);
    } on PlatformException {
      // 如果调用原生 Cookie 失败，自动降级为 HTTP 协议直连
      return _cachedToken = await _signInWithHttp();
    } on MissingPluginException {
      return _cachedToken = await _signInWithHttp();
    }
  }

  /// 纯 HTTP 方式快速登录 Demo 账号，全平台通用且无须原生 WebView 支持
  Future<String> _signInWithHttp() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(
        Uri.parse('$defaultAsrServer/api/v1/auth/login'),
      );
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set('User-Agent', 'Lynxi-Client');
      request.add(utf8.encode(jsonEncode({
        'email': 'demo@asrclient.dev',
        'password': 'demo123456',
      })));
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final body = await utf8.decoder.bind(response).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final token = data['accessToken'] as String?;
        if (token != null && isIeeioLoginToken(token)) {
          return token;
        }
      }
      throw const AsrStreamException('QwenASR Demo 认证失败，请稍后重试', retryable: true);
    } catch (e) {
      if (e is AsrStreamException) rethrow;
      throw const AsrStreamException('无法连接 QwenASR 认证服务器', retryable: true);
    } finally {
      client.close();
    }
  }

  Future<String?> _readStoredToken() async {
    final cookie = await _cookies
        .invokeMethod<String>('readLoginToken')
        .timeout(_cookieTimeout);
    if (cookie == null) return null;
    try {
      final token = Uri.decodeComponent(cookie);
      return isIeeioLoginToken(token) ? token : null;
    } on FormatException {
      return null;
    }
  }

  Future<String> _signInToDemo() async {
    final controller = WebViewController(
      onPermissionRequest: (request) {
        unawaited(request.deny().catchError((Object _) {}));
      },
    );
    var loadFailed = false;
    try {
      await controller
          .setJavaScriptMode(JavaScriptMode.unrestricted)
          .timeout(_cookieTimeout);
      await controller
          .setNavigationDelegate(NavigationDelegate(
            onNavigationRequest: (request) {
              if (request.url == 'about:blank') {
                return NavigationDecision.navigate;
              }
              final uri = Uri.tryParse(request.url);
              return uri != null &&
                      uri.scheme == 'https' &&
                      isIeeioEndpoint(uri) &&
                      uri.userInfo.isEmpty
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
            onWebResourceError: (error) {
              if (error.isForMainFrame == true) loadFailed = true;
            },
          ))
          .timeout(_cookieTimeout);
      await controller
          .loadRequest(Uri.parse('$defaultAsrServer/login'))
          .timeout(_cookieTimeout);

      final clock = Stopwatch()..start();
      var demoSelected = false;
      while (!loadFailed && clock.elapsed < const Duration(seconds: 15)) {
        final token = await _readStoredToken();
        if (token != null && token != _rejectedToken) return _cachedToken = token;
        if (!demoSelected) {
          try {
            final clicked = await controller
                .runJavaScriptReturningResult(_selectDemo)
                .timeout(_cookieTimeout);
            demoSelected = clicked == true || clicked == 'true';
          } on PlatformException {
            // The document may have been replaced during navigation.
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (loadFailed) {
        throw const AsrStreamException('QwenASR 登录页加载失败', retryable: true);
      }
      throw AsrStreamException(
        demoSelected ? 'QwenASR Demo 登录未完成，请稍后重试' : 'QwenASR 的 Demo 登录入口暂不可用',
        retryable: true,
      );
    } finally {
      unawaited(controller
          .loadRequest(Uri.parse('about:blank'))
          .catchError((Object _) {}));
    }
  }

  static const _selectDemo = r'''
(() => {
  if (location.origin !== 'https://asr.ieeio.com' ||
      !(/^\/login\/?$/.test(location.pathname) ||
        /^#\/login(?:[/?]|$)/.test(location.hash))) {
    return false;
  }
  const labels = new Set([
    '一键demo登录', 'demooneclicklogin', 'demo体验', '体验demo',
    'demo', 'demo登录', '登录demo', 'trydemo', 'trythedemo',
    'demologin', 'loginasdemo'
  ]);
  const normalize = (text) => (text || '').toLowerCase().replace(/[\s_-]+/g, '');
  for (const action of document.querySelectorAll(
    'button, a[href], [role=button], input[type=button], input[type=submit]'
  )) {
    if (action.disabled || action.hidden ||
        action.getAttribute('aria-disabled') === 'true' ||
        !action.getClientRects().length) {
      continue;
    }
    const label = action.innerText || action.value || action.getAttribute('aria-label');
    if (labels.has(normalize(label))) {
      if (!action.dataset.pilipalaDemoRequested) {
        action.dataset.pilipalaDemoRequested = 'true';
        action.click();
      }
      return true;
    }
  }
  return false;
})()
''';
}
