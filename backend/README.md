# Sonora Backend · 网易云音乐音源 API

单账号、无数据库的网易云音乐音源服务，用 **Node.js + Express 5 + NeteaseCloudMusicApi** 实现。本仓库**只包含后端 HTTP API，不包含任何前端页面**，可以直接启动为独立服务，也可以嵌入其他项目的 Node.js 进程，供 Web、桌面、移动或命令行客户端调用。

账号登录、曲库查询、播放地址解析（音源）、歌词、媒体代理等能力全部通过 `/api/v1` 暴露；客户端负责界面、播放器和队列。前端相关代码（React + Vite 播放器）已从仓库移除，迁移到其他项目时直接调用这里的 API。

## 能力

| 模块 | 已实现能力 |
| --- | --- |
| 账号 | Cookie 验证导入、扫码登录（创建会话＋轮询）、登录状态、退出、VIP／SVIP 状态查询 |
| 曲库 | 歌曲搜索、歌曲详情、歌单／专辑／歌手详情、推荐歌单、每日推荐、私人推荐歌单、播客 |
| 音源 | `GET /songs/:id/playback` 解析播放地址，按 `quality` 档位向下回退，区分完整／试听／不可播放，可选音频探测 |
| 歌词 | 原文、翻译、罗马音、逐字歌词，以及解析出的近似时间轴 `lines` |
| 媒体 | 短期签名票据、音频与封面代理、GET／HEAD、单 Range（206／416）、独立媒体限流、CDN 与 DNS 校验 |
| 资料库 | 喜欢的歌曲、我的歌单、歌单增删、歌单／专辑收藏、评论与点赞、真实听歌记录上报 |
| 服务 | Bearer Token、CORS 白名单、限流、统一错误模型、请求 ID、脱敏日志、OpenAPI 文档、Docker 镜像 |

后端接口能力大于任何单个客户端所需；按需调用 `GET /api/v1/capabilities` 可以在运行时确认当前版本支持的能力与边界。

## 快速开始

需要 **Node.js 22.12+**（推荐 Node.js 24 LTS）和 npm。

### 1. 安装依赖

```bash
npm ci --ignore-scripts
```

### 2. 配置并启动

macOS／Linux：

```bash
cp .env.example .env
npm start
```

Windows PowerShell：

```powershell
Copy-Item .env.example .env
npm start
```

默认监听 `http://127.0.0.1:3000`，API 前缀为 `/api/v1`。开发时可用 `npm run dev` 自动重启。

### 3. 确认服务可用

```bash
curl http://127.0.0.1:3000/api/v1/health
curl http://127.0.0.1:3000/api/v1/capabilities
```

完整接口说明见 [docs/API.md](docs/API.md)；机器可读定义见 [docs/openapi.json](docs/openapi.json) 或运行时 `GET /api/v1/openapi.json`。

## 接入流程（登录 → 音源 → 歌词）

所有 JSON 成功响应统一为 `{ "success": true, "data": ..., "requestId": "uuid" }`，失败为 `{ "success": false, "error": { "code", "message" }, "requestId": "uuid" }`。

### 1. 登录网易云账号（可选）

公开曲库、搜索、歌词和公开歌曲的播放解析不需要登录；每日推荐、私人推荐、会员状态、资料库和所有写操作需要登录。

Cookie 导入：

```bash
curl -X POST http://127.0.0.1:3000/api/v1/auth/cookie \
  -H 'Content-Type: application/json' \
  -d '{"cookie":"MUSIC_U=...; __csrf=..."}'
```

扫码登录：`POST /api/v1/auth/qr` 创建会话并拿到二维码 `image`，随后每 2 秒左右调用 `GET /api/v1/auth/qr/:sessionId`，`state` 变为 `authorized` 即完成；二维码约 180 秒后过期。

```bash
curl http://127.0.0.1:3000/api/v1/auth/status
```

