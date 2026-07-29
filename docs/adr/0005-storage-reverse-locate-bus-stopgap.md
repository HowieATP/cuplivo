# ADR-0005: 反向定位采用 MessageLocateBus 作为过渡方案

## Context

存储空间管理新增「反向定位」：从 Storage 页点击某个文件的引用，跳转到引用它的会话与消息并高亮。目标动作 `HomePageController.openGlobalSearchResult({conversationId, messageId})`（`home_page_controller.dart:629`）已存在（全局正文搜索复用），但它锁在 `_HomePageState` 私有控制器内（`home_page.dart:461` 构造），不在根 Provider 树中。Storage 页（桌面是 `DesktopHomePage` 的独立 tab，移动端是 push 路由）无法直接 `context.read<HomePageController>()`。

## Decision

新增一个单例载荷总线 `MessageLocateBus`（镜像现有 `DesktopSettingsNavigationBus` 的形态：`instance.stream` + 类型化载荷 `{conversationId, messageId}`）。
- 聊天页在 `initState` 订阅 → 收到事件调用 `openGlobalSearchResult(...)`（切换会话 + 滚动 + spotlight 高亮）。
- 桌面：`DesktopHomePage` 同时订阅 → 切到 Chat tab（`_tabIndex = 0`）。聊天页在 `IndexedStack` 中常驻，控制器始终存活，故切 tab 与定位可独立发生。
- 移动端：Storage 是 push 路由，聊天页在其下方存活 → fire 总线后 `Navigator.pop` 返回，聊天页接收事件并定位。

此为**过渡方案（stopgap）**，非最终形态。

## Rationale

1. **最小闭环**：总线是纯增量改动，不触碰控制器生命周期与根 Provider 树，对聊天页零回归风险。符合 AGENTS.md「最小改动」「不扩大范围」。
2. **镜像既有先例**：`DesktopSettingsNavigationBus` 已验证「单例载荷总线跨 tab 通信」的模式；`openGlobalSearchResult` 已验证「切换+滚动+高亮」动作。两者复用，无新机制发明。
3. **长期更优解是 Provider，但代价是重构**：`HomePageController` 在 `_HomePageState.initState` 构造，并与页面持有的 `ChatAutoFollowScrollController`（`home_page.dart:434`）纠缠。将其提升到根 `MultiProvider` 需重做构造与滚动控制器接线，是一次独立的、有聊天页回归风险的重构，不应夹带进本功能。

## Considered Options

- **提升 `HomePageController` 到根 Provider 树**（长期更优，本次拒绝）：优点是可测试、依赖图显式、未来任何跨页功能直接 `context.read`，且控制器实际上已具备 app-session 生命周期（桌面 IndexedStack 常驻、移动端聊天路由在栈底）。缺点是本次改动爆炸半径大、与功能开发耦合、回归风险集中在聊天页。结论：作为**后续独立重构任务**跟进，而非在本功能中完成。
- **扩展 `ChatActionBus` 携带载荷**（拒绝）：`ChatAction` 是无载荷 enum，为其加 payload 会改变该总线的形状，影响所有现有监听点。新开一个专用载荷总线更干净。

## Consequences

- **正向**：功能可低风险落地；复用两个已验证先例；桌面/移动端统一一套机制。
- **反向 / 债务**：这是第 4 个单例总线（前三个：`ChatActionBus`、`HotkeyEventBus`、`DesktopSettingsNavigationBus`）。单例总线是不可测试的全局可变状态，会随跨页功能增多而蔓延。**后续应将 `HomePageController` 提升为根 Provider，届时移除 `MessageLocateBus`，改用 `context.read`。** 此债务已记录，不应被遗忘。
- **风险**：总线监听点的注册/注销需对称（`initState` 订阅、`dispose` 取消），否则泄漏或在已销毁 State 上触发动作。
