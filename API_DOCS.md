# Project5 API 中文入门与调用文档

> 如果你的目的不是自己学习，而是要把 Project5 接给另一个 AI / Agent / 代码助手，请直接复制仓库根目录的 **`AI_API_CONTEXT.md`** 给它。那份文件只保留接口、参数、异步任务流程和接入约束，不重复本教程内容。

这份文档不是只告诉你“复制一段代码”，而是从 **API 是什么** 开始，解释 Project5 的 Kokoro / Edge TTS API 到底怎么工作。

---

## 1. 先理解：API 到底是什么？

你可以把 API 理解成“程序之间说话的窗口”。

比如你以后做一个 AI 视频项目：

```text
你的 AI 视频程序
    ↓ 发送一段文字
Project5 TTS API
    ↓ 生成语音
返回音频地址
    ↓
你的程序继续合成视频
```

你不需要让“视频项目”知道 Kokoro 模型怎么加载、Edge TTS 怎么请求、音频怎么保存。

视频项目只需要知道：

1. 我要请求哪个地址（Endpoint）
2. 我要使用什么请求方法（GET / POST）
3. 我要带什么参数（JSON）
4. 我要怎么证明自己有权限（API Key）
5. 服务器会返回什么（Response）

这就是 API 的核心。

---

## 2. 一个 HTTP API 请求由什么组成？

以 Project5 为例：

```http
POST /v1/audio/speech
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json

{
  "input": "你好，today we test ChatGPT，然后继续中文。",
  "engine": "kokoro",
  "voice": "zf_001",
  "speed": 1.0
}
```

这里分别代表：

| 部分 | 含义 |
|---|---|
| `POST` | 我要向服务器提交数据，让它做一件事 |
| `/v1/audio/speech` | 这个功能的 API 地址 |
| `Authorization` | 身份认证，证明你有调用权限 |
| `Bearer YOUR_API_KEY` | 把你创建的 API Key 带过去 |
| `Content-Type: application/json` | 告诉服务器：我发的是 JSON |
| `input` | 要朗读的文字 |
| `engine` | 使用 Kokoro 还是 Edge |
| `voice` | 使用哪个音色 |
| `speed` | 语速 |

---

## 3. 为什么 Project5 不直接把音频返回，而是返回 task_id？

因为 TTS 生成可能需要几秒、几十秒，长文本甚至更久。

如果 API 一直卡着等待，容易超时。所以 Project5 使用 **异步任务**：

```text
第 1 步：提交生成任务
POST /v1/audio/speech
          ↓
马上返回 HTTP 202 + task_id
          ↓
第 2 步：不断查询任务
GET /v1/tasks/{task_id}
          ↓
queued → processing → completed
          ↓
第 3 步：completed 后拿 audio_url
```

这也是很多 AI API 常用的设计方式。

### HTTP 202 是什么意思？

`202 Accepted` 的意思不是“已经生成完成”，而是：

> 服务器已经接收你的任务，并准备处理。

---

## 4. 创建 API Key

进入 Project5 后台：

```text
API 密钥 → 创建密钥
```

创建以后你会拿到类似：

```text
sk-kokoro-xxxxxxxxxxxxxxxxxxxx
```

完整 Key 通常只显示一次，请自己保存。

调用时放在 Header：

```http
Authorization: Bearer sk-kokoro-xxxxxxxxxxxxxxxxxxxx
```

不要把真实 API Key 写到 GitHub 公共仓库或前端网页里。

---

# 5. 获取可用音色

## Kokoro 音色

```http
GET /v1/voices?engine=kokoro
```

会返回 Kokoro 的音色列表，例如：

```json
{
  "engine": "kokoro",
  "voices": [
    {
      "id": "zf_001",
      "label": "中文女声 001",
      "gender": "female"
    }
  ]
}
```

你真正调用时需要的是 `id`：

```text
zf_001
```

后台“音色库 / 固定试听表”里的 **API ID** 就是这个参数。

## Edge 音色

```http
GET /v1/voices?engine=edge
```

例如：

```text
zh-CN-XiaoxiaoNeural
zh-CN-YunxiNeural
zh-CN-YunyangNeural
```

---

# 6. Kokoro 本地 TTS 调用

## 请求

```http
POST /v1/audio/speech
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json

{
  "input": "今天我们学习 ChatGPT and LangChain，然后继续聊 RAG。",
  "engine": "kokoro",
  "voice": "zf_001",
  "speed": 1.0
}
```

字段说明：

| 字段 | 必填 | 说明 |
|---|---:|---|
| `input` | 是 | 要生成的文字 |
| `engine` | 是 | `kokoro` |
| `voice` | 建议 | Kokoro 音色 ID，例如 `zf_001` |
| `speed` | 否 | 0.5 ~ 2.0，默认 1.0 |

Kokoro 在你的服务器本地 CPU 推理，输出 WAV。

---

# 7. Edge 在线 TTS 调用

```http
POST /v1/audio/speech
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json

{
  "input": "你好，这是 Edge TTS 的测试。",
  "engine": "edge",
  "voice": "zh-CN-XiaoxiaoNeural",
  "speed": 1.0
}
```

Edge 需要服务器能够访问互联网，输出 MP3。

---

# 8. 提交任务以后会返回什么？

示例：

```json
{
  "id": "tts_20260907_a1b2c3d4e5",
  "engine": "kokoro",
  "voice": "zf_001",
  "status": "queued",
  "task_url": "http://your-server/v1/tasks/tts_20260907_a1b2c3d4e5"
}
```

