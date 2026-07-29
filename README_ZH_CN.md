<div align="center">
  <img src="assets/app_icon.png" alt="Cuplivo Icon" width="100" />
  <h1>为什么选择 Cuplivo？</h1>

  一个 Flutter LLM 聊天客户端 — 社区分支
  
  Kelivo 二群 (QQ) `856321431`

  [Read the English version](README.md)
</div>

### 🔗 兼容性

Cuplivo 是 Kelivo 的一个社区分支，具有强兼容性：

- 备份 zip 格式完整兼容。配置 WebDAV 或 S3（或本地导出 / 导入），恢复从 Kelivo 导出的备份文件即可无缝接续，无需重新配置。
- 已更改包名，以避免冲突。许多开发者可能担心自己改的代码实装后与后续 Kelivo 更新冲突；但安装 Cuplivo **无需卸载、不会覆盖** Kelivo，数据安全双重保障。
- 有真实用户实测。目前已知作者本人和至少 5 位稳定用户在使用，未遇到问题。
- 界面风格继承 Kelivo。整体无大幅改动，原有用户可以快速适应。

#### 🧪 稳定性

本 Fork 的定位是"新功能试验场"，可能会添加一些社区认为有用的新功能，大多依赖简易自测，以期为追求新功能的用户提供更加开箱即用的服务。追求基本的可用性和稳定性（无 P0 Bug，目前暂未遇到过数据损坏/无法开启软件的恶性 Bug），但版本发布更加频繁，审查宽松一些，使用新功能可能出现一些 P1/P2 Level Bug，但反馈会得到及时处理。

我们注意到主仓库 Kelivo 正在进行大规模数据存储的重构。本仓库近期计划仅限兼容其导出的新版 zip。为了数据完整性做出的大多防御性变更未必会被采纳，敬请做好备份。

### ✨ 新功能

Cuplivo 与大多数个人定制 / 单功能 Fork 不同，旨在添加多特性以供更广大的受众尝鲜。随着上游（Kelivo）添加对应功能后，部分项目可能会被移除。

1. **增量备份** — 仅上传自某个选定日期以来的对话和消息，以及附件等。
   - 实测：一次 12.6 MB 的完整备份后，通常仅会产生 50 KB 至 1.5 MB 的增量上传。随着附件和图片的积累，节省效果会更加明显。这降低了带宽与存储开销，也有助于养成更频繁的备份习惯。
   - 注意：仍建议定期进行完整快照备份。

2. **Proactive care（Ta的来信）** — AI 可按设定时间主动向用户发送关怀消息（仅 Android）。
   - 仅 Android：后台闹钟 + 通知渠道，闹钟在强制停止后可恢复
   - *提示*：在助手设置的"Ta的来信"标签页中开启

3. **多 AI 横向对比** — 选择 2 个及以上模型同时回答，在同一界面横向对比回复。择优采用，也可将多份回复总结、融合或评论合成为一个回复（类似更自由的 OpenRouter Fusion）。
   - 桌面端现在每页显示 2 个模型回复，采用双列布局。
   - *提示*：在模型选择器中多选模型后发送消息即可激活

4. **技能 (Skills)** — 从公开 GitHub 仓库导入技能、辅助文件工具。技能持久化存储在文件系统中，并包含在备份中。

