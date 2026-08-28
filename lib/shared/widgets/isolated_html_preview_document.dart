import 'dart:convert';

const HtmlEscape _htmlPreviewAttributeEscape = HtmlEscape(
  HtmlEscapeMode.attribute,
);

const String _isolatedPreviewContentSecurityPolicy =
    "default-src 'none'; "
    "script-src 'unsafe-inline' blob:; "
    "style-src 'unsafe-inline'; "
    'img-src data: blob:; '
    'media-src data: blob:; '
    'font-src data:; '
    "connect-src 'none'; "
    "object-src 'none'; "
    "frame-src 'none'; "
    "child-src 'none'; "
    'worker-src blob:; '
    "form-action 'none'; "
    "base-uri 'none'; "
    "navigate-to 'none'";

String wrapHtmlPreviewDocument(String input, {required bool isDark}) {
  final lower = input.toLowerCase();
  if (lower.contains('<html') && lower.contains('<body')) return input;
  final background = isDark ? '#111111' : '#ffffff';
  final foreground = isDark ? '#eaeaea' : '#222222';
  return '''<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
      html, body { background: $background; color: $foreground; margin: 0; padding: 0; }
      .container { padding: 12px; }
      img, video, canvas, iframe { max-width: 100%; height: auto; }
      pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace; }
    </style>
  </head>
  <body>
    <div class="container">
      $input
    </div>
  </body>
</html>''';
}

String buildIsolatedHtmlPreviewDocument(String input, {required bool isDark}) {
  final background = isDark ? '#111111' : '#ffffff';
  final foreground = isDark ? '#eaeaea' : '#222222';
  final preview =
      '''<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="referrer" content="no-referrer" />
    <meta http-equiv="Content-Security-Policy" content="$_isolatedPreviewContentSecurityPolicy" />
    <style>
      html, body { background: $background; color: $foreground; margin: 0; padding: 0; }
      .container { padding: 12px; }
      img, video, canvas { max-width: 100%; height: auto; }
      pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace; }
    </style>
  </head>
  <body>
    <div class="container">$input</div>
  </body>
</html>''';
  final escapedPreview = _htmlPreviewAttributeEscape.convert(preview);
  return '''<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="referrer" content="no-referrer" />
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; frame-src 'self' data: blob:; child-src 'self' data: blob:; worker-src blob:; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; navigate-to 'none'" />
    <style>
      html, body, iframe { width: 100%; height: 100%; margin: 0; border: 0; overflow: hidden; }
      iframe { display: block; }
    </style>
  </head>
  <body>
    <iframe sandbox="allow-scripts" csp="$_isolatedPreviewContentSecurityPolicy" credentialless referrerpolicy="no-referrer" srcdoc="$escapedPreview"></iframe>
  </body>
</html>''';
}

bool isAllowedIsolatedHtmlPreviewUrl(String url) {
  final lower = url.toLowerCase();
  return lower.startsWith('about:') ||
      lower.startsWith('data:') ||
      lower.startsWith('blob:');
}
