# Project5 API 中文小白教程

> 这份文档是给第一次接触 API 的人看的。  
> 如果你不是自己学，而是想让另一个 AI 直接帮你接入，请把仓库根目录的 **`AI_API_CONTEXT.md`** 完整复制给它。

---

## 先记住两个最重要的信息

### 当前 Project5 公网请求地址

```text
http://186.244.245.177:28442
```

以后所有公开 API 都从这个地址开始。

例如：

```text
生成语音：
http://186.244.245.177:28442/v1/audio/speech

查询任务：
http://186.244.245.177:28442/v1/tasks/{task_id}

Edge 音色：
http://186.244.245.177:28442/v1/voices?engine=edge

Kokoro 音色：
http://186.244.245.177:28442/v1/voices?engine=kokoro
```

如果以后 Project5 换成正式域名，只需要把前面的 BASE_URL 换掉，后面的 `/v1/...` 路径不用改。

### 默认推荐设置

第一次接入 Project5，不需要先研究几十个音色。

先用这一套：

```text
推荐记忆名：ETG1
引擎：edge
实际 voice ID：zh-TW-YunJheNeural
声音：Edge 云哲 · 台湾男声
推荐语速：1.10
```

注意：

```text
ETG1 只是方便记忆的名字。
真正发给 API 的 voice 参数必须是：
zh-TW-YunJheNeural
```

---

# 1. API 到底是什么？

你可以把 API 理解成：

> **两个程序之间办事的窗口。**

例如你以后做一个 AI 视频项目。

视频项目需要一段配音，但是它自己不负责生成声音。

它只需要这样做：

```text
AI 视频项目
↓
把文字交给 Project5
↓
Project5 生成语音
↓
返回音频地址
↓
视频项目继续合成视频
```

这样做的好处是：

```text
Project5 专门负责 TTS
视频项目专门负责视频
知识库项目专门负责知识库
```

不用每做一个新项目，就重新安装一遍 TTS 模型。

---

# 2. 调 API 之前你只需要准备 2 个东西

## 2.1 Project5 地址

当前直接使用：

```text
PROJECT5_BASE_URL=http://186.244.245.177:28442
```

它就是 Project5 的服务器/API 基础地址。

你可以把它理解成“店铺地址”。

例如生成语音这个功能的完整地址就是：

```text
http://186.244.245.177:28442/v1/audio/speech
```

这里：

```text
http://186.244.245.177:28442
= BASE_URL

/v1/audio/speech
= 具体接口路径
```

两部分拼起来就是完整请求地址。

---

## 2.2 API Key

进入 Project5 后台：

```text
API 密钥
→ 创建密钥
→ 复制完整 Key
```

调用 API 时带上：

```http
Authorization: Bearer YOUR_API_KEY
```

API Key 可以理解成“通行证”。

### 安全注意

真实 API Key：

```text
不要写进公开 GitHub
不要直接写进浏览器前端
不要发在公开截图里
不要完整打印进日志
```

正式项目应该放在环境变量里：

```text
PROJECT5_BASE_URL=http://186.244.245.177:28442
PROJECT5_API_KEY=YOUR_API_KEY
```

---

# 3. 小白先认识 6 个词

| 名词 | 你可以怎么理解 |
|---|---|
| BASE_URL | Project5 的基础请求地址 |
| API Key | 调用权限通行证 |
| Endpoint | 某个具体功能的窗口 |
| POST | 向服务器提交一件事情 |
| JSON | 提交给服务器的一张参数表 |
| task_id | 任务取件号 |

例如：

```http
POST http://186.244.245.177:28442/v1/audio/speech
```

意思就是：

```text
我要向 Project5 提交一个“生成语音”的任务。
```

---

# 4. 第一次调用，直接用默认推荐音色

完整请求：

```http
POST http://186.244.245.177:28442/v1/audio/speech
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json
```

Body：

