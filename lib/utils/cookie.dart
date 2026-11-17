import 'dart:io';
import 'package:pilipala/http/constants.dart';
import 'package:pilipala/http/init.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';

class SetCookie {
  static onSet() async {
    // webview_cookie_manager 仅支持移动端（Android/iOS），桌面端跳过以防抛出 MissingPluginException
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }
    try {
      var cookies = await WebviewCookieManager().getCookies(HttpString.baseUrl);
      await Request.cookieManager.cookieJar
          .saveFromResponse(Uri.parse(HttpString.baseUrl), cookies);
      var cookieString =
          cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
      Request.dio.options.headers['cookie'] = cookieString;

      cookies = await WebviewCookieManager().getCookies(HttpString.apiBaseUrl);
      await Request.cookieManager.cookieJar
          .saveFromResponse(Uri.parse(HttpString.apiBaseUrl), cookies);

      cookies = await WebviewCookieManager().getCookies(HttpString.tUrl);
      await Request.cookieManager.cookieJar
          .saveFromResponse(Uri.parse(HttpString.tUrl), cookies);
    } catch (_) {}
  }
}
