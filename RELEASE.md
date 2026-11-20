# Release & Distribution

构建、签名与分发约定。日常发布只需一条命令：

```bash
Scripts/release.sh              # patch 递增（0.5.0 → 0.5.1）
Scripts/release.sh minor        # minor 递增
RELEASE_NOTES="摘要..." Scripts/release.sh --version 1.0.0
```

产出物全部落在 `build/`：

| 文件 | 说明 |
|---|---|
| `DevEco Code Desktop-<version>.dmg` | 拖入 Applications 的标准分发包 |
| `DevEco Code Desktop-<version>.dmg.sha256` | `SHA256=...` 校验行（`shasum -a 256 -c` 可验） |
| `ReleaseNotes-<version>.md` | 发布说明（`RELEASE_NOTES` 传入自定义，否则从 ROADMAP 抽取最近完成项） |

`release.sh` 每次自动递增 `CFBundleVersion`（build number），并做 codesign / hdiutil 校验；DMG 挂载复制到干净目录启动已验证（2026-11-20，v0.5.0）。

## 签名

- 使用**本地持久自签名证书** `DevEco Code Desktop Dev`（专用 keychain：`~/Library/Application Support/DevEcoCodeDesktop/signing/`，由 `build-app.sh` 首次自动创建）。
- 不用 ad-hoc 签名的原因：ad-hoc 每次构建产生新 CDHash，macOS 会视为不同 App，**丢失已授予的 TCC 权限**（文件夹访问等）。持久证书保持签名稳定。
- **未做 Apple 公证**（无 Developer ID 账号）。分发范围为本机/信任设备；对外分发需先公证。

## 首次启动（Gatekeeper）

自签名未公证的 DMG 在别的 Mac 上首次打开可能被拦截：

- 右键 App → **打开**；或
- `xattr -dr com.apple.quarantine '/Applications/DevEco Code Desktop.app'`（仅限信任来源的包）。

用 `shasum -a 256 -c 'build/DevEco Code Desktop-<version>.dmg.sha256'` 先校验完整性。

## 首次启动权限说明

- **无需任何 TCC 特权**：项目目录由用户在 App 内主动选择（NSOpenPanel），服务数据与日志都写入 App 容器（`~/Library/Application Support/DevEcoCodeDesktop/`），不触碰 Documents/Desktop 等。
- 服务只绑定 `127.0.0.1`，无密码监听本机回环；停 App 即停服务（可在设置中改）。
- 依赖：deveco CLI（`npm i -g deveco`）与 Node.js 在 PATH；缺失时出现引导卡片，可在设置里手动指定二进制路径。
- 产品协议：deveco 首次模型调用前要求同意，App 会在检测到 consent 拦截时自动执行 `deveco auth consent --accept` 并引导确认。

## 已知限制

- 未公证包在全新 macOS 上仍可能触发"无法验证开发者"——按上文 Gatekeeper 步骤处理。
- Dock 角标/通知权限按需触发（完成通知需通知授权，拒绝则静默降级）。
- `hdiutil create` 的弃用警告来自系统提示，不影响产物。
