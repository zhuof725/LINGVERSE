# 聆境 LINGVERSE

听书 App **空壳**：只有界面骨架与占位内容，不含真实业务逻辑。

- SwiftUI · iOS 17+
- 界面：书库 / 书城 / 我的 + 迷你播放条 + 全屏播放页
- 已预留：后台播放、音频会话、锁屏与控制中心

## 云端构建

推送到 `main` 或在 Actions 页面手动触发 **Build IPA**，产物为未签名 IPA，
发布在 Releases 中。

## 本地运行

```bash
brew install xcodegen
xcodegen generate
open LINGVERSE.xcodeproj
```

## 安装说明

构建产物是**未签名 IPA**，不能直接双击安装。可用以下任一方式签名后安装：

- **TrollStore**（设备支持时可直接安装）
- **AltStore / Sideloadly / ESign**（用你自己的 Apple ID 签名，免费账号 7 天有效期）
