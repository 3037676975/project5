# Project5 TTS API · 直接复制给 AI

> 用法：以后让任何 AI、Agent、代码助手把 Project5 接进你的业务项目时，直接把这份文件完整复制给它。  
> 这不是给人看的教程，而是一份“读完以后必须实际完成接入”的执行上下文。

---

## START — 给 AI 的 Project5 接入上下文

你正在接入一个已经独立部署好的 TTS 服务：**Project5**。

你的任务不是重写 TTS，也不是把 Kokoro / Edge 模型塞进当前业务项目，而是通过 HTTP API 调用 Project5，把文字转换成语音。

业务链路：

```text
业务项目
→ POST 提交文字
→ Project5 返回 task_id
→ 轮询任务
→ completed
→ 取得 audio_url
→ 业务继续播放 / 下载 / 合成视频
```

---

## 1. 默认推荐设置

如果用户没有明确指定其他音色，默认优先使用：

```text
推荐记忆名：ETG1
engine：edge
voice：zh-TW-YunJheNeural
显示名：Edge 云哲 · 台湾男声
speed：1.10
```

非常重要：

```text
ETG1 只是方便用户记忆的推荐名。
真正发送给 API 的 voice 参数必须是：
zh-TW-YunJheNeural
```

不要把 `ETG1` 直接作为 `voice` 发给 API。

---

## 2. 连接配置

当前 Project5 公网请求基地址是：

```text
http://186.244.245.177:28442
```

业务项目通过环境变量读取：

```text
PROJECT5_BASE_URL=http://186.244.245.177:28442
PROJECT5_API_KEY=YOUR_API_KEY
```

因此公开接口的完整请求地址是：

```text
POST http://186.244.245.177:28442/v1/audio/speech
GET  http://186.244.245.177:28442/v1/tasks/{task_id}
GET  http://186.244.245.177:28442/v1/voices?engine=edge
GET  http://186.244.245.177:28442/v1/voices?engine=kokoro
```

如果以后 Project5 绑定了新的正式域名，只修改 `PROJECT5_BASE_URL` 即可，后面的接口路径不变。

所有需要认证的公开 API 都带：

```http
Authorization: Bearer YOUR_API_KEY
```

JSON 请求额外带：

```http
Content-Type: application/json
```

安全要求：

```text
- 不要把真实 API Key 硬编码到源码。
- 不要把真实 API Key 写进浏览器前端。
- 不要提交到公开 GitHub。
- 不要在日志中完整打印 API Key。
```

---

## 3. Project5 公开 API

### 获取 Edge 音色

```http
GET http://186.244.245.177:28442/v1/voices?engine=edge
```

### 获取 Kokoro 音色

```http
GET http://186.244.245.177:28442/v1/voices?engine=kokoro
```

### 提交 TTS 任务

```http
POST http://186.244.245.177:28442/v1/audio/speech
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json
```

默认推荐请求：

```json
{
  "input": "要朗读的文字",
  "engine": "edge",
  "voice": "zh-TW-YunJheNeural",
  "speed": 1.10
}
```

### 查询任务

```http
GET http://186.244.245.177:28442/v1/tasks/{task_id}
Authorization: Bearer YOUR_API_KEY
```

---

## 4. 必须正确理解异步任务

`POST /v1/audio/speech` 成功后通常返回 HTTP `202 Accepted`。

202 的含义：

```text
服务器已经收到任务。
```

它不代表：

```text
音频已经生成完成。
```

响应示例：

```json
{
  "id": "tts_xxxxxxxxx",
  "status": "queued",
  "engine": "edge",
  "voice": "zh-TW-YunJheNeural"
}
```

保存其中的 `id`，把它作为 `task_id`。

然后每隔大约 1 秒查询：

```http
GET /v1/tasks/{task_id}
```

状态处理必须是：

```text
queued
→ 继续等待

processing
→ 继续等待

completed
→ 读取 audio_url
→ 返回给业务层

failed
→ 停止轮询
→ 抛出服务端 error
```

必须设置总超时，例如 180 秒。不能无限轮询。

---

## 5. 你读完这份上下文以后，必须实际完成这些工作

不要只解释 API，也不要只给伪代码。请继续在用户当前项目里完成接入：

