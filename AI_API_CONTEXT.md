# Project5 TTS API · 直接复制给 AI

> 以后让任何 AI、Agent、代码助手接入 Project5 时，直接把这份文件完整复制给它即可。不要让它自己猜接口，也不要让它把 Kokoro / Edge 模型重新塞进业务项目。

## START — 给 AI 的接入上下文

你正在接入一个已经独立部署好的 TTS 服务：**Project5**。

你的任务是：业务项目通过 HTTP 调用 Project5，把文字转换成语音。

```text
业务项目
→ POST 提交文字
→ Project5 返回 task_id
→ 轮询任务
→ completed
→ 取得 audio_url
```

### 连接配置

```text
PROJECT5_BASE_URL=http://YOUR_PROJECT5_HOST
PROJECT5_API_KEY=YOUR_API_KEY
```

所有需要认证的请求都带：

```http
Authorization: Bearer YOUR_API_KEY
```

不要把真实 API Key 写进公开前端或公共 GitHub。

---

## 1. 支持的引擎

```text
kokoro = 本地 CPU TTS，通常输出 WAV
edge   = 在线 Edge TTS，通常输出 MP3
```

---

## 2. 获取真实音色 ID

Kokoro：

```http
GET /v1/voices?engine=kokoro
```

Edge：

```http
GET /v1/voices?engine=edge
```

程序应优先使用这里返回的 `id`，不要自己猜 voice ID。

示例：

```text
Kokoro: zf_001
Edge:   zh-CN-XiaoxiaoNeural
```

---

## 3. 提交 TTS 任务

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

参数：

```text
input  = 要朗读的文字
engine = kokoro 或 edge
voice  = /v1/voices 返回的音色 ID
speed  = 语速，默认建议 1.0
```

---

## 4. 这是异步 API

`POST /v1/audio/speech` 成功后不是直接返回音频，而是返回 HTTP `202 Accepted` 和任务 ID。

示例：

```json
{
  "id": "tts_xxxxxxxxx",
  "status": "queued",
  "engine": "kokoro",
  "voice": "zf_001"
}
```

保存 `id`，然后查询：

```http
GET /v1/tasks/{id}
Authorization: Bearer YOUR_API_KEY
```

状态：

```text
queued → processing → completed
                     ↘ failed
```

当 `status == "completed"` 时读取：

```text
audio_url
```

当 `status == "failed"` 时停止轮询并抛出明确错误。

建议每 `1 秒` 查询一次，并设置总超时，不要无限轮询。

---

## 5. 你需要实现的封装

请直接实现以下 3 个函数：

```text
get_voices(engine)
submit_tts(input, engine, voice, speed=1.0)
wait_for_task(task_id)
```

业务层只调用这三个封装，不直接接触 Project5 内部模型代码。

完整逻辑：

```text
输入文字
↓
选择 engine
↓
确认 voice ID
↓
submit_tts()
↓
拿 task_id
↓
wait_for_task()
↓
completed → 返回 audio_url
failed / timeout → 报错
```

---

## 6. Python 最小实现

```python
import os
import time
import requests

BASE_URL = os.environ["PROJECT5_BASE_URL"].rstrip("/")
API_KEY = os.environ["PROJECT5_API_KEY"]
AUTH = {"Authorization": f"Bearer {API_KEY}"}


def get_voices(engine: str):
    r = requests.get(
        f"{BASE_URL}/v1/voices",
        params={"engine": engine},
        headers=AUTH,
        timeout=10,
    )
    r.raise_for_status()
    return r.json()


def submit_tts(text: str, engine="kokoro", voice="zf_001", speed=1.0):
    r = requests.post(
        f"{BASE_URL}/v1/audio/speech",
        headers={**AUTH, "Content-Type": "application/json"},
        json={
            "input": text,
            "engine": engine,
            "voice": voice,
            "speed": speed,
        },
        timeout=15,
    )
    r.raise_for_status()
    return r.json()["id"]


def wait_for_task(task_id: str, timeout_seconds=180):
    deadline = time.time() + timeout_seconds

    while time.time() < deadline:
        r = requests.get(
            f"{BASE_URL}/v1/tasks/{task_id}",
            headers=AUTH,
            timeout=10,
        )
        r.raise_for_status()
        data = r.json()

        if data["status"] == "completed":
            return data["audio_url"]
        if data["status"] == "failed":
            raise RuntimeError(data)

        time.sleep(1)

    raise TimeoutError("Project5 TTS task timeout")


# 示例
id_ = submit_tts(
    "今天测试 ChatGPT and LangChain，然后继续中文。",
    engine="kokoro",
    voice="zf_001",
)
print(wait_for_task(id_))
```

---

## 7. AI 必须遵守的规则

1. 不要把 `202 Accepted` 当成音频已经生成完成。
2. 不要假设 POST 会直接返回二进制音频。
3. 不要自己编造 `voice`，优先读取 `/v1/voices`。
4. 不要把 API Key 写进前端或公开仓库。
5. 不要写死 WAV / MP3 后缀，优先使用服务端返回的 `audio_url`。
6. 如果 Project5 开启了“24 小时自动清理”，需要长期保存的音频应在生成完成后及时下载或复制到业务项目自己的存储。
7. 任务 `failed` 时记录服务端错误，不要无限自动重试。
8. 默认测试可以使用 `kokoro + zf_001 + speed=1.0`；需要在线快速生成时可使用 `edge + zh-CN-XiaoxiaoNeural`。

## END — 给 AI 的接入上下文