```json
{
  "input": "你好，这是 Project5 API 的第一次测试。",
  "engine": "edge",
  "voice": "zh-TW-YunJheNeural",
  "speed": 1.10
}
```

这几个参数分别是什么意思：

| 参数 | 意思 | 推荐值 |
|---|---|---|
| input | 要朗读的文字 | 你自己的文本 |
| engine | 使用哪个 TTS 引擎 | edge |
| voice | 使用哪个音色 | zh-TW-YunJheNeural |
| speed | 语速 | 1.10 |

---

# 5. 为什么 POST 后没有立刻返回 MP3？

这是理解 Project5 API 最重要的一点。

Project5 使用的是：

```text
异步任务
```

因为 TTS 可能需要几秒甚至更久。

如果一直让一个 HTTP 请求卡在那里等，很容易超时。

所以流程是：

```text
POST 提交文字
↓
Project5 接收任务
↓
马上返回 HTTP 202 + task_id
↓
你的程序拿 task_id 查询进度
↓
completed
↓
拿到 audio_url
```

---

# 6. HTTP 202 到底是什么意思？

`202 Accepted` 的意思是：

> Project5 已经收到你的任务，准备处理。

它不是：

> 音频已经生成完成。

例如返回：

```json
{
  "id": "tts_20260907_xxxxxxxxxx",
  "status": "queued",
  "engine": "edge",
  "voice": "zh-TW-YunJheNeural"
}
```

最重要的是：

```text
id
```

这个 id 就是 `task_id`。

你可以把它理解成取件号码。

---

# 7. 拿 task_id 查询任务

完整请求地址：

```http
GET http://186.244.245.177:28442/v1/tasks/tts_20260907_xxxxxxxxxx
Authorization: Bearer YOUR_API_KEY
```

状态通常是：

```text
queued
↓
processing
↓
completed
```

也可能：

```text
failed
```

你的代码应该这样判断：

```text
queued
→ 等 1 秒继续查

processing
→ 等 1 秒继续查

completed
→ 读取 audio_url

failed
→ 停止并读取 error
```

程序一定要有总超时，例如：

```text
180 秒
```

不能无限查询。

---

# 8. completed 后真正拿到什么？

示例：

```json
{
  "id": "tts_20260907_xxxxxxxxxx",
  "status": "completed",
  "engine": "edge",
  "voice": "zh-TW-YunJheNeural",
  "audio_url": "http://186.244.245.177:28442/audio/tts_20260907_xxxxxxxxxx.mp3"
}
```

其中：

```text
audio_url
```

就是最终生成出来的音频地址。

你的项目可以：

```text
播放它
下载它
保存它
交给视频合成程序
交给播客生成程序
```

---

# 9. 完整调用逻辑

把前面所有知识合起来，其实就是：

```text
1. BASE_URL = http://186.244.245.177:28442
2. 准备 API Key
3. POST /v1/audio/speech
4. 得到 HTTP 202
5. 保存 id
6. GET /v1/tasks/{id}
7. queued / processing → 继续等
8. completed → 拿 audio_url
9. failed → 报错
```

一句话记忆：

```text
BASE_URL = Project5 地址
API Key = 通行证
POST = 下单
202 = 已接单
id = 取件号
GET task = 查进度
audio_url = 最终成品
```

---

# 10. curl 第一次测试

先设置地址和 API Key：

```bash
export PROJECT5_BASE_URL="http://186.244.245.177:28442"
export PROJECT5_API_KEY="你的完整API密钥"
```

然后提交生成任务：

```bash
curl -X POST "$PROJECT5_BASE_URL/v1/audio/speech" \
  -H "Authorization: Bearer $PROJECT5_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "input": "你好，这是 Project5 API 的第一次测试。",
    "engine": "edge",
    "voice": "zh-TW-YunJheNeural",
    "speed": 1.10
  }'
```

它会先返回 task_id。

然后再查：

```bash
curl \
  -H "Authorization: Bearer $PROJECT5_API_KEY" \
  "$PROJECT5_BASE_URL/v1/tasks/你的task_id"
```

