class WebFetchContentWindow {
  static const int defaultMaxLength = 5000;
  static const int maximumMaxLength = 20000;

  final String content;
  final int startIndex;
  final int endIndex;
  final int totalLength;

  const WebFetchContentWindow({
    required this.content,
    required this.startIndex,
    required this.endIndex,
    required this.totalLength,
  });

  bool get truncated => endIndex < totalLength;
  int? get nextStartIndex => truncated ? endIndex : null;

  factory WebFetchContentWindow.fromText(
    String text, {
    required int startIndex,
    required int maxLength,
  }) {
    if (startIndex < 0) {
      throw ArgumentError('Invalid startIndex: expected a non-negative value');
    }
    if (maxLength < 1 || maxLength > maximumMaxLength) {
      throw ArgumentError(
        'Invalid maxLength: expected a value from 1 to $maximumMaxLength',
      );
    }
    if (startIndex >= text.length) {
      return WebFetchContentWindow(
        content: '',
        startIndex: text.length,
        endIndex: text.length,
        totalLength: text.length,
      );
    }

    var start = startIndex;
    if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) {
      start -= 1;
    }
    var end = start + maxLength;
    if (end > text.length) {
      end = text.length;
    }
    if (end < text.length &&
        end > start &&
        _isHighSurrogate(text.codeUnitAt(end - 1)) &&
        _isLowSurrogate(text.codeUnitAt(end))) {
      end = end - start == 1 ? end + 1 : end - 1;
    }

    return WebFetchContentWindow(
      content: text.substring(start, end),
      startIndex: start,
      endIndex: end,
      totalLength: text.length,
    );
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
}