服务是**单账号**模型：所有客户端共享同一个网易云账号，导入 Cookie 会改变其他客户端的账号状态。Cookie 只保存在服务端 `data/netease.cookie`（可用 `PERSIST_COOKIE=false` 关闭持久化），不会返回给客户端。

### 2. 搜索并解析音源

```bash
curl "http://127.0.0.1:3000/api/v1/search?keywords=%E6%99%B4%E5%A4%A9&limit=5"
curl "http://127.0.0.1:3000/api/v1/songs/186016/playback?quality=exhigh"
```

播放解析返回 `status`（`full`／`trial`／`unavailable`）、`playable`、实际 `quality`、`restriction` 和签名代理地址 `proxyUrl`。客户端必须同时判断 `playable` 与 `status`，不能把搜索结果里的 `fee` 或已登录状态当作播放权限。

```json
{
  "id": "186016", "status": "full", "playable": true, "trial": false,
  "requestedQuality": "exhigh", "quality": "exhigh", "bitrate": 320000,
  "verified": true, "expiresAt": 1730000000000,
  "proxyUrl": "/api/v1/media/audio?ticket=...", "url": "https://..."
}
```

播放时优先使用 `proxyUrl`（`new URL(data.proxyUrl, base)`），不要长期保存或展示上游 `url`。`proxyUrl` 的 GET／HEAD 不需要 Authorization header，票据短期有效；过期后重新解析播放。

### 3. 取歌词

```bash
curl "http://127.0.0.1:3000/api/v1/songs/186016/lyrics"
```

`original`／`translated`／`romanized`／`wordByWord` 是原始歌词文本，`lines` 是服务端按 `[mm:ss.xx]` 解析出的近似时间轴（`[{ timeMs, text }]`）。纯音乐返回 `instrumental: true`。

### 4. 封面与其他媒体

```bash
curl -X POST http://127.0.0.1:3000/api/v1/media/tickets \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://p1.music.126.net/...","kind":"cover"}'
```

返回的 `proxyUrl` 可直接用于 `<img>` 或 `fetch`；服务只代理允许的网易云 CDN，拒绝 IP、内网地址、非音频／非图片响应，并支持单段 `Range`（视频拖动进度常用）。

### 鉴权与跨域

- 配置 `API_TOKEN`（至少 24 字符）后，除 `/health` 和已签票媒体 GET／HEAD 外的所有请求都需要 `Authorization: Bearer <API_TOKEN>`。
- 监听非回环地址（如 Docker 的 `0.0.0.0`）时**必须**配置 `API_TOKEN`，否则服务拒绝启动。
- 浏览器客户端需要把页面的完整 Origin（协议＋域名＋端口）加入 `CORS_ORIGINS`，不支持 `*`；非浏览器客户端（Node、桌面、移动原生）不发送 Origin，不受此限制。

## 项目结构

```text
music-player/
├── server.js                 服务启动与优雅退出
├── src/
│   ├── app.js                Express 应用工厂与依赖注入
│   ├── config.js             环境变量读取与校验
│   ├── core/                 数据模型、凭据、缓存、音频规则与媒体代理
│   ├── netease/              协议传输、曲库、播放、登录、会员与账号业务
│   └── http/                 路由、验证、鉴权、错误处理、OpenAPI 与兼容接口
├── examples/client.mjs       零依赖最小接入示例（搜索／音源／歌词／封面）
├── test/                     后端离线测试与接口契约测试
├── scripts/                  语法检查、OpenAPI 生成、在线只读验证、封面诊断与 DNS 诊断
├── docs/                     API、迁移、验证记录与 OpenAPI 文件
├── legacy/server.original.js 原始服务存档，仅用于迁移参考
├── .env.example              配置示例
└── Dockerfile                后端容器镜像
```

## 在现有 Node.js 应用中嵌入

```js
const { createApp } = require('./src/app');

const app = createApp();          // 或 createApp({ config })
app.listen(3000, '127.0.0.1');
```