---

# 11. Python 完整最小示例

```python
import os
import time
import requests

BASE_URL = os.environ.get(
    "PROJECT5_BASE_URL",
    "http://186.244.245.177:28442",
).rstrip("/")

API_KEY = os.environ["PROJECT5_API_KEY"]

HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
}


def submit_tts(
    text: str,
    engine="edge",
    voice="zh-TW-YunJheNeural",
    speed=1.10,
):
    response = requests.post(
        f"{BASE_URL}/v1/audio/speech",
        headers={
            **HEADERS,
            "Content-Type": "application/json",
        },
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
            headers=HEADERS,
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


task_id = submit_tts(
    "你好，这是 Project5 API 的第一次测试。"
)

audio_url = wait_for_task(task_id)

print(audio_url)
```

你现在不需要一开始就完全看懂 Python。

先理解：

```text
submit_tts()
= 提交任务

wait_for_task()
= 拿任务编号等待结果
```

就够了。

---

# 12. 获取其他音色

如果默认的云哲台湾男声已经够用，你甚至可以暂时不看这一节。

以后需要换声音，再调用。

## Edge 音色

```http
GET http://186.244.245.177:28442/v1/voices?engine=edge
```

## Kokoro 音色

```http
GET http://186.244.245.177:28442/v1/voices?engine=kokoro
```

程序应该使用接口真实返回的 `id`。

不要自己猜 voice ID。

---

# 13. Edge 和 Kokoro 有什么区别？

| 引擎 | 工作方式 | 输出 | 什么时候用 |
|---|---|---|---|
| Edge | 在线 TTS，需要服务器联网 | MP3 | 默认推荐，快速稳定接入 |
| Kokoro | 本地 CPU 推理 | WAV | 想本地生成或使用 Kokoro 音色时 |

第一次接 API：

```text
先用 Edge 云哲台湾男声 + 1.10
```

等整个业务流程跑通之后，再考虑换其他声音。

---

# 14. 常见错误

## 401 / 403

通常先检查：

```text
API Key 对不对
Authorization 有没有 Bearer
Key 是否已经停用
```

---

## 400 / Unknown voice

最常见错误之一。

不要写：

```json
{
  "voice": "ETG1"
}
```

应该写：

```json
{
  "voice": "zh-TW-YunJheNeural"
}
```

---

## 一直 queued / processing

正常情况下应该继续轮询。

但程序必须有：

```text
总超时
```

如果长时间不完成，可以进入后台的“生成任务”检查。

---

## status = failed

不要只告诉用户“失败”。

应该读取：

```text
error
```

这样才能知道是网络、音色还是 TTS 服务出错。

---

# 15. audio_url 会永久存在吗？

不一定。

Project5 后台有：

```text
音频文件保存策略
```

如果管理员打开：

```text
24小时自动清理
```

正式生成的 WAV / MP3 在完成约 24 小时以后可能被清理。

所以业务项目如果需要长期保存：

```text
生成完成
↓
拿到 audio_url
↓
及时下载 / 转存到自己的长期存储
```

固定音色试听属于后台资产，不走这条正式音频清理规则。

---

# 16. 我不会接 API，最省事的方法是什么？

直接打开：

```text
AI_API_CONTEXT.md
```

把整份内容复制给 AI。

它里面不仅告诉 AI 接口是什么，还明确告诉 AI 当前 Project5 请求地址：

```text
http://186.244.245.177:28442
```

并要求 AI：

```text
检查你的项目
添加环境变量
写客户端
默认用云哲台湾男声 1.10
实现异步轮询
做错误处理
实际测试
最后告诉你改了哪些文件
```

所以你不需要自己先学会写完整代码，再让 AI 接入。

你只需要先理解这条逻辑：

```text
文字
→ POST http://186.244.245.177:28442/v1/audio/speech
→ task_id
→ 查询任务
→ audio_url
```

这就是 Project5 API 最核心的调用方法。
