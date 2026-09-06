# Project5 API 使用文档

Project5 只提供一个模型：`Kokoro-82M-v1.1-zh`。

## 认证

在控制台「API 密钥」里创建 Key，例如：

```text
sk-kokoro-xxxxxxxxxxxxxxxx
```

请求头：

```http
Authorization: Bearer sk-kokoro-xxxxxxxxxxxxxxxx
Content-Type: application/json
```

## 生成语音

`POST /v1/audio/speech`

```json
{
  "input": "欢迎来到 AI 技术分享频道，今天我们学习什么是 RAG。",
  "voice": "zf_001",
  "speed": 1.0
}
```

参数：

- `input`：需要朗读的文字，必填。
- `voice`：中文音色，例如 `zf_001`、`zm_010`。
- `speed`：语速，范围 `0.5` - `2.0`，默认 `1.0`。
- `model`：不用传。Project5 永远使用 `Kokoro-82M-v1.1-zh`。

成功响应示例：

```json
{
  "id": "tts_20260906_ab12cd34ef",
  "status": "completed",
  "model": "kokoro-82m-v1.1-zh",
  "voice": "zf_001",
  "speed": 1.0,
  "duration": 8.21,
  "audio_url": "https://your-domain.example/audio/tts_20260906_ab12cd34ef.wav"
}
```

## cURL

```bash
curl https://your-domain.example/v1/audio/speech \
  -H "Authorization: Bearer sk-kokoro-xxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{"input":"欢迎来到 AI 技术分享频道","voice":"zf_001","speed":1.0}'
```

## Python

```python
import requests

r = requests.post(
    "https://your-domain.example/v1/audio/speech",
    headers={"Authorization": "Bearer sk-kokoro-xxxxxxxx"},
    json={
        "input": "欢迎来到 AI 技术分享频道",
        "voice": "zf_001",
        "speed": 1.0,
    },
)
print(r.json())
```

## JavaScript

```javascript
const r = await fetch("https://your-domain.example/v1/audio/speech", {
  method: "POST",
  headers: {
    "Authorization": "Bearer sk-kokoro-xxxxxxxx",
    "Content-Type": "application/json"
  },
  body: JSON.stringify({
    input: "欢迎来到 AI 技术分享频道",
    voice: "zf_001",
    speed: 1.0
  })
});
console.log(await r.json());
```

## 查看音色

`GET /v1/voices`

不需要 API Key。返回当前 Project5 支持的全部中文 voice ID。

## 查询任务

`GET /v1/tasks/{task_id}`

需要使用创建该任务时相同的 API Key。

## 管理后台

管理后台和外部 API Key 是两套密钥：

- `ADMIN_KEY`：只用于进入 Project5 管理控制台。
- `sk-kokoro-*`：给 Project4、脚本、Agent 或其他程序调用 TTS API。

`ADMIN_KEY` 保存在服务器 `.env`，不要提交到 GitHub。
