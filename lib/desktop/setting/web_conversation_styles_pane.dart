import 'package:flutter/material.dart';

import '../../features/settings/pages/web_conversation_styles_page.dart';

class DesktopWebConversationStylesPane extends StatelessWidget {
  const DesktopWebConversationStylesPane({super.key});

  @override
  Widget build(BuildContext context) {
    return const WebConversationStylesPage(desktop: true);
  }
}
