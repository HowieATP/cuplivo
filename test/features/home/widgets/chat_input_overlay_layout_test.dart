import 'package:Cuplivo/features/home/widgets/chat_input_overlay_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('内容铺满可用区域，底部覆盖层贴住底部', (tester) async {
    const rootKey = Key('root');
    const contentKey = Key('content');
    const overlayKey = Key('overlay');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            key: rootKey,
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: ColoredBox(key: contentKey, color: Colors.blue),
              bottomOverlay: SizedBox(key: overlayKey, width: 200, height: 50),
            ),
          ),
        ),
      ),
    );

    expect(tester.getTopLeft(find.byKey(contentKey)).dy, 0);
    expect(tester.getBottomLeft(find.byKey(contentKey)).dy, 600);
    expect(tester.getTopLeft(find.byKey(overlayKey)).dy, 550);
  });

  testWidgets('底部覆盖层内的居中包装不会把输入框推到中间', (tester) async {
    const overlayKey = Key('overlay');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: ColoredBox(color: Colors.blue),
              bottomOverlay: Center(
                child: SizedBox(key: overlayKey, width: 200, height: 50),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.getTopLeft(find.byKey(overlayKey)).dy, 550);
  });

  testWidgets('输入框层位于前景遮罩上方', (tester) async {
    var inputTaps = 0;
    var foregroundTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: const ColoredBox(color: Colors.blue),
              foreground: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => foregroundTaps++,
              ),
              bottomOverlay: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => inputTaps++,
                child: const SizedBox(width: 400, height: 88),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(200, 560));
    await tester.pump();

    expect(inputTaps, 1);
    expect(foregroundTaps, 0);
  });

  testWidgets('底部覆盖层后方有渐变遮罩隔开消息内容', (tester) async {
    const fadeKey = Key('chat-input-overlay-bottom-fade');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: ColoredBox(color: Colors.blue),
              bottomOverlay: SizedBox(width: 200, height: 50),
            ),
          ),
        ),
      ),
    );

    final fadeFinder = find.byKey(fadeKey);
    expect(fadeFinder, findsOneWidget);
    expect(tester.getTopLeft(fadeFinder).dy, 420);
    expect(tester.getBottomLeft(fadeFinder).dy, 600);

    final decoration = tester.widget<DecoratedBox>(
      find.descendant(of: fadeFinder, matching: find.byType(DecoratedBox)),
    );
    final boxDecoration = decoration.decoration as BoxDecoration;
    final gradient = boxDecoration.gradient as LinearGradient;
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.end, Alignment.bottomCenter);
    expect(gradient.colors.first.a, 0);
    expect(gradient.colors[1].a, greaterThan(0.80));
    expect(gradient.colors.last.a, greaterThan(0.95));
  });

  testWidgets('顶部导航栏后方有渐变遮罩隔开消息内容', (tester) async {
    const fadeKey = Key('chat-input-overlay-top-fade');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              content: ColoredBox(color: Colors.blue),
              bottomOverlay: SizedBox(width: 200, height: 50),
            ),
          ),
        ),
      ),
    );

    final fadeFinder = find.byKey(fadeKey);
    expect(fadeFinder, findsOneWidget);
    expect(tester.getTopLeft(fadeFinder).dy, 0);
    expect(tester.getBottomLeft(fadeFinder).dy, 116);

    final decoration = tester.widget<DecoratedBox>(
      find.descendant(of: fadeFinder, matching: find.byType(DecoratedBox)),
    );
    final boxDecoration = decoration.decoration as BoxDecoration;
    final gradient = boxDecoration.gradient as LinearGradient;
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.end, Alignment.bottomCenter);
    expect(gradient.colors.first.a, 1);
    expect(gradient.colors[1].a, greaterThan(0.98));
    expect(gradient.colors[2].a, inInclusiveRange(0.85, 0.90));
    expect(gradient.colors.last.a, 0);
  });

  testWidgets('背景图模式下用背景覆盖顶部且不渲染纯色遮罩', (tester) async {
    const bottomFadeKey = Key('chat-input-overlay-bottom-fade');
    const bottomBackgroundKey = Key('chat-input-overlay-bottom-background');
    const topFadeKey = Key('chat-input-overlay-top-fade');
    const topBackgroundKey = Key('chat-input-overlay-top-background');
    const backgroundKey = Key('background');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatInputOverlayLayout(
              topInset: 100,
              backgroundImageActive: true,
              topBackground: ColoredBox(
                key: backgroundKey,
                color: Colors.green,
              ),
              content: ColoredBox(color: Colors.blue),
              bottomOverlay: SizedBox(width: 200, height: 50),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(bottomFadeKey), findsNothing);
    expect(find.byKey(bottomBackgroundKey), findsOneWidget);
    expect(find.byKey(topFadeKey), findsNothing);
    expect(find.byKey(topBackgroundKey), findsOneWidget);
    expect(find.byKey(backgroundKey), findsNWidgets(2));

    final clipRect = tester.widget<ClipRect>(
      find.ancestor(
        of: find.byKey(topBackgroundKey),
        matching: find.byType(ClipRect),
      ),
    );
    final clip = clipRect.clipper!.getClip(const Size(400, 600));
    expect(clip.height, 116);

    final bottomClipRect = tester.widget<ClipRect>(
      find.ancestor(
        of: find.byKey(bottomBackgroundKey),
        matching: find.byType(ClipRect),
      ),
    );
    final bottomClip = bottomClipRect.clipper!.getClip(const Size(400, 600));
    expect(bottomClip.top, 420);
    expect(bottomClip.height, 180);
  });

  group('键盘弹出（底部 viewInsets）时', () {
    Future<void> pumpLayout(
      WidgetTester tester, {
      Widget? background,
      required Key contentKey,
      required Key inputKey,
      Key? backgroundKey,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              viewInsets: EdgeInsets.only(bottom: 200),
            ),
            child: Scaffold(
              resizeToAvoidBottomInset: true,
              body: ChatInputOverlayLayout(
                topInset: 100,
                background: background,
                content: ColoredBox(key: contentKey, color: Colors.blue),
                bottomOverlay: SizedBox(key: inputKey, width: 800, height: 50),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('内容区域随键盘缩小，输入框仍贴住缩小的底部', (tester) async {
      const contentKey = Key('content');
      const inputKey = Key('input');

      await pumpLayout(
        tester,
        contentKey: contentKey,
        inputKey: inputKey,
      );

      // 默认测试窗口为 800x600，键盘 inset 200 -> body 高度 400。
      expect(tester.getBottomLeft(find.byKey(contentKey)).dy, 400);
      expect(tester.getTopLeft(find.byKey(inputKey)).dy, 350);
      expect(tester.getBottomLeft(find.byKey(inputKey)).dy, 400);
    });

    testWidgets('背景图层覆盖完整窗口高度，不随键盘上移', (tester) async {
      const contentKey = Key('content');
      const inputKey = Key('input');
      const backgroundKey = Key('background');
      double backgroundSeenInsets = -1;

      await pumpLayout(
        tester,
        backgroundKey: backgroundKey,
        background: Builder(
          builder: (context) {
            backgroundSeenInsets = MediaQuery.viewInsetsOf(
              context,
            ).bottom;
            return ColoredBox(key: backgroundKey, color: Colors.green);
          },
        ),
        contentKey: contentKey,
        inputKey: inputKey,
      );

      final bgRect = find.byKey(backgroundKey);
      // 背景保持完整窗口几何：顶部不动、底边延伸到窗口底（键盘下方不可见区域被裁掉）。
      expect(tester.getTopLeft(bgRect).dy, 0);
      expect(tester.getBottomLeft(bgRect).dy, 600);
      expect(tester.getSize(bgRect).height, 600);

      // 背景子树不应再感知键盘 inset（几何已手动补偿）。
      expect(backgroundSeenInsets, 0.0);

      // 内容仍只铺满缩小的 body。
      expect(tester.getBottomLeft(find.byKey(contentKey)).dy, 400);
    });

    testWidgets('渐变条内的背景副本与底层背景保持同一完整窗口几何', (tester) async {
      const baseKey = Key('bg-base');
      const stripKey = Key('bg-strip');

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              viewInsets: EdgeInsets.only(bottom: 200),
            ),
            child: Scaffold(
              resizeToAvoidBottomInset: true,
              body: ChatInputOverlayLayout(
                topInset: 100,
                backgroundImageActive: true,
                background: const ColoredBox(
                  key: baseKey,
                  color: Colors.green,
                ),
                topBackground: const ColoredBox(
                  key: stripKey,
                  color: Colors.green,
                ),
                content: const ColoredBox(color: Colors.blue),
                bottomOverlay: const SizedBox(width: 800, height: 50),
              ),
            ),
          ),
        ),
      );

      // 底层背景铺满整个窗口（800x600），顶部固定。
      expect(
        tester.getRect(find.byKey(baseKey)),
        const Rect.fromLTWH(0, 0, 800, 600),
      );

      // 顶部/底部渐变条内各有一份背景副本，几何必须与底层完全一致，
      // 否则渐变区域会出现随键盘动画错位的重影。
      expect(find.byKey(stripKey), findsNWidgets(2));
      expect(
        tester.getRect(find.byKey(stripKey).first),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
      expect(
        tester.getRect(find.byKey(stripKey).at(1)),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
    });

    testWidgets('无背景图时布局不受影响', (tester) async {
      const contentKey = Key('content');
      const inputKey = Key('input');

      await pumpLayout(
        tester,
        contentKey: contentKey,
        inputKey: inputKey,
      );

      expect(find.byKey(const Key('background')), findsNothing);
      expect(tester.getBottomLeft(find.byKey(contentKey)).dy, 400);
      expect(tester.getTopLeft(find.byKey(inputKey)).dy, 350);
    });

    testWidgets('顶部/底部渐变遮罩仍跟随缩小的 body 而非窗口', (tester) async {
      const contentKey = Key('content');
      const inputKey = Key('input');
      const topBackgroundKey = Key('chat-input-overlay-top-background');
      const bottomBackgroundKey = Key('chat-input-overlay-bottom-background');

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              viewInsets: EdgeInsets.only(bottom: 200),
            ),
            child: Scaffold(
              resizeToAvoidBottomInset: true,
              body: ChatInputOverlayLayout(
                topInset: 100,
                backgroundImageActive: true,
                topBackground: const ColoredBox(color: Colors.green),
                content: const ColoredBox(
                  key: contentKey,
                  color: Colors.blue,
                ),
                bottomOverlay: const SizedBox(
                  key: inputKey,
                  width: 800,
                  height: 50,
                ),
              ),
            ),
          ),
        ),
      );

      // 内层覆盖层栈随键盘缩小为 400 高，两个背景裁剪层都铺满该栈，
      // 不再延伸到窗口底（600）。
      expect(tester.getTopLeft(find.byKey(topBackgroundKey)).dy, 0);
      expect(tester.getBottomLeft(find.byKey(topBackgroundKey)).dy, 400);
      expect(tester.getBottomLeft(find.byKey(bottomBackgroundKey)).dy, 400);

      // 底部渐变裁剪窗口贴住缩小的 body 底部（高度 180）。
      final bottomClipRect = tester.widget<ClipRect>(
        find.ancestor(
          of: find.byKey(bottomBackgroundKey),
          matching: find.byType(ClipRect),
        ),
      );
      final bottomClip = bottomClipRect.clipper!.getClip(const Size(800, 400));
      expect(bottomClip.top, 220);
      expect(bottomClip.height, 180);
    });
  });
}