`createApp({ config, api, media, store })` 支持测试依赖注入，导入 `server.js` 不会自动监听端口。不要运行 `legacy/` 中的原始服务。

## 客户端示例

`examples/client.mjs` 是零依赖脚本，演示健康检查、可选 Cookie 导入、搜索、播放解析、歌词、封面票据和音频 Range：

```bash
node examples/client.mjs "晴天"
```

环境变量：

| 变量 | 说明 |
| --- | --- |
| `MUSIC_API` | 后端地址，默认 `http://127.0.0.1:3000` |
| `MUSIC_TOKEN` | 后端启用 `API_TOKEN` 时填写 |
| `NETEASE_COOKIE` | 可选；填写后先导入登录 Cookie，再执行查询 |
| `MUSIC_KEYWORD` | 未传命令行关键词时的默认搜索词 |

可选参数 `--quality=standard|exhigh|lossless|hires|jymaster` 指定音质档位，默认 `exhigh`。

Windows PowerShell 示例：

```powershell
$env:MUSIC_API='http://127.0.0.1:3000'
node examples/client.mjs "晴天"
```

除可选的 Cookie 导入外，示例只做只读请求，不会修改歌单或收藏。

## 配置

`npm start` 和 `npm run dev` 读取可选的根目录 `.env`，系统环境变量优先。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `HOST` | `127.0.0.1` | 监听地址；非回环地址必须配置 `API_TOKEN` |
| `PORT` | `3000` | 服务端口；测试可用 `0` 随机分配 |
| `API_TOKEN` | 空 | Bearer Token，设置后至少 24 字符 |
| `CORS_ORIGINS` | 空 | 逗号分隔的完整浏览器 Origin；空只允许不带 Origin 的客户端 |
| `PERSIST_COOKIE` | `true` | 是否持久化网易云账号凭据 |
| `COOKIE_FILE` | `./data/netease.cookie` | 相对于工作目录；部署建议使用绝对路径 |
| `UPSTREAM_TIMEOUT_MS` | `8000` | 单次上游请求超时，100～60000 毫秒 |
| `PLAYBACK_BUDGET_MS` | `15000` | 播放解析总预算，100～60000 毫秒 |
| `PROBE_AUDIO` | `true` | 是否验证上游音频；关闭时返回 `verified=false` |
| `MEDIA_SECRET` | 启动时随机生成 | 签名密钥，至少 32 字符；固定后票据可跨重启验证 |
| `MEDIA_TTL_SECONDS` | `300` | 票据有效期，10～900 秒，不超过音频上游有效期 |
| `RATE_LIMIT_PER_MINUTE` | `120` | 每客户端地址的普通 API 每分钟额度 |
| `MEDIA_RATE_LIMIT_PER_MINUTE` | `600` | 签票、封面和音频 Range 共用的独立每分钟额度 |
| `LOG_REQUESTS` | `true` | 记录请求 ID、路由模板、方法和状态，隐藏参数与凭据 |

跨域部署请填写实际 Origin，不能使用 `*`。限流按直接连接的 socket 地址统计，不信任 `X-Forwarded-For`；反向代理部署需考虑多个客户端共享额度。

## 测试与验证

```bash
# 后端离线测试（假上游，不使用真实账号）
npm test

# JavaScript／ESM 语法检查
npm run check

# 路由变更后重新生成 docs/openapi.json
npm run docs
```

后端启动且网络可用时，可运行只读在线验证：

```bash
npm run verify:live
```

默认检查 `http://127.0.0.1:3000`，可用 `MUSIC_VERIFY_ORIGIN` 指定地址，启用鉴权时设置 `MUSIC_VERIFY_TOKEN`。该脚本读取推荐、搜索、歌词、播放解析和媒体，不修改账号歌单或收藏，失败时进程以非零码退出。

离线测试通过不代表上游接口永久可用；真实登录、会员、写操作仍需账号联调。历史证据与验收边界见 [验证记录](docs/VERIFICATION.md)。

