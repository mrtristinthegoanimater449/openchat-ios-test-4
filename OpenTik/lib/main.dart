import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

const String _appTitle = 'OpenTik';
const String _appUrl = 'https://exclude-certificates-semi-dollar.trycloudflare.com/opentik';
const MethodChannel _notifChannel = MethodChannel('openchat/notifications');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  ));
  runApp(const OpenChatShell());
}

class OpenChatShell extends StatelessWidget {
  const OpenChatShell({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _appTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5865F2),
          brightness: Brightness.dark,
        ),
      ),
      home: const _WebPage(),
    );
  }
}

class _WebPage extends StatefulWidget {
  const _WebPage();

  @override
  State<_WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<_WebPage> {
  late final WebViewController _controller;
  double _progress = 0;

  @override
  void initState() {
    super.initState();

    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      // Sound is a first-class feature here:
      //  * no media type needs a user gesture before it may play;
      //  * video plays inline instead of opening the full-screen player.
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _controller = WebViewController.fromPlatformCreationParams(params)
      ..addJavaScriptChannel('ocNotifBridge', onMessageReceived: (JavaScriptMessage message) {
        _handleNotificationMessage(message.message);
      })
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0F0F0F))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (int progress) {
          if (mounted) setState(() => _progress = progress / 100.0);
        },
        onPageFinished: (String url) async {
          await _controller.runJavaScript(_audioUnlockScript);
          await _controller.runJavaScript(_notificationScript);
          final String status = await _notificationPermission();
          await _setWebNotificationPermission(status);
        },
        onNavigationRequest: (NavigationRequest request) {
          final Uri? uri = Uri.tryParse(request.url);
          if (uri == null) return NavigationDecision.prevent;
          if (uri.scheme == 'http' || uri.scheme == 'https') {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
      ));

    if (_controller.platform is WebKitWebViewController) {
      final WebKitWebViewController webKit =
          _controller.platform as WebKitWebViewController;
      // Camera, microphone and photo-library requests made by the web page
      // (calls, voice messages, uploads) are granted inside this app.  iOS
      // still shows its own system prompt because Info.plist contains the
      // matching usage descriptions.
      webKit.setOnPlatformPermissionRequest((request) => request.grant());
      webKit.setAllowsBackForwardNavigationGestures(true);
    }

    _controller.loadRequest(Uri.parse(_appUrl));

