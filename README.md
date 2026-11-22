# DevEco Code Desktop

A native macOS GUI for the locally installed `deveco` CLI. The app manages a local `deveco serve` process and talks to its HTTP API — the same API the bundled web UI uses (`GET /doc` on a running server).

中文说明见下方 [中文文档](#中文文档)。

![App icon](Resources/AppIcon.png)

## Requirements

- macOS 11+（提供 Apple Silicon / Intel 两个安装包）
- Xcode command line tools (Swift 5.9)
- `deveco` CLI installed locally (`npm i -g deveco`) and Node.js on PATH

## Build & Run

```bash
./Scripts/install.sh       # build and atomically replace /Applications/DevEco Code Desktop.app
./Scripts/make-dmg.sh      # build arm64 + Intel .app bundles and DMGs (build/)
```

The build script signs with a persistent self-signed certificate (created once in `~/Library/Application Support/DevEcoCodeDesktop/signing`). A stable signing identity keeps TCC grants (folder access, etc.) across rebuilds; ad-hoc signing would reset them every build. If the identity is unavailable the script falls back to ad-hoc with a warning.

`install.sh` is the only supported way to put the app on this machine: it builds into `build/`, replaces `/Applications/DevEco Code Desktop.app` in place, and removes leftover `*.backup-*.app` copies plus old in-repo bundles. It also unregisters every other LaunchServices entry for `com.local.deveco-codesktop` (build output, temp install dirs, unmounted DMGs) and fails unless exactly one registered path remains, so there is always exactly one installed copy and no duplicate Launchpad entries.

## Features

**Sessions & input**

- Create (⌘N), search, rename, archive, and delete sessions; grouped by Today / Yesterday / Earlier with relative timestamps. New sessions take their title from the first prompt; placeholder titles are backfilled when loaded.
- Enter sends (Shift+Enter newline, ⌘⏎ also sends); prompts stream live with a single generation indicator (tool, todo progress, retry reason, stalled hint, stop button).
- **Prompt queueing**: Enter while generating queues the prompt as a removable chip; it sends automatically on idle. **Prompt history**: Option+↑/↓ recalls recent prompts.
- Drafts, queues, attachments, model picks, and generating state are fully isolated per session — switching chats never hijacks the composer.
- `@` file mentions with 180 ms debounce (`/api/fs/find`), junk filtered (dot-directories, `node_modules`, logs/temp); Enter completes the highlighted candidate, and mentions work after line breaks. Slash commands (`/name args`) route to the command endpoint; Enter completes a half-typed command name.
- Image/file attachments: pasted images compress to ≤1568 px (pixel-accurate on Retina), oversized ones warn; files attach by reference, must live inside the project folder.

**Transcript & rendering**

- Codex-style transcript: compact right-aligned user bubbles, borderless assistant prose, elapsed time per reply, quiet tool cards with durations and localized tool names.
- Markdown prose (headings, lists, quotes, inline formatting) and code blocks with language label, copy button, and lightweight syntax highlighting. Streaming renders parse/highlight only the changed bubble via caches.
- **⌘F** search with highlight and match navigation; **Changes** panel with colorized unified diffs; agent todo panel; assistant messages show model name, token usage, and cost.
- **Compact** compresses context; **Revert/unrevert** rolls back to before any message; export any session as Markdown.
- Token usage is shown by dimension instead of one ambiguous number: a warning strip appears only when the context window is ≥80% full, each reply shows generated tokens on hover, and the Work Panel's Context tab breaks down context window, last-turn request size, and session totals.

**Models & providers**

- The composer model picker covers every runnable model (`GET /api/model`) merged with custom providers; IDs route as `providerID/modelID` (slashes allowed). Reasoning-effort variants are per model, labeled 低/中/高/… in Chinese.
- **Models & Providers** settings: browse/add/edit OpenAI-compatible providers (base URL, API key, models with limits/reasoning), delete, set the server default model. New sessions preselect the configured default model.

**Status & notifications**

- Retry-aware status (attempt/reason), per-session sidebar indicators (busy, retrying, needs permission, needs answer, failed, unread), Dock badge for pending permissions/questions.
- Background session completion fires a macOS notification + optional sound; clicking it routes to that session. Permission nudges after 10 s unanswered.
- Network-class send failures auto-retry once after a 2 s backoff; a second failure surfaces the inline error card.

**Server & data**

- Starts `deveco serve` on a free local port (from `127.0.0.1:4096`, configurable); resolves the binary from common npm/homebrew paths or a minimal `/bin/sh -c` PATH probe that does not load shell profiles. Quit behavior configurable (stop vs. keep the server).
- Backup/restore the deveco data directory (zip); live server log viewer; update-available banner; project usage totals and git branch in the UI.

## Harness / account boundary

This desktop app is a native GUI for the locally installed `deveco` CLI. It starts
`deveco serve`, talks to its documented HTTP API (`GET /doc`), and renders the
same SSE events and REST resources as the bundled web UI. It does **not**
embed, reimplement, or depend on a proprietary harness from DevEco Studio.

Signing in to a Huawei/DevEco account is **not required to open the app or chat
with models configured in Models & Providers**. A Huawei account is only needed
for the commands/products that your local `deveco` CLI itself gates behind
authentication (for example device/cloud services). Model calls go to the
provider endpoint you configure (OpenAI-compatible providers, or the servers
already configured in your `deveco` CLI). Tool execution, permissions, and
session storage are performed by the local `deveco serve` process.

In short: the "harness" here is the standard `deveco serve` process and its
public HTTP protocol, not a hidden SDK in this app. If a command needs a
Huawei account, the local CLI will say so; ordinary chat/model usage does not.

中文补充：本 App 是本地 `deveco` CLI 的原生 GUI，通过官方 `deveco serve` 的
HTTP/SSE 接口工作，没有内置或绕过华为的私有 harness。是否登录华为账号取决于
具体工具/云服务；普通模型对话只需要配置好模型/供应商，不要求华为账号。

## Release & distribution

```bash
Scripts/release.sh        # bumps version, builds, packages, verifies, tags v<x.y.z>
git push origin v0.5.x    # pushes the tag → GitHub Actions builds & publishes the Release
```

`release.sh` produces `build/DevEco Code Desktop-<version>-arm64.dmg` and `-x86_64.dmg`, each with `.sha256`, plus release notes (see [RELEASE.md](RELEASE.md)). Pushing a `v*` tag triggers [.github/workflows/release.yml](.github/workflows/release.yml): tests run, the DMG is built on a clean macOS runner (ad-hoc signed), and a GitHub Release is created with the DMG and checksum attached. The DMG is **not notarized** — on other Macs, right-click → Open or `xattr -dr com.apple.quarantine`.

## Design notes

- Streaming updates arrive over the `GET /event` SSE stream with exponential-backoff reconnects; a light 2 s poll only runs for the visible session while a prompt is in flight.
- The server binds to loopback only and runs without a password. `XDG_DATA_HOME` points at `~/Library/Application Support/DevEcoCodeDesktop/deveco-data`.
- Provider edits use `PATCH /config`; per-prompt model selection uses the `model` field of `POST /session/{id}/prompt_async`.

## Tests

```bash
swift test --disable-sandbox
```

135 tests cover failure classification, queue hardening, session isolation, mention parsing, path filtering, image downscaling, and settings migrations.

## Localization

The UI ships in English and Simplified Chinese; macOS picks automatically. Strings live in `Resources/{en,zh-Hans}.lproj/Localizable.strings`.

## License & credits

Licensed under [Apache-2.0](LICENSE). The app icon adapts the "cobra" icon by Delapouite from [game-icons.net](https://game-icons.net/) (CC BY 3.0), recolored white on a flat indigo squircle; see `Resources/snake-cobra.svg`.

---

# 中文文档

DevEco Code Desktop 是本机 `deveco` CLI 的原生 macOS 图形客户端。应用负责管理本地 `deveco serve` 进程，并通过其 HTTP API 通信——与内置 Web UI 使用同一套 API（运行中的服务器访问 `GET /doc` 可见）。

## 环境要求

- macOS 11+（提供 Apple Silicon / Intel 两个安装包）
- Xcode 命令行工具（Swift 5.9）
- 本机已安装 `deveco` CLI（`npm i -g deveco`）且 Node.js 在 PATH 中

## 构建与运行

```bash
./Scripts/install.sh       # 构建并原子覆盖安装到 /Applications/DevEco Code Desktop.app
./Scripts/make-dmg.sh      # 构建 arm64 与 Intel 的 .app 和 DMG（输出到 build/）
```

构建脚本使用持久自签名证书签名（首次自动创建于 `~/Library/Application Support/DevEcoCodeDesktop/signing`）。签名身份稳定可保留 macOS 已授予的权限（如文件夹访问）；ad-hoc 签名每次构建 CDHash 都会变化导致权限重置。找不到证书时自动回退 ad-hoc 并警告。

本机安装只走 `install.sh`：它把产物构建到 `build/`，原子替换 `/Applications/DevEco Code Desktop.app`，并顺带清理遗留的 `*.backup-*.app` 与仓库内的旧 `.app`。脚本还会按 bundle id 注销 LaunchServices 里其余所有登记（构建产物、临时安装目录、已卸载 DMG），最后断言只剩 `/Applications` 一条，否则直接失败——因此系统里始终只有一份，启动台不会再出现重复图标。

## 功能

**会话与输入**

- 新建（⌘N）、搜索、重命名、归档、删除会话；按 今天/昨天/更早 分组并显示相对时间。新会话以首条 prompt 命名，占位标题在加载时自动回填。
- 回车发送（Shift+回车换行，⌘⏎ 也可发送）；生成状态单一指示条（当前工具、todo 进度、重试原因、卡顿提示、停止按钮）。
- **队列**：生成中回车会把 prompt 排队（可删除的 chip），空闲后自动发送。**历史**：Option+↑/↓ 调出最近发送记录。
- 草稿、队列、附件、模型选择、生成状态按会话完全隔离——切换会话不会劫持输入框。
- `@` 文件引用：180ms 防抖（`/api/fs/find`），过滤隐藏目录/`node_modules`/日志临时文件；回车补全选中项，换行后仍可触发。斜杠命令（`/name args`）走命令端点；未输完参数时回车先补全命令名。
- 图片/文件附件：粘贴图片压缩到 ≤1568px（Retina 像素口径精确），过大图片有提示；文件按引用附加，必须在项目目录内。

**转写与渲染**

- Codex 风格转写：用户气泡右对齐紧凑、助手正文无边框、每条回复上方显示耗时、安静的工具卡（含耗时与中文名：读取/运行命令/…）。
- Markdown 正文（标题/列表/引用/行内格式）与代码块（语言标签、复制按钮、轻量语法高亮）。流式期间经缓存只重新解析变化中的气泡。
- **⌘F** 搜索（高亮 + 计数导航）；**变更**面板（着色 unified diff）；agent todo 面板；助手消息下方显示模型名、token 用量与费用。
- **压缩**长上下文；**回退/撤销回退**到任意消息之前；导出任意会话为 Markdown。
- token 用量按维度展示，不再在输入框常驻一个含义模糊的数字：上下文窗口占用 ≥80% 时才出现告警条，单条回复悬停显示生成 token，工作台「上下文」页拆分上下文窗口、最近一轮请求体量与本次会话累计。

**模型与供应商**

- 输入框模型选择器覆盖服务器可运行的全部模型（`GET /api/model`），并与自定义供应商合并；ID 以 `providerID/modelID` 路由（允许含斜杠）。强度档位来自所选模型，中文显示 低/中/高/…。
- **模型与供应商**设置：浏览/新增/编辑 OpenAI 兼容供应商（base URL、API key、模型上下文/输出上限与推理标记）、删除、设置服务端默认模型。新会话自动预选该默认模型。

**状态与通知**

- 重试状态（第 n 次 · 原因）、侧栏逐会话指示（运行中/重试/待权限/待回答/失败/未读）、待处理权限与提问时 Dock 角标。
- 后台会话完成触发系统通知（可选提示音），点击直达对应会话；权限请求 10 秒未响应时提醒。
- 网络类发送失败 2 秒退避后自动重试一次；二次失败才显示行内错误卡。

**服务器与数据**

- 在空闲本地端口启动 `deveco serve`（起始 `127.0.0.1:4096`，可配置）；自动解析 deveco 二进制（常见 npm/homebrew 路径、不加载 shell 配置的最小 `/bin/sh -c` PATH 探测），也可在设置中指定。退出行为可配置（停止/保留服务进程）。
- 备份与恢复 deveco 数据目录（zip）；实时服务器日志查看器；新版本横幅；侧栏显示项目用量统计与 git 分支。

**Harness 与账号边界**

- 本 App 不内置、不实现、也不依赖 DevEco Studio 的私有 harness；它是本地 `deveco` CLI 的原生 GUI，通过官方 `deveco serve` 的 HTTP/SSE 接口工作。
- 普通模型对话不需要登录华为/DevEco 账号；模型调用发往你在「模型与供应商」中配置的 OpenAI 兼容端点，或 `deveco` CLI 已配置的供应商。
- 是否要求华为账号取决于具体命令/云服务，由本地 `deveco` CLI 自行判定；工具执行、权限审批与会话存储均由本地 `deveco serve` 完成。

## 发布与分发

```bash
Scripts/release.sh        # 递增版本、构建、打包、校验、打 v<x.y.z> 标签
git push origin v0.5.x    # 推送标签 → GitHub Actions 自动构建并发布 Release
```

`release.sh` 产出 `build/DevEco Code Desktop-<version>-arm64.dmg` 与 `-x86_64.dmg`（各含 `.sha256`）+ 发布说明（详见 [RELEASE.md](RELEASE.md)）。推送 `v*` 标签触发 [.github/workflows/release.yml](.github/workflows/release.yml)：干净 macOS runner 上先跑测试再构建 DMG（ad-hoc 签名），自动创建 GitHub Release 并附 DMG 与校验和。DMG **未做公证**——在其他 Mac 上首次打开请右键 → 打开，或执行 `xattr -dr com.apple.quarantine`。

## 设计说明

- 流式更新走 `GET /event` SSE，指数退避重连；仅在可见会话有进行中的 prompt 时才启用 2 秒兜底轮询。
- 服务器只绑定 loopback、无密码运行。`XDG_DATA_HOME` 指向 `~/Library/Application Support/DevEcoCodeDesktop/deveco-data`。
- 供应商编辑用 `PATCH /config`；逐 prompt 模型选择用 `POST /session/{id}/prompt_async` 的 `model` 字段。

## 测试

```bash
swift test --disable-sandbox
```

136 项测试覆盖失败分类、队列加固、会话隔离、@ 解析、路径过滤、图片压缩、token 口径与设置迁移。

## 本地化

界面支持英文与简体中文，macOS 按系统语言自动选择。字符串位于 `Resources/{en,zh-Hans}.lproj/Localizable.strings`。

## 许可与署名

项目基于 [Apache-2.0](LICENSE) 开源。应用图标改编自 [game-icons.net](https://game-icons.net/) Delapouite 的 "cobra" 图标（CC BY 3.0），重新着色为纯色靛蓝底白色剪影；源文件见 `Resources/snake-cobra.svg`。
