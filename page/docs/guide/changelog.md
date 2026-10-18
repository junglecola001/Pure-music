---
outline: false
description: Pure Music 更新日志，自 2.0.0 起按版本折叠。
---

# 更新日志

从 **2.0.0** 起。每个版本默认折叠，点版本号展开。最新：**2.4.0**。

完整发布页：[GitHub](https://github.com/junglecola001/Pure-music/releases) · [Gitee 镜像](https://gitee.com/junglecola001/Pure-music)（同步常滞后）

<details>
<summary><strong>2.4.0</strong></summary>

**先看这些**

- 仓库已迁到 [junglecola001/Pure-music](https://github.com/junglecola001/Pure-music)，应用内「检查更新」和下载链接都指向新仓库。
- 本次开始提供 Windows ARM64 构建：文件名带 `_arm64` 的安装包 / 便携包给骁龙 X 系列等 ARM64 设备用；普通 x64 电脑仍下载不带后缀的包。
- 在线音乐是实验性功能，需要自己跑一个本地后端（见下方说明），不装后端就只能用本地曲库。

**在线音乐（实验性）**

- 侧边栏新增「在线音乐」页，可搜索歌曲，查看歌单 / 专辑 / 歌手详情并直接播放。
- 设置里新增「在线音源」页：开关、后端地址、Token、音质档位、缓存开关、Node 路径等。
- 需要自行部署后端：仓库里的 `backend/`（Node.js 22.12+，`npm ci --ignore-scripts` 后 `npm start`，默认 `http://127.0.0.1:3000`），支持扫码登录和 Cookie 导入网易云账号。安装包里不含后端。
- 在线播放与歌词由后端解析，音质档位不可用时按后端能力自动向下回退。

**歌词**

- 桌面歌词支持鼠标悬停解锁，解锁后才响应拖拽和操作，避免误触。
- 新增歌词偏移调节，入口改为单个按钮。
- 歌词辉光效果默认开启。
- 行高变化时当前行留在原地；切行上抬从行首跟上唱标；修正未选字体时的韩文回退。

**窗口与更新**

- 新增主窗口置顶。
- 下载更新不再跟随窗口移动，进度显示在标题栏，可稍后安装。

**其他**

- 收紧静态检查，补上泛型和未等待的调用。
- 生成 flutter_rust_bridge 绑定时锁定版本，出错就停下。
- 修复录音停止后写入已关闭日志文件的问题。
- 开发工具里只启用正在使用的 Provider 扩展。
- 新增 GitHub 赞助配置。

**此次更新贡献者**

[@qingyueyin](https://github.com/qingyueyin) [@junglecola001](https://github.com/junglecola001)

---

**下载说明**

| 文件 | 说明 |
| --- | --- |
| `pure_music_2.4.0_release_installer.exe` | x64 安装包（大多数电脑） |
| `pure_music_2.4.0_release_portable.zip` | x64 便携包 |
| `pure_music_2.4.0_release_installer_arm64.exe` | ARM64 安装包（Windows on ARM） |
| `pure_music_2.4.0_release_portable_arm64.zip` | ARM64 便携包 |

每个文件都附带 `.sha256` 校验值。

</details>

---

更早版本见 [GitHub Releases](https://github.com/junglecola001/Pure-music/releases)。下载见 [下载页](/download)。
