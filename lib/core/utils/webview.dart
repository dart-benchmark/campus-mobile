import 'dart:core';
import 'dart:io';
import 'package:campus_mobile_experimental/app_styles.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

void reloadWebView(String url, WebViewController controller) => controller.loadRequest(Uri.parse(url));

void openLink(String url) async {
  try {
    launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
  } catch (e) {
    // an error occurred, do nothing
  }
}

double validateHeight(context, height) {
  double maxHeight = MediaQuery.of(context).size.height * 0.6; // Limit to 60% of screen height
  if (height == null || height < cardContentMinHeight) {
    height = cardContentMinHeight;
  } else if (height > maxHeight) {
    height = maxHeight;
  }
  return height;
}

/// Opens an arbitrary external URI (maps app, browser, or any other
/// registered handler) outside the in-app browser -- used by the
/// map-navigation JS bridge channel in [WebViewContainer].
void openMapLocation(String uri) async {
  try {
    await launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication); // SINK: PLANTED-Dart-HR-713
  } catch (e) {
    // an error occurred, do nothing
  }
}

/// One native capability the [WebViewContainer] JS bridge can dispatch to
/// by name (see the `BridgeAction` channel) -- a small command pattern so a
/// single channel can expose more than one operation to the page.
abstract class WebBridgeAction {
  void execute(String arg);
}

/// Opens a URL from the bridge -- restricted to http(s) so a compromised
/// page can't use this action to launch arbitrary intents/deep links.
class OpenUrlAction implements WebBridgeAction {
  @override
  void execute(String arg) {
    final String? scheme = Uri.tryParse(arg)?.scheme;
    if (scheme == 'http' || scheme == 'https') {
      launchUrl(Uri.parse(arg), mode: LaunchMode.externalApplication); // SAFE_SINK: PLANTED-Dart-HR-711-safe
    }
  }
}

/// Exports the bridge payload to a local file whose path is taken directly
/// from the JS-supplied argument.
class ExportAction implements WebBridgeAction {
  @override
  void execute(String arg) {
    File(arg).writeAsStringSync(''); // SINK: PLANTED-Dart-HR-711
  }
}