最重要的是：

```text
id
```

这个就是任务编号。

---

# 9. 查询任务状态

请求：

```http
GET /v1/tasks/tts_20260907_a1b2c3d4e5
Authorization: Bearer YOUR_API_KEY
```

状态一般会经历：

```text
queued
↓
processing
↓
completed
```

如果出错：

```text
failed
```

完成时可能返回：

```json
{
  "id": "tts_20260907_a1b2c3d4e5",
  "status": "completed",
  "engine": "kokoro",
  "voice": "zf_001",
  "duration": 8.42,
  "audio_url": "http://your-server/audio/tts_20260907_a1b2c3d4e5.wav"
}
```

你的程序接下来就可以读取 `audio_url`。

---

# 10. 用 curl 调用：最适合测试 API

## Kokoro

```bash
curl -X POST "http://YOUR_HOST/v1/audio/speech" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "input": "你好，today we test ChatGPT，然后继续中文。",
    "engine": "kokoro",
    "voice": "zf_001",
    "speed": 1.0
  }'
```

查询：

```bash
curl "http://YOUR_HOST/v1/tasks/TASK_ID" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

---

# 11. Python 调用完整示例

```python
import time
import requests

BASE_URL = "http://YOUR_HOST"
API_KEY = "YOUR_API_KEY"

headers = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
}

payload = {
    "input": "今天学习 ChatGPT and LangChain，然后继续中文。",
    "engine": "kokoro",
    "voice": "zf_001",
    "speed": 1.0,
}

# 1. 提交任务
r = requests.post(
    f"{BASE_URL}/v1/audio/speech",
    headers=headers,
    json=payload,
    timeout=30,
)
r.raise_for_status()
task = r.json()
task_id = task["id"]
print("任务 ID:", task_id)

# 2. 查询任务
while True:
    r = requests.get(
        f"{BASE_URL}/v1/tasks/{task_id}",
        headers=headers,
        timeout=30,
    )
    r.raise_for_status()
    task = r.json()
    print("状态:", task["status"])

    if task["status"] == "completed":
        print("音频:", task["audio_url"])
        break

    if task["status"] == "failed":
        raise RuntimeError(task.get("error", "TTS failed"))

    time.sleep(1)
```

你以后做 AI 视频项目时，核心逻辑其实就是这一段。

---

# 12. JavaScript 调用思路

```javascript
const submit = await fetch('/v1/audio/speech', {
  method: 'POST',
  headers: {
    'Authorization': 'Bearer YOUR_API_KEY',
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    input: '你好，today we test AI，然后继续中文。',
    engine: 'kokoro',
    voice: 'zf_001',
    speed: 1.0
  })
});

const task = await submit.json();
console.log(task.id);
```

正式项目里不要把私密 API Key 直接写在公开浏览器 JavaScript 中，最好让你自己的后端保存 Key。

---

# 13. Project5 的后台 API 与公开 API 有什么区别？

Project5 有两类接口。

## 给你的其他项目调用

```text
POST /v1/audio/speech
GET  /v1/tasks/{id}
GET  /v1/voices
```

认证方式：

```text
Authorization: Bearer API_KEY
```

## 给 Project5 后台管理界面调用

例如：

```text
GET  /admin/previews
POST /admin/previews/generate
POST /admin/previews/generate-batch
GET  /admin/voice-notes
PUT  /admin/voice-notes
GET  /admin/audio-retention
PUT  /admin/audio-retention
```

这些属于管理功能，不建议你的普通业务项目直接依赖它们。

---

# 14. 固定试听和正式音频不是一回事

## 固定音色试听

用途：帮助你比较 103 个 Kokoro 音色，以及 Edge 音色。

```text
/static/previews/...
```

特点：

- 手动生成
- 可以一键生成全部
- 永久保存
- 可以给每个音色写备注
- 不参与 24 小时清理

## 正式生成音频

```text
/audio/tts_xxx.wav
/audio/tts_xxx.mp3
```

可以选择：

```text
手动清理
或
只保留 24 小时
```

即使音频文件被清理，任务历史仍保留，方便追踪曾经使用的 engine / voice / 时间。

---

# 15. 常见 HTTP 状态码

| 状态码 | 含义 |
|---:|---|
| `200` | 请求成功 |
| `202` | 任务已经接收，但还没有生成完成 |
| `400` | 参数不对，例如音色 ID 错误 |
| `401` | API Key 不正确或没有登录 |
| `404` | 任务或音频不存在 |
| `409` | 当前状态不允许这个操作 |
| `500` | 服务器内部错误 |

---

# 16. 以后你的 AI 视频项目应该怎么接 Project5？

建议架构：

```text
文章 / 脚本
    ↓
你的 AI 视频后端
    ↓
调用 Project5 /v1/audio/speech
    ↓
拿 task_id
    ↓
轮询 /v1/tasks/{id}
    ↓
拿 audio_url
    ↓
下载 / 使用音频
    ↓
FFmpeg / 视频合成
```

这样 Project5 就是一个独立的“语音基础服务”。

未来无论你做：

- AI 视频生成
- 知识播客
- 自动配音
- Agent
- RAG 讲解
- 批量短视频

都不需要把 Kokoro / Edge 的模型代码重复塞进主项目。

---

# 17. 一句话理解这套 API

Project5 API 的核心就是：**提交文本生成任务 → 拿 task_id → 查询状态 → 拿 audio_url。**
