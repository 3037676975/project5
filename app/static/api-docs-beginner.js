(() => {
  const VERSION = 'api-beginner-etg1-v1';
  const RECOMMENDED = {
    nickname: 'ETG1',
    engine: 'edge',
    voice: 'zh-TW-YunJheNeural',
    label: 'Edge 云哲 · 台湾男声',
    speed: 1.10,
  };

  const esc = (value) => String(value ?? '').replace(/[&<>"']/g, ch => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));

  const AI_CONTEXT = `你正在接入一个已经独立部署好的 TTS 服务：Project5。

【你的任务】
不要把 Kokoro / Edge 的模型代码复制进当前业务项目。请把 Project5 当成独立 HTTP API 服务，完成真正的调用接入。

【默认推荐设置】
如果用户没有另外指定音色，优先使用：
engine = edge
voice = zh-TW-YunJheNeural
speed = 1.10
说明：这是后台记忆名“ETG1”，显示名“Edge 云哲 · 台湾男声”。ETG1 不是 API voice 参数，真正发送给 API 的 voice 必须是 zh-TW-YunJheNeural。

【连接配置】
PROJECT5_BASE_URL=http://YOUR_PROJECT5_HOST
PROJECT5_API_KEY=YOUR_API_KEY
所有需要认证的公开请求都带：
Authorization: Bearer YOUR_API_KEY
不要把真实 API Key 硬编码进前端、代码仓库或日志。

【公开 API】
1. GET /v1/voices?engine=edge
2. GET /v1/voices?engine=kokoro
3. POST /v1/audio/speech
4. GET /v1/tasks/{task_id}

【默认 TTS 请求】
POST /v1/audio/speech
Content-Type: application/json
Authorization: Bearer YOUR_API_KEY
Body:
{
  "input": "要朗读的文字",
  "engine": "edge",
  "voice": "zh-TW-YunJheNeural",
  "speed": 1.10
}

【异步任务规则】
POST 成功后通常返回 HTTP 202。202 只代表服务器已经接收任务，不代表音频已经生成完成。
保存响应里的 id 作为 task_id，然后每隔约 1 秒请求：
GET /v1/tasks/{task_id}
状态 queued / processing：继续等待。
状态 completed：读取 audio_url，并把它返回给业务层。
状态 failed：停止轮询并抛出服务端 error。
必须设置总超时，不能无限轮询。

【你读完以后必须实际完成这些工作】
1. 先检查当前项目使用的语言、框架和现有 HTTP 客户端，不要盲目新建一套技术栈。
2. 增加 PROJECT5_BASE_URL 和 PROJECT5_API_KEY 的环境变量配置，密钥只能放服务端安全配置。
3. 封装至少三个函数：get_voices(engine)、submit_tts(text, engine, voice, speed)、wait_for_task(task_id)。
4. 业务代码默认使用 edge + zh-TW-YunJheNeural + 1.10；用户明确指定其他音色时再覆盖默认值。
5. 正确实现 202 → task_id → 轮询 → completed → audio_url 的完整流程。
6. 处理 401/403、400、404、429/5xx、failed 和 timeout，不要静默失败。
7. 如果当前环境允许访问 Project5，实际提交一条短文本做端到端测试；如果环境不允许访问，至少完成可运行的客户端代码和测试，并明确说明未能联网验证。
8. 完成后向用户汇报：修改了哪些文件、环境变量怎么配、业务代码怎么调用、验证结果是什么。

【禁止】
- 不要把 ETG1 当成 voice 参数发送。
- 不要假设 POST 后立即有音频。
- 不要自己猜不存在的 voice ID；其他音色先调用 /v1/voices 获取真实 id。
- 不要把真实 API Key 提交到 GitHub。
- 不要重写 Project5 内部 TTS 模型实现，除非用户明确要求修改 Project5 本身。`;

  const CURL_EXAMPLE = `curl -X POST "$PROJECT5_BASE_URL/v1/audio/speech" \\
  -H "Authorization: Bearer $PROJECT5_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{
    "input": "你好，这是 Project5 API 的第一次测试。",
    "engine": "edge",
    "voice": "zh-TW-YunJheNeural",
    "speed": 1.10
  }'`;

  const PYTHON_EXAMPLE = `import os
import time
import requests

BASE_URL = os.environ["PROJECT5_BASE_URL"].rstrip("/")
API_KEY = os.environ["PROJECT5_API_KEY"]
HEADERS = {"Authorization": f"Bearer {API_KEY}"}


def submit_tts(text, voice="zh-TW-YunJheNeural", speed=1.10):
    r = requests.post(
        f"{BASE_URL}/v1/audio/speech",
        headers={**HEADERS, "Content-Type": "application/json"},
        json={
            "input": text,
            "engine": "edge",
            "voice": voice,
            "speed": speed,
        },
        timeout=15,
    )
    r.raise_for_status()
    return r.json()["id"]


def wait_for_task(task_id, timeout_seconds=180):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        r = requests.get(
            f"{BASE_URL}/v1/tasks/{task_id}",
            headers=HEADERS,
            timeout=10,
        )
        r.raise_for_status()
        data = r.json()
        if data["status"] == "completed":
            return data["audio_url"]
        if data["status"] == "failed":
            raise RuntimeError(data.get("error") or data)
        time.sleep(1)
    raise TimeoutError("Project5 TTS task timeout")


task_id = submit_tts("你好，这是 Project5 API 的第一次测试。")
print(wait_for_task(task_id))`;

  async function copyText(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (_) {}
    const textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.setAttribute('readonly', '');
    textarea.style.position = 'fixed';
    textarea.style.left = '-9999px';
    document.body.appendChild(textarea);
    textarea.select();
    const ok = document.execCommand('copy');
    textarea.remove();
    return ok;
  }

  function notify(message) {
    if (typeof toast === 'function') toast(message);
    else console.log(message);
  }

  function installCss() {
    if (document.getElementById('p5ApiBeginnerCss')) return;
    const style = document.createElement('style');
    style.id = 'p5ApiBeginnerCss';
    style.textContent = `
      #p5ApiDocsV2.p5-api-beginner{margin-top:0;border-top:0;padding-top:0}.p5-api-beginner *{box-sizing:border-box}
      .p5-api-hero{padding:22px;border:1px solid #dbeafe;border-radius:18px;background:linear-gradient(135deg,#eff6ff,#fff);margin-bottom:18px}
      .p5-api-hero h2{font-size:22px!important;margin:6px 0 8px!important}.p5-api-kicker{font-size:12px;font-weight:800;color:#2563eb;letter-spacing:.06em;text-transform:uppercase}
      .p5-api-reco{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin:14px 0}.p5-api-reco>div{padding:12px;border:1px solid #bfdbfe;background:#fff;border-radius:12px}.p5-api-reco span{display:block;font-size:11px;color:#64748b}.p5-api-reco b{display:block;margin-top:4px;font-size:13px;word-break:break-word}
      .p5-api-step{display:grid;grid-template-columns:44px 1fr;gap:12px;margin:16px 0}.p5-api-step-num{width:38px;height:38px;border-radius:50%;display:grid;place-items:center;background:#2563eb;color:#fff;font-weight:800}.p5-api-step-body{padding:14px 16px;border:1px solid #e5eaf1;border-radius:14px;background:#fff}.p5-api-step-body h3{margin:0 0 6px!important;font-size:15px!important}.p5-api-step-body p{margin:4px 0}
      .p5-api-terms{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;margin:14px 0}.p5-api-term{padding:13px;border-radius:12px;background:#f8fafc;border:1px solid #e5eaf1}.p5-api-term b{display:block;margin-bottom:4px}.p5-api-term span{font-size:12px;color:#64748b;line-height:1.6}
      .p5-api-callout{padding:14px 16px;border-radius:13px;background:#fff7ed;border:1px solid #fed7aa;color:#9a3412;margin:14px 0}.p5-api-success{background:#f0fdf4;border-color:#bbf7d0;color:#166534}.p5-api-code-head{display:flex;justify-content:space-between;gap:10px;align-items:center;margin:16px 0 7px}.p5-api-code-head b{font-size:13px}.p5-api-beginner .code{font-size:12px;line-height:1.7;white-space:pre-wrap;word-break:break-word}
      .p5-api-actions{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0}.p5-api-flow{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:14px 0}.p5-api-flow span{padding:8px 10px;border:1px solid #dbeafe;background:#f8fbff;border-radius:10px;font-size:12px}.p5-api-arrow{color:#93a4ba!important;border:0!important;background:transparent!important;padding:0!important}.p5-api-ai{border:1px solid #c7d2fe;border-radius:16px;padding:16px;background:#f7f7ff;margin-top:20px}
      @media(max-width:820px){.p5-api-reco{grid-template-columns:1fr 1fr}.p5-api-terms{grid-template-columns:1fr 1fr}}
      @media(max-width:560px){.p5-api-reco,.p5-api-terms{grid-template-columns:1fr}.p5-api-step{grid-template-columns:1fr}.p5-api-step-num{width:32px;height:32px}.p5-api-code-head{align-items:flex-start;flex-direction:column}.p5-api-beginner .code{font-size:11px}}
    `;
    document.head.appendChild(style);
  }

  function render() {
    const panel = document.querySelector('#docs .panel');
    if (!panel) return false;
    installCss();
    panel.innerHTML = `
      <div id="p5ApiDocsV2" class="p5-api-beginner doc" data-version="${VERSION}">
        <div class="p5-api-hero">
          <div class="p5-api-kicker">Project5 API · 小白入门</div>
          <h2>不会写代码也能先看懂：一个项目到底怎样调用 Project5 生成语音？</h2>
          <p class="muted">把 API 想成“程序之间办事的窗口”：你的项目把文字交给 Project5，Project5 生成语音，再把音频地址交回来。你不需要把 TTS 模型重新装进每个项目。</p>
          <div class="p5-api-reco">
            <div><span>默认推荐记忆名</span><b>${RECOMMENDED.nickname}</b></div>
            <div><span>实际 API 音色 ID</span><b>${RECOMMENDED.voice}</b></div>
            <div><span>声音</span><b>${RECOMMENDED.label}</b></div>
            <div><span>推荐语速</span><b>${RECOMMENDED.speed.toFixed(2)}</b></div>
          </div>
          <div class="p5-api-callout p5-api-success"><b>先记住：</b>你说的“ETG1”是方便记忆的推荐名，真正发给 API 的 <span class="p5-inline-code">voice</span> 必须是 <span class="p5-inline-code">zh-TW-YunJheNeural</span>。</div>
        </div>

        <h3>先认识 6 个最重要的词</h3>
        <div class="p5-api-terms">
          <div class="p5-api-term"><b>BASE_URL</b><span>Project5 的网站/API 地址，相当于“店铺地址”。</span></div>
          <div class="p5-api-term"><b>API Key</b><span>调用通行证。后台左侧「API 密钥」里创建。</span></div>
          <div class="p5-api-term"><b>Endpoint</b><span>具体办什么业务的窗口，例如 /v1/audio/speech。</span></div>
          <div class="p5-api-term"><b>POST</b><span>向服务器提交一份任务，例如“把这段文字生成语音”。</span></div>
          <div class="p5-api-term"><b>JSON</b><span>程序提交给服务器的参数表单。</span></div>
          <div class="p5-api-term"><b>task_id</b><span>任务取件号。拿到它后继续查询任务是否完成。</span></div>
        </div>

        <h3>完整调用逻辑，只看这一条线也可以</h3>
        <div class="p5-api-flow">
          <span>你的程序</span><span class="p5-api-arrow">→</span><span>POST 文字</span><span class="p5-api-arrow">→</span><span>202 + task_id</span><span class="p5-api-arrow">→</span><span>轮询任务</span><span class="p5-api-arrow">→</span><span>completed</span><span class="p5-api-arrow">→</span><span>audio_url</span>
        </div>

        <div class="p5-api-step"><div class="p5-api-step-num">1</div><div class="p5-api-step-body"><h3>先创建 API Key</h3><p class="muted">左侧进入「API 密钥」→ 创建密钥 → 保存完整 Key。调用时放在请求头：<span class="p5-inline-code">Authorization: Bearer YOUR_API_KEY</span>。真实 Key 不要写进公开 GitHub 或浏览器前端。</p></div></div>
        <div class="p5-api-step"><div class="p5-api-step-num">2</div><div class="p5-api-step-body"><h3>先用默认推荐设置，不要一开始纠结音色</h3><p class="muted">第一次接入建议直接使用 Edge 云哲台湾男声：<span class="p5-inline-code">engine=edge</span>、<span class="p5-inline-code">voice=zh-TW-YunJheNeural</span>、<span class="p5-inline-code">speed=1.10</span>。以后想换声音，再调用 <span class="p5-inline-code">GET /v1/voices?engine=edge</span> 查询真实 voice ID。</p></div></div>
        <div class="p5-api-step"><div class="p5-api-step-num">3</div><div class="p5-api-step-body"><h3>提交语音生成任务</h3><p class="muted">向 <span class="p5-inline-code">POST /v1/audio/speech</span> 提交文字、引擎、音色和语速。</p></div></div>

        <div class="p5-api-code-head"><b>第一次请求：推荐直接照着这个格式</b></div>
        <div class="code">POST /v1/audio/speech\nAuthorization: Bearer YOUR_API_KEY\nContent-Type: application/json\n\n{\n  "input": "你好，这是 Project5 API 的第一次测试。",\n  "engine": "edge",\n  "voice": "zh-TW-YunJheNeural",\n  "speed": 1.10\n}</div>

        <div class="p5-api-callout"><b>为什么不是马上返回 MP3？</b> 因为 TTS 可能需要时间，所以 Project5 用“异步任务”。HTTP 202 的意思只是“我已经收到你的任务”，不是“已经生成完成”。</div>

        <div class="p5-api-step"><div class="p5-api-step-num">4</div><div class="p5-api-step-body"><h3>保存返回的 id</h3><p class="muted">提交成功后通常返回 <span class="p5-inline-code">HTTP 202</span>，响应里的 <span class="p5-inline-code">id</span> 就是 task_id。</p></div></div>
        <div class="code">{\n  "id": "tts_20260907_xxxxxxxxxx",\n  "status": "queued",\n  "engine": "edge",\n  "voice": "zh-TW-YunJheNeural"\n}</div>
        <div class="p5-api-step"><div class="p5-api-step-num">5</div><div class="p5-api-step-body"><h3>拿 task_id 查询进度</h3><p class="muted">每隔大约 1 秒请求一次 <span class="p5-inline-code">GET /v1/tasks/{task_id}</span>。queued / processing 就继续等；completed 就读取 audio_url；failed 就停止并显示 error。</p></div></div>
        <div class="code">GET /v1/tasks/tts_20260907_xxxxxxxxxx\nAuthorization: Bearer YOUR_API_KEY</div>
        <div class="p5-api-step"><div class="p5-api-step-num">6</div><div class="p5-api-step-body"><h3>completed 后拿 audio_url</h3><p class="muted">audio_url 就是最终结果。你的 AI 视频、播客、知识库项目可以下载它、播放它，或者继续进入视频合成流程。</p></div></div>

        <h3>想自己实际试一下：curl</h3>
        <p class="muted">先把环境变量里的地址和 API Key 换成你自己的，然后执行。这个例子默认就是 ETG1 / 云哲 / 1.10。</p>
        <div class="p5-api-code-head"><b>curl 示例</b><button class="btn small secondary" id="p5CopyCurl">复制 curl</button></div>
        <div class="code">${esc(CURL_EXAMPLE)}</div>

        <h3>Python 完整最小示例</h3>
        <p class="muted">这段代码已经包含“提交任务 → 保存 task_id → 轮询 → 返回 audio_url”的完整逻辑。</p>
        <div class="code">${esc(PYTHON_EXAMPLE)}</div>

        <h3>两个引擎怎么选？</h3>
        <table><thead><tr><th>引擎</th><th>你可以怎么理解</th><th>适合</th></tr></thead><tbody>
          <tr><td><b>Edge</b></td><td>服务器联网调用在线语音服务，输出 MP3</td><td><b>默认推荐</b>，先用云哲台湾男声快速接通业务</td></tr>
          <tr><td><b>Kokoro</b></td><td>服务器本地 CPU 推理，输出 WAV</td><td>需要本地生成、想使用 Kokoro 音色库时</td></tr>
        </tbody></table>

        <h3>常见错误怎么看？</h3>
        <table><thead><tr><th>现象</th><th>先检查什么</th></tr></thead><tbody>
          <tr><td>401 / 403</td><td>API Key 是否正确、是否启用、Authorization 是否带 Bearer。</td></tr>
          <tr><td>400 Unknown voice</td><td>不要传 ETG1；实际 voice 应传 zh-TW-YunJheNeural，其他声音先查 /v1/voices。</td></tr>
          <tr><td>一直 queued / processing</td><td>继续轮询，但程序必须有总超时；同时查看后台生成任务。</td></tr>
          <tr><td>status=failed</td><td>读取响应里的 error，不要忽略服务端错误。</td></tr>
          <tr><td>拿到 audio_url 后过一段时间失效</td><td>后台若开启“24小时自动清理”，正式生成音频会按保存策略清理；固定试听不受影响。</td></tr>
        </tbody></table>

        <div class="p5-api-ai">
          <h3 style="margin-top:0!important">不会接 API？把下面整段直接复制给 AI</h3>
          <p class="muted">这不是只告诉 AI “接口有哪些”，还明确要求它读完以后真正修改你的业务项目、封装客户端、加环境变量、完成轮询并验证。</p>
          <div class="p5-api-actions"><button class="btn" id="p5CopyAiContext">一键复制给 AI</button><a class="btn secondary" href="/static/api-guide-zh.html" target="_blank" rel="noopener">打开完整小白教程</a></div>
          <div class="code" id="p5AiContextBlock">${esc(AI_CONTEXT)}</div>
        </div>
      </div>`;

    document.getElementById('p5CopyAiContext')?.addEventListener('click', async () => {
      notify(await copyText(AI_CONTEXT) ? '已复制：直接粘贴给 AI 即可' : '复制失败，请手动选择代码块');
    });
    document.getElementById('p5CopyCurl')?.addEventListener('click', async () => {
      notify(await copyText(CURL_EXAMPLE) ? 'curl 示例已复制' : '复制失败，请手动选择代码块');
    });
    return true;
  }

  let attempts = 0;
  const timer = setInterval(() => {
    attempts += 1;
    if (render() || attempts > 40) clearInterval(timer);
  }, 250);
  render();
})();