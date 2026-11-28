# ROADMAP — DevEco Code Desktop

方法论与分阶段计划。核心思路：**通过三层"逆向"分析对齐 deveco 服务端与官方客户端的真实行为**，再决定做什么功能。

## 分析方法论（三层，成本递增、可信度递增）

| 层 | 对象 | 手段 | 得到什么 |
|---|---|---|---|
| L1 协议真相 | 本机 `deveco serve` 的 `GET /doc`（OpenAPI） | curl + 解析 schema | 92 种事件、全部端点、字段级 schema（权威） |
| L2 官方客户端行为 | 内置 Web UI（服务端直接下发的 minified JS bundle） | REA 式静态分析：`grep` 字符串常量、调用点计数 | 官方真实消费的事件族、端点、错误读取方式 |
| L3 上游源码 | opencode（deveco 上游，MIT）、codex（openai/codex，Apache-2.0） | 浅克隆读源码 | 设计模式、UX 决策、边界处理 |

**关于 REA**（[morluto/rea](https://github.com/morluto/rea)）：REA 的价值在**无源码目标**。本项目里对应的就是 L2——deveco 服务端是 149MB Mach-O 二进制 + 内嵌混淆 Web UI，属于典型 REA 场景；但 Web UI 可直接从运行中的服务器下载为 JS 文本，用 grep 级分析即可，暂不需要动用 Ghidra。Codex CLI 本身开源，读源码即可，无需 REA。

## 已确认的协议事实（deveco 0.3.0-stable）

### 事件（SSE `GET /event`，共 92 种）

- 本 App 处理的事件名全部与 schema 一致：`server.connected` / `session.created|updated|deleted` / `message.updated` / `message.part.updated|delta` / `permission.asked` / `session.idle` / `session.status` / `session.error` / `todo.updated`
- 官方 Web UI **不用** `session.next.*` 事件族（0 处引用）和 `permission.v2.*`——继续以传统事件族为准
- 关键字段：`message.part.delta` 带 `field`（必须过滤，只处理 `text`）；`session.error` 的 error 是 `{name, data:{message}}` 嵌套；`session.status.retry` 带 `attempt`/`message`
- 未消费的高价值事件：`question.asked`（Agent 向用户提问）、`file.edited`、`session.diff`、`session.compacted`、`vcs.branch.updated`、`installation.update-available`、`workspace.status`

### 端点

- 已用：session CRUD/归档、prompt_async、abort、message、permission reply、config、provider
- 官方 Web UI 实际在用而 App 未用的：`/session/{id}/compact`、`/fork`、`/revert|/unrevert`、`/summarize`、`/todo`、`/question`（`/api/` 前缀变体）、`/vcs/status|diff`、`/stats/usage`、`/command`、`/skill`、`/share`
- session 与 assistant message 均带 `tokens {input,output,reasoning,cache}` 与 `cost`

## 已实施（2026-11-19）

- 协议对齐修复：session.error 嵌套读取（与官方客户端一致）、delta `field` 过滤、session.status retry 展示（"Retrying · attempt n"）、abort/deletion 状态清理
- Todo 面板：`todo.updated` 事件 + `GET /session/{id}/todo`，消息区上方可折叠卡片（n/m 进度、状态图标）
- 消息用量展示：assistant 消息底部 `↑输入 ↓输出 ⚡︎缓存读 · $成本`
- 设置面板 / 会话管理（重命名·删除·归档·搜索·时间分组）/ 代码块复制（见 README）

## Phase 2 已实施（2026-11-19 第二批）

- **Diff 面板**：`GET /session/{id}/diff` + `session.diff` 事件，文件级 +/− 与统一 diff 视图
- **Compact**：`POST /session/{id}/compact`（实测：bare 路由 200 可用；`/api/` 变体在 deveco 0.3.0 是 503，按文档走会踩坑）
- **Revert/Unrevert**：消息右键回退、横幅状态、`message.removed`/`message.part.removed` 事件对齐
- **⌘K 快速切换**：活动会话 type-to-filter + Enter 直达
- **最近项目**：工具栏 Project 菜单（最多 8 个，持久化，切换自动重启服务）
- **导出 Markdown**：会话转写（含 Thinking 折叠块、工具摘要、用量成本），File 菜单与侧栏右键双入口
- 消息时间戳解码（MessageInfo.time），为更多导出/展示能力铺路

## Phase 2 已实施（2026-11-19 第三批）

- **Question UI**：`question.asked` → 内联问答卡片（单选/多选/自定义回答/Skip），bare 路由 `/question/{id}/reply|reject`（payload `{answers: [[labels]]}`，schema 实测确认）
- **Usage 汇总**：`GET /stats/usage` → 侧栏底部 sessions/messages/cost
- **分支显示**：`GET /vcs` + `vcs.branch.updated` 事件 → 状态栏胶囊（非 git 目录 branch 为 null，静默隐藏）

## Phase 2 剩余项

1. **持续源码对照**：上游仓库已克隆至 `/tmp/deveco-research/{opencode,codex}`，重点读 codex-rs 的 approval/sandbox 模型、opencode 的 session 总结/续聊策略，沉淀 UX 差异清单
2. 视觉打磨：diff 着色渲染（逐行 +/- 着色）、消息内图片/文件附件展示

## Phase 3 已实施（2026-11-19 第一批）

- **斜杠命令系统**：`GET /command` 统一 commands/skills/MCP 三类（`source` 字段区分），输入 "/" 弹出补全面板；发送 "/name args" 路由到 `POST /session/{id}/command`（与官方客户端同构的客户端侧解析）
- **Fork**：会话右键复制（`POST /session/{id}/fork` 返回新 Session）
- **Subagent 会话识别**：`Session.parentID` → 行内 "subagent" 标签
- **首次启动引导**：deveco CLI 缺失时的 Setup 卡片（选二进制 / 重试 / 开设置），ServerManager 增加 `FailureReason` 枚举替代字符串匹配
- **Dock 角标**：待处理权限 + 提问数

## Phase 3 已实施（2026-11-19 第二批）

- **附件展示**：`FilePart{mime,filename,url}` → 消息内可点击 chip（图片/PDF/文本图标），NSWorkspace 打开
- **Diff 着色**：统一 diff 逐行着色（+绿/−红/@@蓝），纯函数 `colorizedDiff` 可测试
- **备份/恢复**：Settings → Server，ditto 打包/还原 deveco 数据目录（参数已在临时目录上实测），恢复前停服 + 二次确认，完成后自动重启

## Phase 3 已实施（2026-11-19 第三批）

- **中英双语本地化**：zh-Hans 全量翻译（约 130 条），`Resources/{en,zh-Hans}.lproj` 随 .app 打包，按系统语言自动切换
- 关键坑位修复：SwiftUI 中三目/运行时 String 走 `Text(StringProtocol)` **不查本地化表**，全部改为 `NSLocalizedString`（状态栏、分组标签、Compacting/Archive 切换、工具状态、You 标签、help 提示）；插值字符串统一 `%@`/`%lld` 格式键

## Phase 3 已实施（2026-11-19 第四批）

- **应用图标重绘**：纯色靛蓝底 + 居中白色蛇头徽记，符合 macOS 圆角矩形规范（1024 画布 824 内容区），`Scripts/make-icon.sh` 一键再生（Swift 绘制 → sips 缩放 iconset → iconutil 出 icns）
- **DMG 分发包**：`Scripts/make-dmg.sh` 产出 `build/DevEco Code Desktop-<version>.dmg`（App + Applications 符号链接），已挂载验证

## Phase 3 已实施（2026-11-20 成熟度打磨，对齐 codex 交互）

- **消息队列**：生成中回车入队（可移除的排队条），session.idle 自动逐条发出
- **会话级状态指示**：session.status 事件覆盖全部会话 → 侧栏行内忙（转圈）/重试（橙色叹号）标记
- **提示词历史**：Option+↑/↓ 回溯最近 50 条（持久化）
- **按会话草稿**：切换会话不丢输入内容
- **完成通知**：UNUserNotificationCenter + 可选提示音，仅对后台完成且此前在生成的会话触发（Settings → Chat 开关）
- **更新横幅**：installation.update-available 事件 → 可关闭的提示条
- **窗口标题**跟随当前会话

## Phase 3 已实施（2026-11-20 第五批：模型目录打通）

- 实测确认：Magpie 写入的 11 个模型本来就在 `GET /config` 的 provider 段里（Desktop 一直能读到）；`/api/model` 才是完整可用模型目录（64 个 = 54 个 opencode 内置免费 + 11 个配置的）
- **模型选择器升级**：接入 `/api/model` 作为权威数据源（按 provider/名称排序、去重），config 自定义模型兜底合并——聊天头部、默认模型、设置三处 Picker 全部覆盖
- 双斜杠模型 ID（`magpie/zcode/GLM-5.3-Flash`）验证：send 按第一个 `/` 拆分为 providerID/modelID，路由正确

# v0.2 成熟度计划（对标 Codex / Claude Code 桌面端）

核心目标：打磨**编码对话主循环**——发指令 → 看 Agent 干活（工具输出、diff 清晰可见）→ 审批 → 续问。
以下协议可行性均已通过 `GET /doc` 实测验证。

## 差距诊断（八支柱自评）

| 支柱 | 现状 | 主要缺口 |
|---|---|---|
| 1. 编码主循环 | ★★☆ | 工具输出不可见（字段已解码未展示）、无代码高亮、无审批档位、流式性能 |
| 2. 信息架构 | ★★★ | 无会话内内容搜索、无子任务树、无置顶、检查点无视觉标记 |
| 3. 输入体验 | ★★★ | 不能编辑重发用户消息、无 Esc 停止、输入框高度固定、命令面板无键盘导航 |
| 4. 安全与信任 | ★★ | 无审批档位、无已保存规则查看器（/api/permission/saved 端点已验证）、Always allow 不透明 |
| 5. 状态可见性 | ★★★ | 无 sticky 当前活动条、无上下文用量、无卡住检测、权限等待无通知 |
| 6. 视觉与动效 | ★★ | 无流式光标、无消息出现动画、颜色/间距 ad hoc 无设计 token |
| 7. 可靠性与性能 | ★★★ | markdown 全量重解析、重启后侧栏空白（无本地缓存）、无统一日志、无性能基线 |
| 8. 分发与文档 | ★★★★ | DMG/图标/本地化已齐；缺关于页（版本/协议/致谢） |

## M1 主循环体感（第一批，2026-11-20 已实施：工具卡片/流式光标+节流/错误内联+Retry/Esc/输入自适应/代码高亮）

**协议发现（实测否决）**：审批模式三档。`PATCH /session/{id}` 的 permission 规则是**追加语义**——发新规则后旧规则仍在（echo 出现同 permission 的 allow+ask 双条），无法替换/清空。硬做切换器会造成"以为在询问、实际在放行"的安全错觉，故撤下；权限卡片 + Always allow 仍是正确路径。待服务端支持替换语义后再做。



1. **工具卡片升级**【S】：可展开完整输出、输入参数摘要、耗时（time.start/end）、复制。字段早已解码，白捡的观感提升
2. **流式光标 + markdown 节流**【M】：流式尾部 ▍ 闪烁光标；markdown 解析节流至 ~150ms，流式期间纯文本、idle 后上格式；长会话滚动 60fps
3. **审批模式三档**【M】：每问询问（默认）/ 放行编辑 / 全放行，聊天头部切换，写入 `PATCH /session/{id}` 权限规则；权限卡片兜底
4. **错误内联气泡 + Retry**【S】：session.error 显示在消息流内，一键重发上一条
5. **Esc 停止生成 + 输入框高度自适应**【S】：键盘肌肉记忆；1~10 行随内容
6. **代码高亮**【M】：手写着色器（字符串/注释/关键字/数字），Swift/JS/TS/Python/Go/Rust/JSON/Shell，零依赖

验收：真实改代码任务全程主窗口完成；8k token 长回复流式滚动不掉帧。

## M2 输入与上下文

7. **编辑用户消息并重发**【M】：右键/悬停编辑 → 自动 revert 到该消息前 → 预填输入框（revert API 已验证）
8. **@文件引用**【L】：@ 弹文件搜索（/api/fs/find），选中作为 FilePart 发送，气泡 chip 展示
9. **图片粘贴/拖拽/剪贴板文件**【M】：落临时文件 → FilePart；消息内缩略图
10. **上下文用量**【S】：会话头部 tokens / 模型 context 上限
11. **会话内搜索 ⌘F**【M】：内容过滤（客户端已有全量消息）
12. **命令面板键盘导航**【S】：↑↓ 选择、Tab 补全

## M3 信任与信息架构

13. **已保存权限规则查看器**【M】：/api/permission/saved 列出永久放行项、可删除——安全透明
14. **子任务树**【M】：/session/{id}/children → subagent 会话树形缩进展示
15. **置顶会话 + 会话内检查点标记线**【S/M】
16. **Sticky 活动条**【S】：滚动离开底部时顶部仍显示"正在运行 bash…"
17. **卡住检测**【M】：busy 但 >60s 无 delta → 提示并可中止
18. **权限后台通知**【S】：等待审批超过 10s 且窗口非前台 → 系统通知
19. **git 未提交变更徽标**【S】：/vcs/status

## M4 质感与工程

20. ~~设计 token 统一~~ ✅ 已实施（Theme.swift 语义色，ChatView/ContentView 清扫完成）
21. ~~消息出现动画~~ ✅ 已实施（新消息淡入+上移过渡）
22. **本地缓存**【M】：重启即显示上次会话列表（服务启动后静默刷新）
23. **统一日志 os_log**【S】+ 网络层瞬时错误重试【S】
24. **大对话性能基线**【M】：500 消息 + 8k token 回复实测，量化并优化
25. **关于页**【S】：版本/协议/上游致谢（opencode MIT、codex Apache-2.0）
26. ~~variant 档位选择~~ ✅ 已实施（2026-11-20，v0.3 第四批）：头部按模型显示档位选择器（实测 10 个 magpie 模型带 low/medium/high/max/none），prompt_async 带 variant 字段，echo 验证 variant: high 生效

## 量化质量基线

- 500 消息会话滚动 60fps；流式期间 CPU 峰值 < 15%（M4 实测）
- 冷启动到可交互 < 2s；杀进程/断网恢复 < 3s 自动重连并刷新
- 每里程碑交付即跑：swift test 全过 + DMG 重打 + 真实任务走查

## 只做十件事清单（影响力/成本排序）

工具输出展开 → 流式光标+节流 → 审批三档 → 错误内联+Retry → Esc+输入自适应 → 代码高亮 → 编辑重发 → @文件引用 → 上下文用量 → 图片粘贴

## 非目标（明确不做）

- PTY 终端集成（重；Agent 自己会跑终端）
- 内嵌编辑器/diff 编辑（定位是对话客户端，不是 IDE）
- Sparkle 自动更新（引第三方依赖；已有更新横幅）

## 风险与约束

- deveco 版本升级可能改事件/端点 → 每次升级重跑 L1/L2 对比（脚本化：`curl /doc` diff）
- 所有第三方代码仅**学习设计**不搬运（Swift vs TS/Rust 本身难搬运），MIT/Apache 协议允许，保持 README 署名即可
- 分析产物在 `/tmp/deveco-research/`（doc.json、webui.js），可随时重新生成

# v0.3 计划（M2 收尾 + 可靠性 + 集成）

v0.2 完成情况：M1 全部落地（审批三档实测否决，见上）；M2 已完成图片粘贴、编辑重发、头部用量、面板键盘导航。
以下依据均已实测：`/api/model` 条目带 `limit.context/output` 与 `capabilities`；`/api/fs/find?query=` 返回相对路径列表；裸 message 端点无分页（全量返回）；`/api/permission/saved` 形状 `{data:[...]}`。

## N1 编码上下文（M2 收尾）

| # | 功能 | 依据 | 体量 | 验收 |
|---|---|---|---|---|
| 1 | **@文件引用**：输入 @ 弹文件搜索（`/api/fs/find`），选中作为 FilePart 发送；路径相对项目根 | find 端点已验证 | L | 引用文件发送后 Agent 能读取该文件 |
| 2 | **拖拽文件到输入框**：与粘贴同通道，项目外路径前置校验 | 粘贴通道已上线 | S | 拖入图片/文件出现 chip |
| 3 | **上下文用量 vs 上限**：头部显示 `45k/200k`（`/api/model` 的 limit.context） | limit 字段已验证 | S | 长会话数值随对话增长 |
| 4 | **⌘F 会话内搜索**：过滤/高亮匹配消息 | 纯客户端 | M | ⌘F 唤起，输入即过滤 |

## N2 可靠性与性能（2026-11-20 已实施：网络重试/本地缓存/os_log/基线）

**性能基线实测数据**（XCTest，Debug 构建）：
- markdown 分段解析 9KB 混排文本：**≈ 0.7ms**（节流周期 120ms 内占比 < 1%）
- 300 条流式 delta 的缓冲+批量刷新：**≈ 7ms**（≈ 23µs/条）
结论：store/解析层不是瓶颈，GUI 渲染按 60fps 目标另行观察；基线测试已入 `PerformanceTests.swift` 防回归。

| # | 功能 | 说明 | 体量 |
|---|---|---|---|
| 5 | ~~性能基线实测~~ | ✅ 已完成（见上） | M |
| 6 | **本地缓存**：重启即显上次会话列表/选中项，服务起来后静默刷新 | 纯客户端 | M |
| 7 | **网络层瞬时错误重试**：APIClient 对 5xx/超时做 1 次退避重试 | 纯客户端 | S |
| 8 | **os_log 统一日志**：服务生命周期/网络错误/事件流异常分级落日志 | 纯客户端 | S |

## N3 集成与信任（2026-11-20 已实施：除多窗口）

已落地：Dock 菜单（新建会话/快速切换）、设置新增 权限（查看/撤销 Always-allow）· 用量（总量+模型明细）· 关于 三页；权限等待 10s 后台通知；卡住检测（busy >60s 无 delta 橙色提示 + Esc 可停）。

| # | 功能 | 说明 | 体量 |
|---|---|---|---|
| 9 | **多窗口**：需按窗口路由会话选择的较大重构，暂缓 | SwiftUI 场景 API | L（改判） |

## 执行约定

- 每批交付三件套：`swift test` 全过 + 真实对话 E2E 回归 + DMG 重打
- 涉及新端点先查 `GET /doc` 并实测（教训：审批规则追加语义、consent 门禁均靠实测提前发现）
- 量化基线沿用：500 消息滚动 60fps、流式 CPU < 15%、冷启动 < 2s、断连恢复 < 3s
- 新增 UI 字符串同步补 zh-Hans 条目

# v0.4 细节扫尾（2026-11-20）

- **abort 语义修正**：停止生成同时清空排队消息（此前队列会在停止后残留并继续吞掉下一条）
- **删除会话清理**：草稿/队列/重发记录/状态图字典同步清除（内存卫生）
- **输入框焦点自动恢复**：切换/新建会话后直接可打字，不再需要手动点输入框
- **侧栏空态 + 自动滚动**：无会话时显示提示文案；选中会话自动滚动到可视区
- **消息内图片内联预览**：data:/file: URL 图片直接渲染缩略图（实测存储保留 data URL），非图片仍是 chip
- **@ 即时文件面板**：实测 fs/find 空查询返回文件列表，打出 @ 即显示面板，不必先输入关键字
- **重命名弹窗自动聚焦**
- **细节打磨**：图片解码 NSCache（流式期间不再重复解码大图）、data: 图片点击打开修复、权限卡片显示挂起总数、消息 meta 显示 variant 档位、ctx 显示支持 Server default 模型上限、⌘F 定位首个匹配
- **事故与恢复记录**：一次脚本变量复用错误将 Models.swift 覆盖为 ChatView 内容，已完整重建（含 MessageRecord/DevCommand/Catalog 等漏项），并确认另一处脚本锚点静默失效（0.25/0.2 描边不一致）——此后脚本编辑一律改为 Read+Edit 精确操作

# v0.5 产品打磨计划（2026-11-20）

目标：从“功能齐全”收敛到“打开就能顺畅工作”。每个阶段都以真实任务走查、`swift test` 和 DMG 重建收尾。

## P0 产品外壳（✅ 第一批已落地）

- [x] 去掉双层侧栏，把 Chat / Models 提升为顶栏切换；会话列表成为唯一左侧栏，释放大屏横向空间
- [x] 会话、模型与供应商页面统一使用居中的最大内容宽度，不再横跨超宽屏
- [x] 新建会话加入项目上下文和三组高质量起手任务，点击后预填并自动聚焦输入框
- [x] 输入框模型菜单按供应商分组，避免几十个模型挤在单一菜单
- [x] 命令补全、@ 文件引用和发送后恢复输入焦点
- [x] 切换会话时显示加载态，避免旧消息与新空态闪烁

## P1 编码主循环可读性（2026-11-20 第一批已实施）

- [x] **滚动跟随暂停 + 回到最新**：ScrollTracker（NSViewRepresentable 观察 SwiftUI ScrollView 底层 NSScrollView 的 clip view bounds/frame 变化）判定距底部 ≤80pt 视为贴底；向上翻历史时暂停 streamTick/messages.count 自动跟随，右下角出现"回到最新"胶囊按钮（regularMaterial），点击回底并恢复跟随；切换会话重置为贴底。注意 LazyVStack 尾部视图会被虚拟化，所以不用锚点 GeometryReader 方案，直接观察 NSScrollView 才可靠
- [x] **消息悬停操作条**：MessageBubble 悬停时右上角浮现操作条（regularMaterial 圆角胶囊）——复制消息文本（仅 text part，复制后变绿勾 1.2s）、编辑重发（仅用户消息）、回退到此处；右键菜单保留
- [x] **顶部 sticky 活动条**：isSending 或 retryInfo 非空时，滚动区上方持续显示一行——当前运行工具名+summary（从 messages 逆序找最后一个 status=="running" 的 tool part）、Todo 进度 n/m、橙色重试状态、红色停止按钮（store.abort()）
- [x] **工具卡片折叠策略 + 复制 + 错误态**：默认策略 = running 展开/完成收起，用户手动切换后以用户为准（userExpanded: Bool?）；运行中显示 mini 转圈；Input/Output/Error 三段全部带复制按钮；错误态红描边 + Error 段常显（不再藏在展开区）+ 红色文本
- [x] **Diff 面板增强**：文件名筛选框（大小写不敏感）、全部展开/收起（allExpanded + expandedFiles 集合，单行收起时自动退出全展态）、头部变更汇总（文件数 + 总 +/−）、行悬浮显示完整路径

验收：一个真实改码任务从提问、工具执行、diff 查看到继续追问，不需要寻找按钮或手动追赶滚动位置。

## P2 输入与会话体验（2026-11-20 已实施）

- [x] **模型与推理强度按会话持久化**：modelsBySession/variantsBySession 字典 + AppSettings.sessionModels/sessionVariants（UserDefaults JSON），select() 时暂存旧会话/恢复新会话，refresh() 清理已删会话的残留项；重启后按会话恢复上次选择
- [x] **排队消息增强**：每条排队 chip 新增 编辑（拉回输入框）/ 立即发送（abort(clearQueue: false) 后直接发这条）/ 移除；拖拽排序（.draggable(id) + .dropDestination，拖到目标 chip 前插入）；abort 增加 clearQueue 参数
- [x] **附件增强**：拖拽悬停时输入框高亮描边（ChatTextView draggingEntered/Exited/Ended 回调）；粘贴图片生成 64pt 缩略图 chip；>1.5MB 图片自动降采样（最长边 ≤1568、JPEG 0.85，压缩失败回退原图并提示；无法解码时按原始字节发送并提示）
- [x] **⌘F 搜索增强**：Enter/Shift+Enter 在匹配间前后跳转（匹配索引 + scroll anchor .center）；搜索栏显示 n/m 计数 + 当前匹配片段（查询词黄色高亮）；用户消息纯文本部分内联高亮所有匹配（highlightedAttributedString，分段拼接避免 AttributedString.Index 转换坑）
- [x] **标题建议**：现有 autoTitleIfNeeded 已满足——首条 prompt 自动命名，仅在标题为空或 "New session" 时生效，手动重命名后不再覆盖（验证确认，无代码改动）
- 新增测试 5 个（P2FeatureTests：高亮全部命中/无匹配 nil/中文保留/降采样最长边/小图跳过）

## Bug 修复（2026-11-20 深度自查第二批）

用户指出"能用和好用差距很大"后做的全路径审查（SessionStore 状态机逐段 + ChatView 交互层 + ChatTextView 键盘/IME/拖拽），确认并修复 8 处：

1. **流式文本重复追加**（必现，数据损坏级）：fallback 轮询每 2s 全量 `loadMessages()` 覆盖 messages 后，pendingDeltas 缓冲未清——flush 时把已包含在快照里的 delta 再 append 一次。修复：快照赋值后 `pendingDeltas.removeAll()`（服务端先写状态后发事件，快照必然包含已收 delta，清空不丢字）
2. **发送失败静默丢消息**：prompt_async 网络失败时只有 errorMessage 横幅，文本不在队列/输入框/任何地方。修复：失败时设置 inlineError（带分类 + Retry 按钮），文本可一键恢复
3. **Esc→立即发送竞态丢消息**：abort POST 在途时 send() 直接触发 prompt_async，与服务端 abort 竞态可能被拒且消息消失。修复：新增 isAborting 状态，abort 窗口内的 send() 自动入队，abort 响应后 flushQueue 放行
4. **flushQueue 竞态丢消息**：performSend 被拒（busy/aborting）时消息从队列移除但未发送。修复：performSend 返回 Bool，flushQueue/sendQueuedNow 被拒时回填队首
5. **编辑排队消息覆盖草稿**：draft 有未完成内容时被直接覆盖丢失。修复：原草稿自动重新入队
6. **permission.replied 字段名不兼容**：不同 deveco 版本用 requestID/permissionID/id 三种键名，只读 id 会导致权限卡片永不消失。修复：三个键名依次回退
7. **权限通知重复轰炸**：多个 pending 权限各自调度 10s 通知任务且互相误触发。修复：每个权限只提醒一次（notifiedPermissionIDs）
8. **revert/编辑重发后 diff/todo 不刷新**：回滚后文件变更集已变，面板显示旧数据。修复：回滚成功后同步刷新 loadDiff/loadTodos
9. **@ 空查询面板 stale**：单独输入 "@" 时显示上一次搜索的残留结果。修复：空查询也发起请求（fs/find 空查询返回文件列表）

新增 QueueHardeningTests 3 个回归测试（编辑排队保草稿/空白草稿不入队/无会话发送不丢 draft）。总 51 测试全过 + smoke test 全绿。

**尚未解决、需要真实使用暴露的问题**（诚实记录）：GUI 渲染层（滚动掉帧、渲染异常）无法用单测覆盖；服务端怪癖（内置模型 Model not found 等）只能分类提示不能根治；多窗口/会话树/置顶等信息架构项在 v0.6 候选清单。

## Bug 修复（2026-11-20 自查第一批）

1. **select() 恢复会话时 variant 被 didSet 级联清空**（必现逻辑错误）：先设 selectedModel 触发 didSet → selectedVariant = nil → variant didSet 把 `variantsBySession[新会话]` 写成 ""，随后才读回，该会话存的强度选择丢失。修复：先捕获 restoredVariant/restoredModel 再赋值。同时修复无会话级选择时回落 nil、丢失全局默认模型的问题（有 "" 条目 = 用户明确选 Server default；无条目 = 回落 AppSettings.defaultSessionModel）。回归测试 ×2
2. **sendQueuedNow 与 abort 竞态**：abort 的 POST 原本是发后不管，紧接着发 prompt_async 可能撞上服务端仍 busy。修复：abort 拆为 `performAbort(clearQueue:) async` 可等待版本 + 同步包装，sendQueuedNow 改 async 等待 abort 响应后再发送

验收：连续切换多个会话、连续排入多条任务、引用多个文件时，不丢草稿、不丢附件、不误发。

## P3 可靠性与性能（2026-11-20 已实施第一批：统一状态条/失败分类/诊断复制）

- [x] **统一连接状态条**：工具栏下方的 ConnectionStatusStrip，覆盖全部故障态——starting（转圈+端口）、failed（FailureReason 本地化标签 + 错误详情 + Retry + Show Log）、stopped（Start Server 按钮）、SSE 断连重连中（"连接中断，正在重连… 第 n 次尝试"，SessionStore.isReconnecting + reconnectAttemptCount）；条随状态淡入淡出
- [x] **Provider 失败原因分类**：FailureKind 六类（auth/quota/modelUnavailable/network/server/unknown），状态码优先（401/403→auth、402/429→quota、404→model、5xx→server）+ 关键词兜底；InlineErrorBubble 显示分类图标/标签 + 可操作建议 hint；session.error 无 sessionID 时横幅加分类前缀；APIError.kind 供本地请求错误复用
- [x] **诊断信息一键复制**：ServerManager.diagnosticsReport()（App 版本/build、macOS 版本、服务状态与端口、项目目录、deveco/Node 路径、数据目录、日志路径、最近错误、server.log 尾部 800 字符）；设置 → Server 新增 Copy Diagnostics 按钮（复制后绿色 ✓ 1.6s）
- 新增 P3ReliabilityTests 8 个（六类分类、状态码优先级、unknown 兜底、诊断报告关键字段）

- [x] **长会话性能基线（500 消息规模，2026-11-20 实测，Debug 构建 XCTest）**：
  - 300 条 delta 管线在 500 消息会话中 ≈ 9ms（≈30µs/条）——与单消息规模几乎持平，O(n) 消息定位成本在 500 条时可忽略
  - ⌘F 全量过滤 500 消息 ≈ 12ms/次击键（可接受；若将来加节流有余量）
  - markdown 9KB 分段解析 ≈ 0.7ms（复测一致）
  - 测试入 PerformanceTests（test500MessageDeltaPipelinePerformance / test500MessageSearchFilterPerformance），每轮迭代重建 500 消息防止累计膨胀
- [x] **2026-11-29 长会话性能优化（第二轮，四方向）**：
  - 行推导缓存 `TranscriptRows.swift`：前缀 checkpoint + 尾部重折，指纹覆盖 id/role/时间戳/part 类型/文本长度与工具状态（status/title/output/error 长度、起止时间）。500 消息流式每帧 **59 ms → 0.46 ms（128×）**，首帧 99 ms（一次性建 checkpoint）
  - 缓存只保存「装饰」（日期分隔、合并 reasoning、工具分组、模型切换提示），不保存 `MessageRecord`：每帧与调用方当前消息配对，封存消息的迟到更新（用量/成本/模型、工具输出）不可能渲染成旧内容；`revision` 未变时整份结果直接复用，`body` 因 `isSending`/草稿等无关状态重算不再付出折叠成本
  - 结构拆分：ChatView.swift **5068 → 1648 行**，拆出 ChatRendering / TranscriptRowsView / ChatComposer / MessageBubbleView / MarkdownView / ChatCards；`TranscriptRowsTests` 14 例对旧全量折叠做等价校验（含封存消息迟到更新、同条数会话切换、revision 未变复用）
  - 包体积：`build-app.sh` 加 `strip -x`，二进制 **11.1 → 3.0 MB**，DMG **2.2/2.3 → 1.8/2.0 MB**（dSYM 保留，崩溃报告可符号化）；`-dead_strip`/thin LTO 实测无效
  - 稳定性：`NotificationObserverBag` 管理 SessionStore 观察者（deinit 移除）；`applicationSupportDirectory()` 空数组回退；去掉 `serverProcess!` 强解包
  - 死代码清理：`EarlyLanguageSetup.swift`、`TimelineNotice`/`timelineNotices`（从未写入）、`LinkText` 的 `searchQuery` 补上实现（流式气泡此前 ⌘F 不高亮）、`chatFontMenu`（被工具栏溢出菜单取代）、`providerColor`、`questionResult`、`decodePart`、ProviderEditorView 未用的 `dismiss`；拆分文件里未用的 `import UniformTypeIdentifiers`
  - 冷启动基线：`open` 到首窗 **0.38 s**（strip 前后一致，远低于 2 s 目标）
  - 验证：`swift build`（debug/release）零警告；`swift test` **248/248**
- [x] **本地 smoke test**：`Scripts/smoke-test.sh`——独立临时数据目录起 `deveco serve` → 健康 → consent → 建会话 → prompt_async → SSE 等 session.idle（同时捕获 session.error 给出原因）→ 验证 assistant 消息 → 删会话 → 清理，全程不触碰用户数据，连跑两次全绿
  - **协议发现（实测）**：`/api/model` 返回 `{data:[{providerID,id,status,...}], location:{...}}`——location 是目录元信息不是 provider；prompt_async 不传 model 字段时全新数据目录自动落到 opencode 内置免费模型（无需任何 key）；显式传 `{"providerID":"opencode","modelID":"tidepool-alpha-free"}` 反而报 "Model not found"（服务端对内置 provider 的解析怪癖，用户配置的 magpie 模型用同一形状则正常）

验收：断网、杀服务、Provider 限流三种故障都能明确显示原因，并在恢复后继续同一会话。

## P4 分发与发布（2026-11-20 已实施）

- [x] **版本号与 build number 自动化递增**：`Scripts/release.sh`（major/minor/patch/--version 四种模式，CFBundleVersion 每次发布 +1，写回 Info.plist），DMG 文件名带版本
- [x] **Release Notes + SHA-256**：release.sh 产出 `build/ReleaseNotes-<version>.md`（RELEASE_NOTES 环境变量自定义，缺省从 ROADMAP 抽取最近 15 条完成项）+ `<dmg>.sha256`（shasum -a 256 -c 可验）；v0.5.0 已产出三件套
- [x] **权限与签名文档**：RELEASE.md——持久自签名证书原理（避免 ad-hoc 丢 TCC 权限）、未公证的 Gatekeeper 首启步骤、无需 TCC 特权的说明、依赖与 consent 处理；README 加发布入口
- [x] **干净目录安装验收**：挂载 DMG → 复制到全新临时目录 → codesign 校验 → 版本核对 → 启动存活 6s → 干净退出；v0.5.0 (build 3) 全过。发现并修复 release.sh 变量名冲突 bug（NOTES 环境变量与内部路径变量重名导致 Notes 正文丢失）

验收：交付物可重复构建（smoke test ×2 全绿 + release.sh 重跑验证）、签名身份稳定、安装后无需额外配置即可连接本地 deveco。

## 多会话状态隔离（2026-11-20 已实施）

针对“切换会话后误停止、误排队、附件串会话”的状态污染问题，完成一轮会话级状态机收口：

- **运行状态按会话隔离**：`activeSessionIDs` / `abortingSessionIDs` 取代全局 `isSending` / `isAborting`；当前选中的空闲会话不会再继承后台会话的生成状态，后台会话完成/失败也不会改写当前会话。
- **不可变 PromptSnapshot**：发送时一次性捕获 `text/model/variant/attachments`；排队、编辑后重发、失败重试都使用各自快照，不再读取可能已经切换的全局输入框状态。
- **附件按会话暂存**：切换会话恢复各自附件；发送后只移除已被快照接管的附件，避免重复发送或把 A 会话附件带入 B 会话。
- **显式会话参数**：`performSend`、`flushQueue`、`abort`、`retryLastPrompt` 均接收明确的 `sessionID`；重试状态与 fallback polling 也按会话保存。
- **后台错误不串台**：`session.error` / `session.status` / `session.idle` 按事件所属会话更新；后台失败只显示全局摘要，不再出现在当前会话的内联错误区。
- 新增 `SessionIsolationTests` 4 项回归：忙碌状态不泄漏、重试状态隔离、附件隔离、编辑排队消息恢复其快照附件；测试会保存并恢复 `UserDefaults`，不污染真实偏好。

验证：`swift test` 55/55 通过；`swift build -c release` 通过；`Scripts/smoke-test.sh` 真实服务全链路通过。

### 多会话注意力提示（2026-11-20 继续完善）

- **侧栏/⌘K 状态徽标**：按用户优先级显示“需要授权（含待处理数量）→ 需要回答（含数量）→ 会话失败 → 重试中 → 生成中 → 完成未读”，避免后台任务需要决策时被忽略。
- **后台失败可追溯**：错误改存于会话级字典，后台会话失败不再只留一条容易被覆盖的全局提示；切换到该会话后仍能看到分类、原始错误、建议与 Retry。
- **完成未读**：后台会话从忙碌转为 idle 时标记未读；若队列立即开始下一条则保持忙碌；打开会话即清除未读。
- **测试**：新增 3 项回归（授权/提问计数与隔离、后台失败跨会话保留、完成未读清除），总计 58/58。

后续候选：fallback polling 仅在 SSE 断连或长时间无 delta 时启用；排队消息显示附件数量；模型选择器增加搜索/最近使用。

## 对话可读性与字号（2026-11-20 继续完善）

- **消息层级重做**：用户消息右对齐、助手消息左对齐，加入角色头像、圆角气泡、浅描边和 18pt 消息间距；宽屏下助手内容仍限制在 900pt 阅读列内。
- **耗时可见**：每条助手回复显示创建时间与整轮耗时；每个工具调用显示独立耗时胶囊；小于 10ms 显示 `<0.01s`，分钟级使用 `1m 05s`。
- **文字格式增强**：助手正文新增标题、有序/无序列表、引用块、分隔线等块级解析；保留行内粗体/斜体/代码；段落使用随字号缩放的行距和块间距。
- **字号统一生效**：聊天头部新增 **Aa** 菜单（13–30pt、默认 16pt、快捷增减、预设档位）；同一设置现在同步作用于正文、输入框、代码块、思考过程、工具输出和消息元信息。旧版 13pt 默认值做一次性迁移，不覆盖后续手动选择。
- **设置预览**：Settings → Chat 增加实时字号预览和代码示例，调整时立即可见。
- 新增 3 项回归测试（耗时格式、Markdown 块解析、字号缩放边界），总计 61/61。

## Codex 风格 UI 精修（2026-11-20 继续完善）

- **阅读列收口**：宽屏阅读列从 900pt 降到 760pt，消息间距提升到 26pt，正文默认字号再提升到 16pt（范围 13–30pt），元信息与代码最小字号同步放大。
- **消息层级**：用户消息改为内容自适应宽度的低对比右对齐气泡；助手消息去除卡片与头像，改为左侧正文流。整轮耗时移到回复顶部（"用时 3.41 秒"），模型名、token 与费用降为底部弱化元信息。
- **隐藏内部部件**：`step-start` / `step-finish` / `snapshot` / `patch` 不再以原始文本形式泄漏到转写中。
- **工具卡重做**：按 bash/edit/read/search/web 显示不同图标与色调，标题优先展示工具语义摘要，耗时右对齐；卡片改为低对比填充 + 发丝描边，去掉胶囊与重边框。
- **输入区重做**：模型、推理强度、发送按钮统一收到输入容器底部；用户/助手模型名去掉内部 id 后缀（如 `Hy4 flash (hy4flash)` → `Hy4 flash`）；发送键改为 Codex 式圆形主按钮，禁用态保留可见描边；附件 chip 收进同一容器。
- **侧栏与工具栏**：会话列表从系统 List 改为自定义分组滚动列表（轻量选中态、悬停态、分组小标题）；顶部改成紧凑的聊天/模型分段切换、状态胶囊、项目名与图标操作，去掉笨重分段控件。
- **本地化**：新增"会话、用时、查看文件变更、压缩会话"以及中文耗时单位（秒/分）。
- 验证：`swift test` 61/61；`Scripts/smoke-test.sh` 真实 `deveco serve` 全链路通过；真机输入框输入、模型菜单、字号菜单逐项验证。

## 服务启动状态修复（2026-11-20 继续完善）

- **启动期间防 App Nap**：`deveco serve` 引导期间持有 `ProcessInfo.beginActivity(.userInitiated)`，避免应用在后台被系统节流导致健康检查迟迟不推进。
- **健康探针显式超时**：改为 1.2s 超时的 uncached `URLRequest`，避免继承 URLSession 的长默认超时；成功后统一走 `markRunning()` 清理错误与活动令牌。
- **回前台立即复查**：监听 `NSApplication.didBecomeActiveNotification`，启动中或被挂起时立即探测；服务其实已健康会直接切到“已连接”。
- **失败重试可用**：`start()` 在 failed 且仍有存活子进程时先停掉旧进程再重启，不再出现点击“启动服务”无反应。
- 验证：清空旧服务后冷启动 5 秒内进入“已连接”；`swift test` 61/61。

## 推理强度选择修复（2026-11-20 继续完善）

- **新会话不再隐藏强度**：会话处于“服务端默认”时，用全局默认模型解析可用 variants，强度选择器正常出现。
- **选择即固定模型**：在“服务端默认”下选择强度时先固定当前实际模型，再写入 variant，避免只改强度却不知道该发给哪个模型。
- **档位本地化**：low/medium/high/xhigh/max/none 显示为低/中/高/极高/最高/无；当前档位用勾选表示。
- **入口更明确**：强度按钮加滑杆图标与“强度：默认 / 强度：高”文案，不再只是灰色“默认强度”。

## 可读性二次打磨与自动标题兜底（2026-11-20 继续完善）

- **辅助字号对齐 Codex**：聊天正文 16pt，次级文字 14pt，微元信息 12pt，代码 14pt；侧栏标题 14pt、路径 12pt、时间 12pt，工具卡标题/耗时、状态栏与连接提示使用 12–14pt。
- **交互控件对齐**：顶部会话标题 15pt，搜索、文件变更、压缩按钮与 Aa 字号码统一到 11.5–13.5pt；欢迎页起始提示、输入框模型/强度菜单、排队消息和 Todo 面板同步收口。
- **自动标题兜底**：除发送时按首条 prompt 命名外，加载已有消息时若标题仍为空 / `New session` / `Untitled session`，也会用首条用户消息回填；48 字符截断，`/` 命令不参与命名。
- 验证：`swift test` 61/61；真机把已有会话改回 `New session` 后切走再切回，标题自动恢复为首条消息内容。

## Codex 色板与扁平图标（2026-11-20 继续完善）

- **背景色对齐**：主画布 `#181818`、侧栏与顶部栏 `#242424`、输入框 `#343434`，与 Codex 实测色值一致；浅色模式保留对应的中性灰白，不强制全局深色。
- **表面统一**：搜索栏、活动条、Todo 面板、命令面板和弹窗统一使用 chrome 表面色，避免局部仍是系统默认的 `#1E1E1E` / `#323232`。
- **图标扁平化**：移除紫蓝渐变、气泡和星光，改为纯色 `#4F46E5` 圆角底 + 居中的白色终端瓦片（`>_`），小尺寸 Dock/Finder 下仍清晰可辨。
- **字号回正**：正文保持 Codex 的 16pt，侧栏/工具栏/元信息收回到 12–16pt，避免上一轮局部放大后比 Codex 更粗更大。
- 验证：`swift build` 通过；`swift test` 61/61；真机取色确认主画布 `#181818`、侧栏 `#242424`、输入框 `#343434`。

## 字号按 Codex 实测值校准（2026-11-20 继续完善）

- **Codex 源值**：从 `/Applications/ChatGPT.app/Contents/Resources/app.asar` 确认 `--codex-chat-font-size:16px`、`--codex-chat-code-font-size:0.875rem`（14px）、`--text-sm:14px`、`--text-xs:12px`。
- **聊天正文**：16pt，与 Codex 一致；Aa 菜单仍可在 13–30pt 间调整。
- **代码/次级文字/微元信息**：代码 14pt，工具摘要与次级标签 14pt，模型 token、耗时、路径、时间等微元信息 12pt。
- **界面层级**：侧栏标题 16pt、会话行 14pt；顶部导航/项目名 14pt、会话标题 16pt；输入框模型/强度 14pt、聊天条微元信息 12pt。
- 验证：`swift build` 通过；`swift test` 61/61；真机截图对照 Codex 的字号层级。
- 验证：新会话中打开强度菜单、选择“高”、重开菜单确认勾选并保持；`swift test` 61/61。

## Codex 正文视觉匹配与图标刷新（2026-11-20 继续完善）

- **正文默认值定案**：Codex CSS 的 `--codex-chat-font-size` 为 `16px`；macOS 上 CSS px 虽按逻辑点渲染，但 Codex 的 CJK fallback 墨迹高度比 AppKit 16pt 小约 10%。默认正文改为 15pt 做视觉匹配，Aa 菜单仍保留 16pt。
- **存量设置迁移**：已保存的 16pt 默认值一次性迁移到 15pt；迁移标记保证之后用户手动选择 15/16pt 不会被覆盖。
- **辅助字号同步**：次级文字最小 12.5pt、微元信息最小 12pt、代码最小 13pt，随正文档位缩放。
- **Dock 图标刷新**：启动时从 bundle 重新加载 `AppIcon.icns` 并赋给 `NSApp.applicationIconImage`，避免 macOS 继续显示旧缓存；真机 Dock 已确认显示纯色靛蓝底 + 白色 `>_` 图标。
- 验证：`swift build` 通过；`swift test` 61/61；真机确认 15pt 迁移、正文观感与 Dock 图标。

## 顶部层级与图标比例（2026-11-20 继续完善）

- **去除重复标题**：聊天区不再重复显示 16pt 会话标题，只保留 macOS 窗口标题；会话工具条（ctx、Aa、搜索、变更、压缩）收成 34pt 紧凑行。
- **图标中心放大**：白色终端瓦片从 440×420 放大到 510×490，`>_` 图形同步加粗放大，提升 Dock/Finder 小尺寸辨识度，同时保留外围靛蓝 squircle 留白。
- 验证：`swift build` 通过；`swift test` 61/61；真机确认顶部无重复标题、Dock 图标中心比例更醒目。

## 蛇头像与工具中文名（2026-11-20 继续完善）

- **图标主体替换**：中心图形改为放大的白色侧脸蛇头，张嘴露出两颗獠牙，保留单眼、鼻孔、分叉舌与回环颈身；整体按视觉包围盒居中。
- **小尺寸校验**：在 512/128/48px 下检查轮廓，蛇头、獠牙与分叉舌仍可辨识；`Scripts/make-icon.swift` 继续作为可复现的图标源。
- **工具名中文化**：对话工具卡、顶部活动条和 Markdown 导出统一使用本地化名称——读取、写入、编辑、修改、运行命令、搜索、查找文件、浏览目录、读取网页、搜索记忆等。
- 验证：`swift build` 通过；`swift test` 61/61；真机确认工具卡显示中文且 Dock 使用蛇图标。

## 采用现成开源蛇形素材（2026-11-20 继续完善）

- **素材来源**：侧视盘蛇图标 “cobra”，作者 Delapouite，来自 game-icons.net（CC BY 3.0）；源文件保存为 `Resources/snake-cobra.svg`，保留原作者署名。
- **改动内容**：移除原图的黑色方形底板与固定填充色，转为纯白单色；按内容包围盒裁切后等比缩放、精确居中到 `#4F46E5` 纯色 squircle 上，图形高度约为画布 62%。
- **小尺寸校验**：512 / 128 / 64 / 48px 下蛇头、蛇身盘绕轮廓仍清晰；`Scripts/make-icon.swift` 继续可从 SVG 复现整套 PNG/ICNS。
- 验证：`swift build` 通过；`swift test` 61/61；Dock 与 Finder 图标替换为盘蛇造型。

## 新会话模型默认值修正（2026-11-21）

- **问题**：新建或切换会话时 `selectedModel` 被重置为 `nil`，选择器只能显示“服务端默认”，服务端配置的实际模型（GET /config 的 `model`）没有回填。
- **修复**：`SessionStore` 记录 `serverDefaultModel`；会话没有本地模型记录时按“应用默认模型 → 服务端默认模型”的顺序回退，新建会话直接预选真实模型。
- **显示**：选择器标签解析服务端默认模型并显示模型名（如 `Hy4 flash · WorkBuddy`），菜单首项显示“服务端默认 · 模型名”，不再只有占位文案。
- **优先级**：设置里的“新会话默认模型” > 服务端 `model` > 服务端默认。
- 验证：`swift build` 通过；`swift test` 63/63（新增 2 项默认模型回退测试）。

# v0.5 打磨批（2026-11-21，评审驱动）

外部评审核实后落地 9 项（含评审发现的 3 个新问题）：
- **生成指示三合一**：删除转写下方重复的 TimelineView 状态条，stalled 提示合并进 ActivityBar（stop 按钮、todo 进度、retry 状态一处集中）
- **@ 弹窗防抖 + 垃圾过滤**：fs/find 加 180ms 防抖（每键一次请求 → 停顿才发）；新增 `isSearchablePath` 过滤隐藏目录/node_modules/.log/.tmp
- **@ 支持换行后触发**：mention token 按空白+换行切分（Shift+Enter 换行后打 @ 也能弹）
- **allModelChoices 查找字典化**：流式期间 meta 行的 O(模型数×排序) 重算 → O(1) 查找
- **通知点击路由会话**：通知 userInfo 带 sessionID + UNUserNotificationCenterDelegate，点击直达对应会话
- **图片压缩按像素口径**：修 Retina 下 1568pt 实际输出 3136px 的 bug（改按 cgImage 像素计算）
- **兜底轮询去 10min 硬上限**：改为活动期间自续、结束即取消

# v0.5.1 上下文占用显示（2026-11-21，对标 Claude 桌面端）

- **ContextMeter**：composer 左下角常驻——细进度条 + `17.4k / 960k · 2%` 读数，颜色分级（<60% 平静 / 60-85% 橙 / >85% 红）
- 数据口径：最后一条 assistant 消息的 `tokens.input`（≈ 下次调用将送入的上下文）÷ 所选模型的 `limit.context`（/api/model 实测字段）
- 会话头部文字同步显示 `ctx 17.4k/960k · 2%`
- 新会话无消息时显示 `0 / 960k` 空条（窗口大小可见）；模型无 limit 数据时退化为纯 tokens 文本

# v0.5.2 细节打磨（2026-11-21 第二批）

- **流式中禁用消息操作**：生成中的最后一条气泡不显示 hover 操作栏，contextMenu 的 Revert 禁用——防止误触截断正在生成的内容（复制仍可用）
- **权限卡片按钮视觉分级**：Allow once 主推（borderedProminent）/ Always allow 常规 / Reject 红色 destructive
- **⌘F 高亮扩展**：assistant 气泡的 markdown 文本段也高亮搜索命中（黄色底），代码块保持语法着色不变
- **日志查看器**：设置 → 服务器 → "View Log…" 弹出实时尾部（等宽、自动滚底、一键复制）

# v0.5.2 收尾（2026-11-21 第三批复核）

复核外部演进与评审遗留项，本轮补齐最后一项：
- **切走会话停兜底轮询**：`select()` 切走时 `stopPolling(for: old)`，消除后台活跃会话每 2s 的空转唤醒；切回时已有逻辑自动重启，无需额外处理
- 其余评审项确认已闭环：三合一指示、@ 防抖+过滤+换行、模型字典缓存（`load()` 后重建，save/delete 均触发）、通知路由（userInfo.sessionID）、图片按像素压缩、轮询去 10min 上限
- 验证：`swift build` 通过；`swift test` 65/65

## 下一步完善方向（按优先级）

1. **打开发布闭环**：当前 GitHub 仓库只有源码；建议 release.sh 同步产出 GitHub Release（附 DMG + SHA-256），或加 GitHub Actions 自动构建
2. ~~**长会话性能**~~ ✅ 2026-11-29 已实施：`TranscriptRowCache`（已封存前缀 checkpoint + 尾部重折 + Hasher 指纹失效检测），500 消息流式每帧行推导 59 ms → 0.46 ms（≈128×）；⌘F 结果记忆化；ProviderStore 模型查找 O(1)；ChatView 5068 行拆为 8 个文件
3. **错误恢复**：SSE 断连重连已有时序护栏，但 inline error 只能手动 Retry；可对"网络类失败"自动退避重试一次
4. **@ 弹窗键盘体验**：上下键/Tab 已接，但 Enter 优先发送——候选选中时 Enter 应先完成补全（与 slash 命令面板行为对齐）
5. **设置项迁移**：`chatFontSize` 已有多轮迁移标记，建议引入统一 `settingsVersion`，避免继续叠加一次性迁移键
6. **测试盲区**：UI 层（ChatView 组合逻辑）无快照/行为测试；优先给 composer 状态机（发送中/队列/附件）补 ViewModel 级测试

# v0.5.2 第四批（2026-11-21）：候选补全与网络自愈

- **Enter 补全候选**：@ 弹窗可见时 Enter 先完成附件补全（再按发送）；"/" 命令面板在未输入参数时 Enter 先补全命令名——`/cmd args` 仍直接发送，与 slash 命令路由不冲突
- **网络类失败自动重试一次**：session.error 分类为 network 时，2s 退避后用原 PromptSnapshot 自动重发；ActivityBar 经 retryInfo 显示"网络错误，正在重试…"。计数器在新发送时清零，第二次失败/手动中止/无快照立即回退到 inline 错误卡，不会死循环
- 验证：`swift build` 零警告；`swift test` 65/65

# v0.5.2 第五批（2026-11-21）：设置迁移收敛 + 发布标签

- **设置迁移统一 settingsVersion**：`chatFontMigration` + `chatFontSizeCodexMatched` 两个一次性标志合并为单一 `settingsVersion` 整数门（v1 = 旧字号 ≤16pt 一次性落到 15pt）；后续新迁移追加版本号即可，不再叠加一次性键。用户手动选的更大字号不受影响
- **release.sh 版本标签**：打包完成自动打 `v<version>` tag（repo 内），提示 `git push origin v<tag>`；正式 GitHub Release 仍需 token/gh CLI 上传 DMG
- **新增 3 项迁移测试**：16pt→15pt 一次性迁移、用户 20pt 保留、二次启动不重迁移
- 验证：`swift build` 零警告；`swift test` 68/68

# v0.5.2 第六批（2026-11-21）：发布闭环 + 渲染缓存，完善任务收尾

- **GitHub Actions 发布闭环**：新增 `.github/workflows/release.yml`——推送 `v*` tag 自动跑测试、构建 DMG（CI 无签名证书时自动回退 ad-hoc）、创建 GitHub Release 并附 DMG + SHA-256；release.sh 已自动打 tag，本地 `git push origin v0.5.x` 即触发
- **流式渲染缓存**：NSCache 三层缓存——segments 解析、prose blocks 解析、inline AttributedString（key 含字号/字重）；代码高亮同样按 `lang|code` 缓存。流式期间每帧只重新解析变化中的气泡尾部，历史气泡全部命中缓存
- **ESC 关闭候选弹窗**：@ 弹窗可见时 ESC 先移除 "@query" token 并收起弹窗，其次才是中止生成
- **诚实备注**：长会话性能在解析/高亮层已解决（占大头）；SwiftUI 视图级 diff 跳过仍留作将来项。UI 层测试仍偏薄，composer 状态机已有队列/草稿回归测试
- 验证：`swift build` 零警告；`swift test` 68/68；workflow YAML 结构校验通过

# v0.6 预备批（2026-11-21）：置顶会话 + 模型选择器重构

按评审方向二 + 置顶会话落地四个 S 项：
- **置顶会话**：服务端无 pin 字段 → 客户端 `pinnedSessionIDs`（UserDefaults，pin 顺序即展示顺序）；侧栏分「置顶 / 今天 / 昨天 / 更早 / 已归档」，行首 pin 图标，右键 置顶/取消置顶；删除会话自动清除 pin（store `@Published` 驱动刷新）
- **模型选择器重构**：Menu（嵌套子菜单翻 64 个模型）→ Popover（360×380）：顶部搜索框按 名称/供应商/ID 过滤 + 「最近使用」分组（显式选择才记录，去重、最新在前、上限 6）；服务端默认行保留置顶
- **排队 chip 附件数**：快照带附件时显示 📎 × n 提示
- **兜底轮询智能化**：SSE 健康且输出正常时完全静默；断连 2s 快轮询、输出停滞 >45s 时 6s 慢轮询兜底
- **通知路由确认闭环**：完成与权限通知均已带 sessionID 且 AppDelegate 路由（评审项 #4 无需改动）
- 验证：`swift build` 零警告；`swift test` **71/71**（新增 recents 去重上限、pin 往返、删除清 pin 3 项）
- 遗留：子任务树（children 端点已验证 `GET /session/{id}/children` → Session[]）与多窗口按计划放 v0.6 大批；composer 状态机下沉先行
