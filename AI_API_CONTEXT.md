# Project5 API：直接复制给 AI 的上下文

> 用法：以后让任何 AI、Agent、代码助手接入 Project5 TTS 时，把这份文档完整复制给它。  
> 这是一份“机器可理解的调用说明”，不是教程。

---

## START — 给 AI 的 Project5 TTS 上下文

你正在接入一个已经独立部署好的 TTS 服务：**Project5**。

### 1. 你的目标

不要把 Kokoro 或 Edge 的模型代码复制进业务项目。

正确方式是：

```text
业务项目
→ HTTP 调用 Project5
→ Project5 负责 TTS
→ 返回 task_id
→ 轮询任务状态
→ completed 后取得 audio_url
```

Project5 是独立语音服务。

---

## 2. 基本配置

```text
BASE_URL = http://YOUR_PROJECT5_HOST
API_KEY  = YOUR_API_KEY
```

所有需要认证的公开 API 使用：

```http
Authorization: Bearer YOUR_API_KEY
```

JSON 请求使用：

```http
Content-Type: application/json
```

不要把真实 API Key 写进公开前端或 GitHub 公共仓库。

---

## 3. 支持的 TTS 引擎

### Kokoro

```text
engine = kokoro
```

特点：

```text
本地 CPU 推理
输出 WAV
支持多个 Kokoro voice ID
适合本地生成
```

示例 voice：

```text
zf_001
```

### Edge

```text
engine = edge
```

特点：

```text
在线 TTS
输出 MP3
服务器必须能访问互联网
```

示例 voice：

```text
zh-CN-XiaoxiaoNeural
```

---

## 4. 获取音色

Kokoro：

```http
GET /v1/voices?engine=kokoro
```

Edge：

```http
GET /v1/voices?engine=edge
```

程序应读取返回的 voice `id`，不要自己猜 voice ID。

---

## 5. 提交 TTS 任务

统一接口：

```http
POST /v1/audio/speech
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json
```

Kokoro 示例：

```json
{
  "input": "今天学习 ChatGPT and LangChain，然后继续中文。",
  "engine": "kokoro",
  "voice": "zf_001",
  "speed": 1.0
}
```

Edge 示例：

```json
{
  "input": "你好，这是 Edge TTS 测试。",
  "engine": "edge",
  "voice": "zh-CN-XiaoxiaoNeural",
  "speed": 1.0
}
```

字段：

```text
input  = 要朗读的文本
engine = kokoro 或 edge
voice  = 音色 ID
speed  = 语速，通常使用 1.0
```

---

## 6. 提交后不是直接拿音频

Project5 是异步任务模式。

POST 成功后通常返回 HTTP 202，例如：

```json
{
  "id": "tts_xxxxxxxxx",
  "status": "queued",
  "engine": "kokoro",
  "voice": "zf_001"
}
```

其中最重要的是：

```text
id
```

把它当作 task_id 保存。

---

## 7. 查询任务

使用：

```http
GET /v1/tasks/{task_id}
Authorization: Bearer YOUR_API_KEY
```

状态：

```text
queued
→ processing
→ completed
```

失败：

```text
failed
```

当状态为 `completed` 时，从响应里读取：

```text
audio_url
```

示例：

```json
{
  "id": "tts_xxxxxxxxx",
  "status": "completed",
  "engine": "kokoro",
  "voice": "zf_001",
  "audio_url": "http://YOUR_PROJECT5_HOST/audio/tts_xxxxxxxxx.wav"
}
```

---

## 8. AI 必须遵守的调用逻辑

实现代码时必须使用下面流程：

```text
1. POST /v1/audio/speech
2. 检查 HTTP 状态
3. 读取 task_id
4. 每隔约 1 秒 GET /v1/tasks/{task_id}
5. queued / processing → 继续等待
6. completed → 读取 audio_url
7. failed → 抛出错误，并输出服务端 error
8. 设置合理超时，不能无限轮询
```

不要假设 POST 返回后音频已经生成完成。

---

## 9. Python 参考实现

```python
import time
import requests

BASE_URL = "http://YOUR_PROJECT5_HOST"
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

submit = requests.post(
    f"{BASE_URL}/v1/audio/speech",
    headers=headers,
    json=payload,
    timeout=30,
)
submit.raise_for_status()

task_id = submit.json()["id"]

deadline = time.time() + 300

while time.time() < deadline:
    r = requests.get(
        f"{BASE_URL}/v1/tasks/{task_id}",
        headers=headers,
        timeout=30,
    )
    r.raise_for_status()
    task = r.json()

    if task["status"] == "completed":
        audio_url = task["audio_url"]
        print(audio_url)
        break

    if task["status"] == "failed":
        raise RuntimeError(task.get("error", "Project5 TTS failed"))

    time.sleep(1)
else:
    raise TimeoutError("Project5 TTS task timed out")
```

---

## 10. 普通业务项目只依赖这三个公开接口

```text
POST /v1/audio/speech
GET  /v1/tasks/{id}
GET  /v1/voices?engine=...
```

不要让普通业务项目依赖这些管理接口：

```text
/admin/previews
/admin/voice-notes
/admin/audio-retention
```

这些是 Project5 后台自己的管理功能。

---

## 11. 音频文件说明

正式 TTS 音频：

```text
/audio/...
```

可能由服务器设置成 24 小时自动清理，所以如果业务项目需要长期保存，应在拿到 `audio_url` 后自行下载或转存。

固定音色试听：

```text
/static/previews/...
```

只用于后台比较音色，不应该当作正式业务生成接口。

---

## 12. 接入 Project5 时的默认原则

```text
- 不修改 Project5 内部模型代码，除非用户明确要求。
- 优先调用现有 HTTP API。
- voice ID 通过 /v1/voices 获取。
- Kokoro 和 Edge 共用 /v1/audio/speech。
- 必须处理异步 task_id。
- 必须处理 failed 和 timeout。
- 不把 API Key 暴露到公开前端。
- 需要长期使用音频时，把 audio_url 对应文件下载到业务项目自己的存储。
```

## END — 给 AI 的 Project5 TTS 上下文