5. **记忆模式切换 + 时间注入** — 每助手独立开关，保持系统提示词稳定以提升 API 缓存命中：记忆可在**自动注入**（每次对话自动注入记忆到系统提示词）与**按需工具**（通过 `read_memory` 工具按需读取记忆）间切换；时间注入在每条用户消息后追加缓存友好的时间戳，而非写入系统提示词。开启时间注入时，智能警告对话框会扫描系统提示词与记忆提示词中的易变变量 (#121)。
   - *提示*：为获得最佳缓存性能，建议关闭"最近对话参考"，切换到按需记忆模式并开启时间注入。

6. **SVG 预览** — 在 `svg` 代码块内联渲染 SVG 图表。

7. **对话侧边栏批量操作** — 在侧边栏中批量选择、删除或移动多个对话，提升对话管理效率 (#82)。

8. **供应商级自定义 Headers/Body** — 每个供应商可附加自定义请求头与请求体字段 (#120)。

9. **存储空间管理** — 按时间或大小排序已存储文件，查找未被引用的图片/文件（孤儿），反向定位已存储文件属于哪条聊天记录 (#128)。

10. **增强助手消息直接复制** — 朴素子序列 Markdown 复制 + 引用，快速提取消息内容 (#122)。

11. **TTS 音频：保存到本地 + 朗读选中文本** — 在浮窗播放器中保存云端生成的 TTS 音频至本地文件 (#131)；右键/长按选中的助手消息文本可朗读 (#130)。

12. **每服务器心跳间隔** — 为每个 MCP 服务器单独配置心跳间隔，避免 429 限流 (#108)。

13. **PDF/Office 文件附件** — 支持直接上传 PDF、Word、Excel、PowerPoint 文档作为附件，并提供文档处理配置选项。

14. **美化请求日志** — 在日志查看器中拆分消息与配置，让请求体中的消息轮次更易读 (#127)。

15. **自定义动态主题色** — 通过色相拾取器选择自定义种子色，完全控制应用 accent 颜色 (#107)。

16. **桌面端 Markdown 表格工具栏** — 桌面端表格工具栏支持多格式复制（纯文本、HTML、LaTeX）(#109)。

17. **预设消息** — 预设消息在聊天列表中折叠到切换栏后；仅存在预设消息时阻止新建对话 (#116)。

18. **Thinking 开关** — 每助手独立开关，控制 summary/suggestion/compress/translate/OCR 模型的 thinking (#117)。

19. **仓库其他修复项**
    - **停止按钮强制断流** — 修复自上游 Kelivo v1.1.6 起的长期问题：点击"停止"从未真正断开 TCP 连接，供应商无法收到取消通知，导致后台静默生成和意外的 Token 消耗/多扣费
    - **跨 MCP 同名工具冲突** — 已修复：当多个 MCP 服务器暴露同名工具时，现在会检测并解决冲突（禁用或重命名），而非导致工具调用歧义
    - Gemini 缓存 Token 的准确统计
    - 优化标题生成逻辑（首次失败自动重试）
    - 修复大尺寸 base64 图片导致正则表达式栈溢出的问题
    - 修复 Windows 上 Win+V 剪贴板历史粘贴（Flutter 引擎 Bug 绕过）
    - 其他多项稳定性改进

### ⚠️ 注意事项

Cuplivo 是一个社区分支，尚未与原项目完全切割。赞赏码和社区群组（Discord、QQ）仍指向原作者。过渡期间部分地方可能存在名称混用。

---

<div align="center">
  <img src="docx/screenshot_1.png" alt="聊天界面" width="150" />
  <img src="docx/screenshot_2.png" alt="模型选择" width="150" />
  <img src="docx/screenshot_3.png" alt="工具调用" width="150" />
  <img src="docx/screenshot_4.png" alt="网络搜索" width="150" />
</div>

## 🚀 下载

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/us/app/kelivo/id6752122930)


🔗 [下载最新版本](https://github.com/Chevey339/kelivo/releases/latest)

🔗 [TestFlight](https://testflight.apple.com/join/erbGGykR) 参与测试版体验。

## 💖 赞助

感谢 [siliconflow.cn](https://siliconflow.cn) 与我们合作提供可免费使用的模型。

## ✨ 功能特性

- 🎨 **现代化设计** - Material You 设计语言，支持动态主题色(Android12+)
- 🌙 **深色模式** - 完美适配深色主题，保护您的眼睛
- 🌍 **多语言支持** - 支持中文和英文界面
- 🖥️ **多平台支持** - 移动端与桌面端均支持（Android/iOS/Harmony、Windows/macOS/Linux）
- 🔄 **多供应商支持** - 支持 OpenAI、Google Gemini、Anthropic 等主流 AI 供应商
- 🤖 **自定义助手** - 创建和管理个性化 AI 助手
- 🖼️ **多模态输入** - 支持图片、文本文档、PDF、Word 文档等多种格式
- 📝 **Markdown 渲染** - 完整支持代码高亮、LaTeX 公式、表格等
- 🎙️ **语音服务** - 内置系统 TTS，同时支持 OpenAI / Google Gemini / ElevenLabs 语音服务器
- 🛠️ **MCP 支持** - Model Context Protocol 工具集成
- 🧰 **内置 MCP 工具** - 内置 fetch MCP 工具
- 🔍 **网络搜索** - 集成多种搜索引擎（Bing、DuckDuckGo、Exa、Tavily、智谱、LinkUp、Brave、Metaso、SearXNG、Ollama、Jina、Perplexity、Bocha、Serper、Grok）
- 🧩 **提示词变量** - 支持模型名称、时间等动态变量
- 📤 **二维码分享** - 通过二维码导出和导入供应商配置
- 💾 **数据备份** - 支持聊天记录备份和恢复
- 🌐 **自定义请求** - 支持自定义 HTTP 请求头和请求体
- 🔡 **自定义字体** - 支持自定义字体（系统字体 / Google Fonts）
- ⚙️ **Android 后台生成对话** - 可在后台持续生成消息（可在设置中开启）。

## 📱 平台支持

- ✅ Android
- ✅ iOS
- ✅ Harmony ([kelivo-ohos](https://github.com/Chevey339/kelivo-ohos))
- ✅ Windows
- ✅ macOS
- ✅ Linux

## 🤝 贡献指南

欢迎提交 Pull Request 或创建 Issue！

1. Fork 本仓库
2. 创建您的特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交您的更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启一个 Pull Request

## ❤️ 致谢

特别感谢 [RikkaHub](https://github.com/re-ovo/rikkahub) 项目提供的 UI 设计灵感。Kelivo 的界面设计深受 RikkaHub 优美且实用的设计启发。

## ⭐ Star History

如果你喜欢这个项目，可以给个Star ⭐

[![Star History Chart](https://api.star-history.com/svg?repos=Chevey339/kelivo&type=Date)](https://star-history.com/#Chevey339/kelivo&Date)

## 📄 许可证

本项目采用 AGPL-3.0 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情

## 📞 联系我们

- Issue: [GitHub Issues](https://github.com/Chevey339/kelivo/issues)

---

<div align="center">
Made with ❤️ using Flutter
</div>