    // Native -> Dart: a notification banner was tapped.  Route the tap to the
    // page so the web UI (which owns routing/toast logic) can react.
    _notifChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'notificationTapped') {
        final String tag = (call.arguments as String?) ?? '';
        try {
          await _controller.runJavaScript(
            'window.__ocNotifTap && window.__ocNotifTap(${jsonEncode(tag)});',
          );
        } catch (_) { /* page gone */ }
      }
      return null;
    });
  }

  Future<String> _notificationPermission() async {
    try {
      final String? status = await _notifChannel.invokeMethod<String>('getPermission');
      return status ?? 'default';
    } catch (_) {
      return 'default';
    }
  }

  Future<void> _setWebNotificationPermission(String status) async {
    try {
      await _controller.runJavaScript(
        'window.__ocNotifSetPermission && '
        'window.__ocNotifSetPermission(${jsonEncode(status)});',
      );
    } catch (_) { /* page not ready */ }
  }

  Future<void> _handleNotificationMessage(String raw) async {
    try {
      final dynamic payload = jsonDecode(raw);
      if (payload is! Map) return;
      switch (payload['action']) {
        case 'show':
          await _notifChannel.invokeMethod('show', <String, Object?>{
            'title': payload['title']?.toString() ?? 'OpenChat',
            'body': payload['body']?.toString() ?? '',
            'tag': payload['tag']?.toString() ?? '',
          });
          break;
        case 'request_permission':
          final String? status =
              await _notifChannel.invokeMethod<String>('requestPermission');
          await _setWebNotificationPermission(status ?? 'default');
          break;
        case 'get_permission':
          await _setWebNotificationPermission(await _notificationPermission());
          break;
      }
    } catch (_) { /* malformed bridge message */ }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            WebViewWidget(controller: _controller),
            // Loading indicator: the OpenChat iOS loading GIF
            // (bundled from assets/build/loading_ios.gif in this repo).
            if (_progress < 1.0)
              Container(
                color: const Color(0xFF0F0F0F),
                alignment: Alignment.center,
                child: Image.asset(
                  'assets/loading_ios.gif',
                  gaplessPlayback: true,
                  fit: BoxFit.contain,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Runs after every page load.  iOS/WKWebView allows media playback without a
// gesture when mediaTypesRequiringUserAction is empty, but the Web Audio API
// (used by OpenChat's notification beep) still starts suspended.  This installs
// a one-time gesture listener that resumes it.  It also tags the page so the web
// UI can tell that it is running inside the native app and starts OpenTik with
// sound on (the web page starts muted because browsers require a tap).
const String _audioUnlockScript = r'''
(function () {
  window.__OC_NATIVE_APP__ = true;

  // OpenTik shows a "Tap for sound" badge and starts its feed muted.  Native
  // autoplay is allowed here, so press that badge for the user.
  try {
    if (location.pathname.replace(/\/+$/, '') === '/opentik') {
      var soundBadge = document.getElementById('sound');
      if (soundBadge) soundBadge.click();
    }
  } catch (e) { /* not OpenTik */ }

  // Track every AudioContext the page creates.  OpenChat's notification beep
  // creates its context lazily, so it must be resumed on the first gesture.
  try {
    var NativeCtx = window.AudioContext || window.webkitAudioContext;
    if (NativeCtx && !window.__ocAudioCtxTracked) {
      window.__ocAudioCtxTracked = true;
      window.__ocAudioContexts = window.__ocAudioContexts || [];
      var TrackedCtx = function (options) {
        var ctx = new NativeCtx(options);
        try { window.__ocAudioContexts.push(ctx); } catch (e) { /* ignore */ }
        return ctx;
      };
      TrackedCtx.prototype = NativeCtx.prototype;
      window.AudioContext = TrackedCtx;
      if (window.webkitAudioContext) window.webkitAudioContext = TrackedCtx;
    }
  } catch (e) { /* older WebKit: the gesture listener below still runs */ }

  if (window.__ocAudioUnlockInstalled) return;
  window.__ocAudioUnlockInstalled = true;
  function unlock() {
    try {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      if (!window.__ocAudioCtx) window.__ocAudioCtx = new Ctx();
      if (window.__ocAudioCtx.state === 'suspended') window.__ocAudioCtx.resume();
      var list = window.__ocAudioContexts || [];
      for (var i = 0; i < list.length; i++) {
        if (list[i].state === 'suspended') list[i].resume();
      }
    } catch (e) { /* the next gesture will try again */ }
  }
  ['touchstart', 'touchend', 'pointerdown', 'click', 'keydown'].forEach(function (ev) {
    document.addEventListener(ev, unlock, true);
  });
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) unlock();
  });
  unlock();
})();
''';

// Notification bridge.  WKWebView does not implement the web Notification
// API at all ('Notification' in window === false), so OpenChat's web UI would
// silently skip desktop-style notifications.  This installs a small polyfill:
//   * window.Notification mirrors the browser API (permission / requestPermission /
//     constructor with onclick and close());
//   * construction posts {action:'show'} to the Dart side over the 'ocNotifBridge'
//     JavaScript channel, which forwards to native UNUserNotificationCenter;
//   * requestPermission() posts {action:'request_permission'} - iOS then shows the
//     official permission dialog on first use, exactly like in Safari.
// onPageFinished() pushes the real native authorization status into the page
// via window.__ocNotifSetPermission(...) so Settings > Notifications renders
// the correct state immediately.
const String _notificationScript = r'''
(function () {
  if (window.__ocNotifBridge) return;
  function post(payload) {
    try { window.ocNotifBridge.postMessage(JSON.stringify(payload)); } catch (e) {}
  }
  function NativeNotification(title, options) {
    options = options || {};
    this.title = String(title);
    this.body = String(options.body || '');
    this.tag = String(options.tag || '');
    this.onclick = null;
    this.onclose = null;
    this.close = function () {};
    this.addEventListener = function (type, fn) {
      if (type === 'click') this.onclick = fn;
      if (type === 'close') this.onclose = fn;
    };
    this.removeEventListener = function () { this.onclick = null; this.onclose = null; };
    this.dispatchEvent = function () { return true; };
    if (this.tag) (window.__ocNotifOnClicks = window.__ocNotifOnClicks || {})[this.tag] = this;
    post({action: 'show', title: this.title, body: this.body, tag: this.tag});
  }
  NativeNotification.permission = 'default';
  NativeNotification.maxActions = 0;
  NativeNotification.requestPermission = function (callback) {
    return new Promise(function (resolve) {
      var done = function (status) {
        if (status !== 'granted' && status !== 'denied') status = 'default';
        NativeNotification.permission = status;
        if (typeof callback === 'function') { try { callback(status); } catch (e) {} }
        resolve(status);
      };
      window.__ocNotifPermissionResolve = done;
      post({action: 'request_permission'});
      // If the page never gets a native answer (older build), fall back to
      // asking native for the current status after 10s.
      window.setTimeout(function () {
        if (window.__ocNotifPermissionResolve === done) {
          post({action: 'get_permission'});
        }
      }, 10000);
    });
  };
  window.__ocNotifSetPermission = function (status) {
    var normalized = (status === 'granted' || status === 'denied') ? status : 'default';
    NativeNotification.permission = normalized;
    var resolve = window.__ocNotifPermissionResolve;
    window.__ocNotifPermissionResolve = null;
    if (resolve) resolve(normalized);
    try {
      document.dispatchEvent(new CustomEvent('openchat-notification-permission',
        {detail: normalized}));
    } catch (e) { /* CustomEvent unavailable */ }
  };
  window.__ocNotifTap = function (tag) {
    var key = String(tag || '');
    var notif = window.__ocNotifOnClicks && window.__ocNotifOnClicks[key];
    if (window.__ocNotifOnClicks) delete window.__ocNotifOnClicks[key];
    if (notif && typeof notif.onclick === 'function') {
      try { notif.onclick.call(notif, {}); return; } catch (e) { /* fall back below */ }
    }
    try { if (location.pathname !== '/') window.location.assign('/'); } catch (e) {}
  };
  window.Notification = NativeNotification;
  window.__ocNotifBridge = true;
})();
''';
