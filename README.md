# Project5 — Kokoro 中文 TTS API 平台

Project5 是一个轻量级中文 TTS API 服务平台，只使用 **Kokoro-82M-v1.1-zh** 一个模型。

目标不是做多模型平台，而是把 TTS 做成一个稳定、简单、可复用的基础服务：

```text
外部项目 / Agent / 视频系统
          │
          │ Authorization: Bearer sk-kokoro-xxx
          ▼
POST /v1/audio/speech
          │
          ▼
FastAPI + API Key 校验
          │
          ▼
Kokoro-82M-v1.1-zh
          │
          ▼
WAV 音频 + SQLite 任务记录
          │
          ▼
Project5 管理控制台
```

## V1 功能

- 工作台：今日调用、成功/失败、字符数、7 天趋势。
- 在线生成：输入文本、选择中文音色、设置 `0.5x - 2.0x` 语速。
- API Key：创建、启用、停用、删除；完整 Key 只显示一次。
- 生成任务：记录来源 IP、调用方、文本、音色、语速、耗时、状态和错误。
- 音频文件：在线播放、下载、删除。
- API 文档：控制台内置 cURL / Python / JavaScript 示例。
- API 请求日志：后台记录来源 IP、HTTP 状态、耗时和关联任务。

## 固定模型

```text
hexgrad/Kokoro-82M-v1.1-zh
```

Project5 不提供模型切换。调用者只需要传：

```json
{
  "input": "欢迎来到 AI 技术分享频道",
  "voice": "zf_001",
  "speed": 1.0
}
```

## 核心接口

```text
POST /v1/audio/speech   生成语音
GET  /v1/voices         查看中文音色
GET  /v1/tasks/{id}     查询自己的任务
GET  /health            健康检查
```

详细调用方式见 [API_DOCS.md](./API_DOCS.md)。

## 技术栈

```text
Python 3.10+
FastAPI
Kokoro 官方 Python 推理库
misaki[zh]
soundfile
SQLite
原生 HTML/CSS/JavaScript 控制台
```

不需要 Redis、PostgreSQL、消息队列，也不要求 Docker。

## 推荐部署方式：Python venv + 自动重启

你的宝塔 Git 自动部署已经会在拉取最新代码后执行脚本，因此部署脚本填写：

```bash
bash /www/wwwroot/project5/scripts/auto-deploy.sh
```

`auto-deploy.sh` 会自动：

1. 检查 Python 3.10+。
2. 检查/尝试安装 `espeak-ng`。
3. 第一次创建 `.venv`，以后复用。
4. 只有 `requirements.txt` 变化时才重新安装 Python 依赖。
5. 第一次自动生成 `.env` 和随机 `ADMIN_KEY`，以后绝不覆盖。
6. 用 `restart.sh` 重启 Uvicorn，不构建 Docker 镜像。
7. 自动检查 `/health`。

所以后续普通代码更新的过程基本就是：

```text
GitHub push
   ↓
宝塔 Webhook
   ↓
git pull
   ↓
复用 .venv
   ↓
重启 Project5
```

## 第一次部署后的两个动作

### 1. 查看管理密钥

服务器：

```bash
cd /www/wwwroot/project5
cat .env
```

找到：

```text
ADMIN_KEY=admin-p5-xxxxxxxx
```

打开控制台时输入这个管理密钥。

### 2. 宝塔设置反向代理

Project5 默认监听：

```text
127.0.0.1:8005
```

在宝塔当前 Project5 站点的「反向代理」中，目标 URL 填：

```text
http://127.0.0.1:8005
```

然后你的原站点地址/域名就是 Project5 控制台和 API 地址。

Nginx 示例见：

```text
scripts/nginx-project5.conf.example
```

## 手动控制服务

启动：

```bash
bash scripts/start.sh
```

停止：

```bash
bash scripts/stop.sh
```

重启：

```bash
bash scripts/restart.sh
```

日志：

```bash
tail -f logs/app.log
```

健康检查：

```bash
curl http://127.0.0.1:8005/health
```

## 第一次生成为什么可能较慢？

Project5 默认 `PRELOAD_MODEL=0`，服务启动时不马上加载模型，这样部署和重启很快。第一次真正生成语音时，Kokoro 会加载/下载模型资源；之后模型常驻内存，后续请求不需要重新加载。

## 目录

```text
project5/
├── app/
│   ├── main.py            # API、Key、任务、统计
│   ├── tts.py             # Kokoro 中文推理
│   └── static/
│       └── index.html     # 管理控制台
├── data/
│   ├── project5.db        # SQLite（运行时生成）
│   └── audio/             # WAV（运行时生成）
├── scripts/
│   ├── auto-deploy.sh
│   ├── start.sh
│   ├── stop.sh
│   ├── restart.sh
│   └── nginx-project5.conf.example
├── .env.example
├── requirements.txt
├── API_DOCS.md
└── README.md
```

## 安全规则

- `.env` 不提交 GitHub。
- `ADMIN_KEY` 和外部 API Key 分离。
- API Key 服务端只保存 SHA-256 哈希。
- 完整 API Key 仅在创建时返回一次。
- Kokoro 后端只监听 `127.0.0.1`，公网流量通过 Nginx 进入。