## Docker 部署

Dockerfile 只打包后端，不包含前端。

```bash
docker build -t sonora-backend .
docker run --rm -p 127.0.0.1:3000:3000 --env-file .env.docker -v sonora-data:/app/data sonora-backend
```

运行前新建本地 `.env.docker`，至少配置：

```dotenv
API_TOKEN=replace-with-a-long-random-secret
# 浏览器客户端填写其完整 Origin，例如：
CORS_ORIGINS=https://your-client.example
```

请替换示例 Token。容器以非 root 用户运行，默认监听 `0.0.0.0`，因此没有 Token 会拒绝启动。不要在 `.env.docker` 中覆盖为 `HOST=127.0.0.1`，否则容器端口映射无法访问服务。数据卷用于保存账号凭据。对外部署时使用 HTTPS 反向代理，并把 `/api/v1` 转发到该服务。

## 常见问题

**音频解析失败或封面被拒绝**

媒体服务只连接允许的网易云 CDN，并检查 DNS 地址。代理工具若返回 `198.18.0.0/15` 的 Fake-IP，会触发 `AUDIO_PROBE_FAILED` 或 `MEDIA_URL_REJECTED`。为 `music.126.net` 和 `music.163.com` 及其子域名配置真实 DNS／Fake-IP 排除，重载代理配置并清除旧 DNS 缓存后重试。Clash 类配置可使用 `+.music.126.net` 与 `+.music.163.com`。

`scripts/fix-flclash-dns.ps1` 提供特定 FlClash 配置的预览、备份与修改，启用了 DNS 覆写时应直接在客户端中编辑；使用前请查看脚本适用条件。不要关闭媒体地址校验。`PROBE_AUDIO=false` 只跳过解析时探测，不会解除代理校验。

**登录后仍有歌曲无法完整播放**

播放受会员、购买、地区和版权限制影响，项目不绕过这些限制。会员接口信息不完整时返回 `unknown`。专辑收藏状态分页扫描未完成时可能返回 `null`，不能当作未收藏。单曲实际权限以播放解析的 `playable`／`status`／`restriction` 为准。

**浏览器客户端无法连接后端**

先检查后端健康接口与 Token，再核对 `CORS_ORIGINS` 是否包含浏览器当前完整 Origin（协议、域名和端口）；HTTPS 页面不能请求 HTTP 接口。服务端对已签票媒体的 GET／HEAD 不要求 Bearer，因此 `<audio>`／`<img>` 可以直接使用 `proxyUrl`。

**仓库里为什么没有前端？**

这个仓库被裁剪为纯 API 后端：`web/` 前端工程已移除，播放器界面、队列、歌词滚动等交互由调用方项目实现。可先用 `examples/client.mjs` 验证接口，再在目标项目中按 [docs/API.md](docs/API.md) 接入。

## 使用边界

这是自用的单账号服务。所有持有 API Token 的客户端共享同一个网易云账号，导入 Cookie 会改变其他客户端的账号状态。目前没有多用户隔离，也不支持多进程共享凭据。

Cookie 是账号凭据，保存在本地受保护文件中；Windows 部署需要适当的目录 ACL。`.env`、Cookie、`data/`、依赖、构建产物、覆盖率与日志均不应提交。媒体票据也具有短期访问权限，不应公开分享或写入日志。登出清空本服务凭据与缓存，已签发票据有效至到期。

项目使用第三方网易云协议，接口可能随上游变化。依赖审计与已知限制见 [docs/VERIFICATION.md](docs/VERIFICATION.md)，部署前执行 `npm audit`。不要盲目执行可能降级 SDK 的 `npm audit fix --force`。

## 更多文档

- [API 使用说明](docs/API.md)
- [OpenAPI 文件](docs/openapi.json)
- [验证记录与已知边界](docs/VERIFICATION.md)
- [旧版服务迁移说明](docs/MIGRATION.md)