1. **先检查项目结构**：确认当前项目使用 Python、Node.js、Java、Go 或其他语言，以及现有 HTTP 客户端和配置方式。
2. **加入环境变量**：增加 `PROJECT5_BASE_URL=http://186.244.245.177:28442` 和 `PROJECT5_API_KEY`，遵守当前项目已有的配置规范。
3. **封装客户端**：至少实现下面三个能力：

```text
get_voices(engine)
submit_tts(text, engine, voice, speed)
wait_for_task(task_id)
```

4. **设置业务默认值**：用户没有指定时，默认：

```text
engine=edge
voice=zh-TW-YunJheNeural
speed=1.10
```

5. **实现完整异步流程**：

```text
POST
→ HTTP 202
→ 读取 task_id
→ GET 轮询
→ completed
→ audio_url
```

6. **做好异常处理**：至少处理：

```text
400 参数错误 / voice 错误
401 / 403 API Key 错误
404 任务不存在
429 / 5xx 服务异常
status=failed
轮询超时
网络超时
```

7. **完成验证**：
   - 如果当前运行环境可以访问 Project5，实际提交一条短文本完成端到端测试。
   - 如果环境不能访问，至少写出可运行的客户端代码和测试，并明确告诉用户“代码已完成，但当前环境未能联网验证”。
8. **最终汇报**：告诉用户：

```text
修改了哪些文件
环境变量怎么配置
业务代码怎么调用
默认音色是什么
测试结果是什么
还有什么需要用户填写
```

---

## 6. Python 最小参考实现

```python
import os
import time
import requests

BASE_URL = os.environ.get("PROJECT5_BASE_URL", "http://186.244.245.177:28442").rstrip("/")
API_KEY = os.environ["PROJECT5_API_KEY"]
AUTH = {"Authorization": f"Bearer {API_KEY}"}


def get_voices(engine="edge"):
    response = requests.get(
        f"{BASE_URL}/v1/voices",
        params={"engine": engine},
        headers=AUTH,
        timeout=10,
    )
    response.raise_for_status()
    return response.json()


def submit_tts(
    text: str,
    engine="edge",
    voice="zh-TW-YunJheNeural",
    speed=1.10,
):
    response = requests.post(
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
    response.raise_for_status()
    data = response.json()
    return data["id"]


def wait_for_task(task_id: str, timeout_seconds=180):
    deadline = time.time() + timeout_seconds

    while time.time() < deadline:
        response = requests.get(
            f"{BASE_URL}/v1/tasks/{task_id}",
            headers=AUTH,
            timeout=10,
        )
        response.raise_for_status()
        data = response.json()

        if data["status"] == "completed":
            return data["audio_url"]

        if data["status"] == "failed":
            raise RuntimeError(data.get("error") or data)

        time.sleep(1)

    raise TimeoutError("Project5 TTS task timeout")


task_id = submit_tts("你好，这是 Project5 TTS API 测试。")
audio_url = wait_for_task(task_id)
print(audio_url)
```

---

## 7. 其他音色的处理规则

默认先使用：

```text
zh-TW-YunJheNeural
```

只有用户明确要求换声音时，再调用：

```http
GET /v1/voices?engine=edge
```

或：

```http
GET /v1/voices?engine=kokoro
```

从真实返回结果里选择 voice `id`。

不要自己猜 voice ID。

---

## 8. 两个引擎怎么理解

```text
Edge
= 在线 TTS
= 服务器需要联网
= 通常输出 MP3
= 默认推荐先使用

Kokoro
= 本地 CPU TTS
= 通常输出 WAV
= 适合需要本地推理或指定 Kokoro 音色的业务
```

---

## 9. 音频保存提醒

Project5 的正式生成音频可能受到后台“音频文件保存策略”影响。

如果管理员开启 24 小时自动清理：

```text
audio_url 对应的正式音频
→ 完成约 24 小时后可能被清理
```

因此业务如果需要长期保存音频，应该在生成完成后及时下载或转存到自己的长期存储。

固定音色试听属于后台资产，不参与这条正式音频清理规则。

---

## 10. 禁止事项

```text
不要把 ETG1 直接作为 API voice 参数。
不要假设 POST 返回后音频已经生成。
不要无限轮询。
不要忽略 failed 状态。
不要自己猜 voice ID。
不要暴露 API Key。
不要在业务项目中重新实现 Project5 内部 TTS 模型。
```

## END — 给 AI 的 Project5 接入上下文
