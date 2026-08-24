/// Renderer-neutral live state for one tool invocation.
///
/// This stays outside Flutter widgets so both the Flutter and Web conversation
/// viewports consume the same authoritative tool state.
class ToolUIPart {
  const ToolUIPart({
    required this.id,
    required this.toolName,
    required this.arguments,
    this.content,
    this.loading = false,
  });

  final String id;
  final String toolName;
  final Map<String, dynamic> arguments;
  final String? content;
  final bool loading;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'toolName': toolName,
    'arguments': arguments,
    'content': content,
    'loading': loading,
  };
}
