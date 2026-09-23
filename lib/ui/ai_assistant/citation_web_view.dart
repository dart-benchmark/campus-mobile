import 'package:campus_mobile_experimental/ui/common/container_view.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Full-screen web view for TritonGPT citation / source links.
///
/// Pushed from [ChatCitation.openCitation] so the app bar shows **CITATION**
/// (see [RouteTitles]) instead of reusing another feature title such as News.
class CitationWebView extends StatefulWidget {
  const CitationWebView({
    super.key,
    required this.initialUrl,
  });

  final String initialUrl;

  @override
  State<CitationWebView> createState() => _CitationWebViewState();
}

class _CitationWebViewState extends State<CitationWebView> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    final Uri? uri = Uri.tryParse(widget.initialUrl);
    final bool ok = uri != null && uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
    if (!ok) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link.')),
        );
        Navigator.of(context).pop();
      });
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // let the citation page report a dead/broken source link back to the
      // app so it can be forwarded to campus support
      ..addJavaScriptChannel(
        'ReportBrokenLink',
        onMessageReceived: (JavaScriptMessage message) {
          final String decoded = Uri.decodeComponent(message.message);
          final String reportUrl = 'https://support.ucsd.edu/report-link?url=$decoded';
          launchUrl(Uri.parse(reportUrl), mode: LaunchMode.externalApplication); // SINK: PLANTED-Dart-HR-712
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onSslAuthError: (SslAuthError error) {
            error.cancel(); // SAFE_SINK: PLANTED-Dart-HR-714-safe
          },
        ),
      )
      ..loadRequest(uri);
  }

  @override
  Widget build(BuildContext context) {
    final WebViewController? c = _controller;
    return ContainerView(
      child: c == null ? const SizedBox.shrink() : WebViewWidget(controller: c),
    );
  }
}
