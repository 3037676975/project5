(() => {
  'use strict';

  const EDGE_DEFAULT_TEXT = '欢迎来到 AI 技术分享频道。这里使用 Edge TTS 测试中文、LangChain、RAG、Agent、MCP 和 API 的语音效果。';
  const KOKORO_MODEL = 'Kokoro-82M-v1.1-zh';
  const EDGE_MODEL = 'Microsoft Edge Online TTS';
  const EDGE_DEFAULT_VOICE = 'zh-CN-XiaoxiaoNeural';

  const $id = id => document.getElementById(id);
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const esc = value => String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');

  const engineLabel = engine => engine === 'edge' ? 'Edge 在线 TTS' : 'Kokoro 本地 CPU';
  const engineBadge = engine => engine === 'edge'
    ? '<span class="badge processing">Edge · MP3</span>'
    : '<span class="badge ok">Kokoro · WAV</span>';

  // The legacy generation page is now intentionally Kokoro-only. Edge has its own
  // first-class page instead of a hidden selector injected into the same form.
  window.project5CurrentEngine = () => 'kokoro';

  function genderText(v) {
    if (v?.gender === 'female' || String(v?.id || '').startsWith('zf_')) return '女声';
    if (v?.gender === 'male' || String(v?.id || '').startsWith('zm_')) return '男声';
    return '中文音色';
  }

  function localeText(v) {
    const locale = String(v?.locale || 'zh-CN');
    if (locale.startsWith('zh-HK')) return '粤语';
    if (locale.startsWith('zh-TW')) return '台湾中文';
    if (locale.includes('liaoning')) return '辽宁';
    if (locale.includes('shaanxi')) return '陕西';
    return '普通话';
  }

  function rewriteBrandAndDashboard() {
    const brandSmall = document.querySelector('.brand small');
    if (brandSmall) brandSmall.textContent = 'Kokoro + Edge 双引擎 TTS API';
    const foot = document.querySelector('.side-foot');
    if (foot) foot.textContent = 'Kokoro 本地 · Edge 在线';
    document.title = 'Project5 · 双引擎 TTS';

    const modelPanel = Array.from(document.querySelectorAll('#dashboard .panel')).find(panel =>
      panel.querySelector('h2')?.textContent?.includes('模型状态')
    );
    if (modelPanel) {
      modelPanel.innerHTML = `
        <h2>双引擎状态</h2>
        <div class="result" style="margin-top:0">
          <div class="section-title" style="margin:0"><div><b>${KOKORO_MODEL}</b><div class="muted">本地 CPU · WAV · 支持中英混读</div></div><span class="badge" id="kokoroDashboardBadge">检测中</span></div>
        </div>
        <div class="result">
          <div class="section-title" style="margin:0"><div><b>${EDGE_MODEL}</b><div class="muted">在线服务 · MP3 · 中文音色丰富</div></div><span class="badge ok">在线可用</span></div>
        </div>
        <div style="display:none"><b id="modelLoaded">-</b></div>`;
    }
  }

  async function refreshDualStatus() {
    try {
      const r = await fetch(`/health?_=${Date.now()}`, { cache: 'no-store' });
      if (!r.ok) return;
      const data = await r.json();
      const badge = $id('kokoroDashboardBadge');
      if (badge) {
        const ready = Boolean(data?.engines?.kokoro?.ready ?? data?.model_loaded);
        badge.textContent = ready ? '本地模型已就绪' : '本地模型加载中';
        badge.className = `badge ${ready ? 'ok' : 'processing'}`;
      }
    } catch (_) {}
  }

  function prepareKokoroPage() {
    const nav = document.querySelector('.nav button[data-page="generate"]');
    if (nav) nav.innerHTML = '🎙️ <span class="label">Kokoro 本地试听</span>';

    const page = $id('generate');
    if (!page) return;
    const firstPanel = page.querySelector('.panel');
    if (firstPanel) {
      const title = firstPanel.querySelector('.section-title h2');
      const subtitle = firstPanel.querySelector('.section-title .muted');
      if (title) title.textContent = 'Kokoro 本地生成 / 试听';
      if (subtitle) subtitle.textContent = '只使用 Kokoro-82M-v1.1-zh 本地 CPU 引擎，输出 WAV；适合离线与隐私场景。';
      const modelInput = Array.from(firstPanel.querySelectorAll('input[disabled]')).find(input => String(input.value).includes('Kokoro'));
      if (modelInput) modelInput.value = KOKORO_MODEL;
    }

    const allVoicePanel = page.querySelectorAll('.panel')[1];
    if (allVoicePanel) {
      const h2 = allVoicePanel.querySelector('h2');
      const sub = allVoicePanel.querySelector('.section-title .muted');
      if (h2) h2.textContent = 'Kokoro 中文音色试听';
      if (sub) sub.textContent = '这里仅显示 Kokoro 中文音色，不再混入 Edge 音色。';
    }
  }

  async function loadKokoroVoices() {
    const response = await fetch(`/v1/voices?engine=kokoro&_=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`Kokoro 音色加载失败 HTTP ${response.status}`);
    const data = await response.json();
    const list = data.voices || [];

    // Keep legacy globals in sync because its batch-preview function still uses them.
    try {
      voices = list;
      visibleVoices = list;
    } catch (_) {}

    const select = $id('ttsVoice');
    if (select) {
      const remembered = localStorage.getItem('p5_voice_kokoro');
      const preferred = list.some(v => v.id === remembered) ? remembered : (list[0]?.id || 'zf_001');
      select.innerHTML = list.map(v => `<option value="${esc(v.id)}">${esc(v.label)} (${esc(v.id)})</option>`).join('');
      if (preferred) select.value = preferred;
      select.onchange = () => localStorage.setItem('p5_voice_kokoro', select.value);
    }
    renderKokoroVoices(list);
  }

  function renderKokoroVoices(sourceList = null) {
    let list = sourceList;
    if (!list) {
      try { list = voices || []; } catch (_) { list = []; }
    }
    const q = ($id('voiceSearch')?.value || '').trim().toLowerCase();
    const visible = list.filter(v => !q || `${v.id} ${v.label} ${genderText(v)}`.toLowerCase().includes(q));
    try { visibleVoices = visible; } catch (_) {}
    if ($id('voiceCount')) $id('voiceCount').textContent = `${visible.length} 个 Kokoro 音色`;
    if (!$id('voiceGrid')) return;
    $id('voiceGrid').innerHTML = visible.length
      ? visible.map(v => `<div class="voice-card" data-voice="${esc(v.id)}">
          <strong>${esc(v.label)}</strong>
          <div class="voice-meta"><span class="mono">${esc(v.id)}</span><span>${genderText(v)}</span></div>
          <button class="btn small secondary p5-kokoro-preview" data-voice="${esc(v.id)}">▶ Kokoro 试听</button>
        </div>`).join('')
      : '<div class="empty">没有找到对应 Kokoro 音色</div>';

    document.querySelectorAll('.p5-kokoro-preview').forEach(button => {
      button.onclick = async () => {
        const voice = button.dataset.voice;
        if ($id('ttsVoice')) $id('ttsVoice').value = voice;
        localStorage.setItem('p5_voice_kokoro', voice);
        document.querySelectorAll('#generate .voice-card').forEach(card => card.classList.toggle('selected', card.dataset.voice === voice));
        if (typeof window.synthesize === 'function') await window.synthesize(voice, button);
      };
    });
  }

  function installKokoroOverrides() {
    window.loadVoices = loadKokoroVoices;
    window.renderVoices = () => renderKokoroVoices();
    window.previewVoice = async (id, button) => {
      if ($id('ttsVoice')) $id('ttsVoice').value = id;
      localStorage.setItem('p5_voice_kokoro', id);
      if (typeof window.synthesize === 'function') return window.synthesize(id, button);
      return null;
    };
    try {
      loadVoices = window.loadVoices;
      renderVoices = window.renderVoices;
      previewVoice = window.previewVoice;
    } catch (_) {}

    if ($id('voiceSearch')) $id('voiceSearch').oninput = () => renderKokoroVoices();
    if ($id('clearVoiceSearch')) $id('clearVoiceSearch').onclick = () => {
      $id('voiceSearch').value = '';
      renderKokoroVoices();
    };
  }

  function insertEdgeNavigationAndPage() {
    if ($id('edgeGenerate')) return;
    const kokoroNav = document.querySelector('.nav button[data-page="generate"]');
    if (!kokoroNav) return;

    const edgeNav = document.createElement('button');
    edgeNav.dataset.page = 'edgeGenerate';
    edgeNav.innerHTML = '⚡ <span class="label">Edge 在线试听</span>';
    kokoroNav.insertAdjacentElement('afterend', edgeNav);

    const kokoroPage = $id('generate');
    const edgePage = document.createElement('section');
    edgePage.id = 'edgeGenerate';
    edgePage.className = 'page';
    edgePage.innerHTML = `
      <div class="panel">
        <div class="section-title">
          <div><h2 style="margin-bottom:5px">Edge TTS 在线生成 / 试听</h2><div class="muted">独立于 Kokoro。调用 Edge 在线语音服务，通常生成更快，输出 MP3，需要服务器可以访问外网。</div></div>
          <span class="badge ok" id="edgeReadyBadge">在线引擎可用</span>
        </div>
        <div class="field"><label>Edge 试听文本</label><textarea id="edgeText" placeholder="输入中文或中英混合文本……"></textarea></div>
        <div class="form-grid">
          <div class="field"><label>Edge 中文音色</label><select id="edgeVoice"></select><div class="muted" style="margin-top:7px">普通话、地方口音、台湾中文和粤语音色分开列出。</div></div>
          <div class="field"><label>语速</label><div class="speed-wrap"><input id="edgeSpeedRange" type="range" min="0.5" max="2" step="0.1" value="1.0"><input id="edgeSpeed" class="input" type="number" min="0.5" max="2" step="0.1" value="1.0"></div></div>
          <div class="field"><label>引擎</label><input class="input" value="${EDGE_MODEL}" disabled></div>
        </div>
        <div class="row"><button class="btn" id="edgeGenerateBtn">⚡ Edge 生成并试听</button><button class="btn secondary" id="edgePreviewBtn">▶ 试听当前 Edge 音色</button></div>
        <div class="result" id="edgeProgress" style="display:none"></div>
        <div id="edgeGenerateResult"></div>
        <div class="tip">Edge TTS 不下载本地模型包，因此不占用 Kokoro 的 ONNX 模型内存；网络异常时会自动重试，失败不会影响 Kokoro 本地生成。</div>
      </div>
      <div class="panel">
        <div class="section-title"><div><h2 style="margin-bottom:5px">Edge 中文音色试听</h2><div class="muted">这里仅显示 Edge 中文音色，与 Kokoro 音色完全分开。</div></div><span class="badge" id="edgeVoiceCount">0 个音色</span></div>
        <div class="voice-toolbar"><input id="edgeVoiceSearch" class="input" placeholder="搜索：晓晓、云扬、普通话、粤语、台湾"><button class="btn secondary" id="edgeVoiceClear">清空</button></div>
        <div class="voice-grid" id="edgeVoiceGrid"></div>
      </div>`;
    kokoroPage.insertAdjacentElement('afterend', edgePage);

    edgeNav.onclick = () => activateEdgePage();
    if ($id('edgeText')) $id('edgeText').value = localStorage.getItem('p5_edge_text') || EDGE_DEFAULT_TEXT;
    $id('edgeText').addEventListener('change', () => localStorage.setItem('p5_edge_text', $id('edgeText').value));
    $id('edgeSpeedRange').oninput = () => { $id('edgeSpeed').value = $id('edgeSpeedRange').value; };
    $id('edgeSpeed').oninput = () => { $id('edgeSpeedRange').value = $id('edgeSpeed').value; };
    $id('edgeGenerateBtn').onclick = () => generateEdge($id('edgeVoice').value, $id('edgeGenerateBtn'));
    $id('edgePreviewBtn').onclick = () => generateEdge($id('edgeVoice').value, $id('edgePreviewBtn'));
    $id('edgeVoiceSearch').oninput = renderEdgeVoices;
    $id('edgeVoiceClear').onclick = () => { $id('edgeVoiceSearch').value = ''; renderEdgeVoices(); };
  }

  function activateEdgePage() {
    document.querySelectorAll('.page').forEach(page => page.classList.remove('active'));
    document.querySelectorAll('.nav button').forEach(button => button.classList.toggle('active', button.dataset.page === 'edgeGenerate'));
    $id('edgeGenerate')?.classList.add('active');
    if ($id('pageTitle')) $id('pageTitle').textContent = 'Edge TTS 在线试听';
    loadEdgeVoices().catch(error => toast(error.message));
  }

  let edgeVoices = [];

  async function loadEdgeVoices() {
    const response = await fetch(`/v1/voices?engine=edge&_=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`Edge 音色加载失败 HTTP ${response.status}`);
    const data = await response.json();
    edgeVoices = data.voices || [];
    const select = $id('edgeVoice');
    if (select) {
      const remembered = localStorage.getItem('p5_voice_edge');
      const preferred = edgeVoices.some(v => v.id === remembered)
        ? remembered
        : (edgeVoices.some(v => v.id === EDGE_DEFAULT_VOICE) ? EDGE_DEFAULT_VOICE : edgeVoices[0]?.id);
      select.innerHTML = edgeVoices.map(v => `<option value="${esc(v.id)}">${esc(v.label)} (${esc(v.id)})</option>`).join('');
      if (preferred) select.value = preferred;
      select.onchange = () => localStorage.setItem('p5_voice_edge', select.value);
    }
    renderEdgeVoices();
  }

  function renderEdgeVoices() {
    const q = ($id('edgeVoiceSearch')?.value || '').trim().toLowerCase();
    const visible = edgeVoices.filter(v => !q || `${v.id} ${v.label} ${genderText(v)} ${localeText(v)}`.toLowerCase().includes(q));
    if ($id('edgeVoiceCount')) $id('edgeVoiceCount').textContent = `${visible.length} 个 Edge 音色`;
    if (!$id('edgeVoiceGrid')) return;
    $id('edgeVoiceGrid').innerHTML = visible.length
      ? visible.map(v => `<div class="voice-card" data-edge-voice="${esc(v.id)}">
          <strong>${esc(v.label)}</strong>
          <div class="voice-meta"><span class="mono">${esc(v.id)}</span><span>${localeText(v)} · ${genderText(v)}</span></div>
          <button class="btn small secondary p5-edge-preview" data-voice="${esc(v.id)}">▶ Edge 试听</button>
        </div>`).join('')
      : '<div class="empty">没有找到对应 Edge 音色</div>';
    document.querySelectorAll('.p5-edge-preview').forEach(button => {
      button.onclick = async () => {
        const voice = button.dataset.voice;
        if ($id('edgeVoice')) $id('edgeVoice').value = voice;
        localStorage.setItem('p5_voice_edge', voice);
        document.querySelectorAll('#edgeGenerate .voice-card').forEach(card => card.classList.toggle('selected', card.dataset.edgeVoice === voice));
        await generateEdge(voice, button);
      };
    });
  }

  function edgeSpeed() {
    let n = Number($id('edgeSpeed')?.value || 1);
    if (n < 0.5) n = 0.5;
    if (n > 2) n = 2;
    return Number(n.toFixed(1));
  }

  async function pollTask(taskId, progressTarget = null) {
    const started = Date.now();
    const deadline = started + 15 * 60 * 1000;
    while (Date.now() < deadline) {
      const task = await adminApi(`/admin/tasks/${encodeURIComponent(taskId)}`);
      if (task.status === 'completed') return task;
      if (task.status === 'failed') throw new Error(task.error || 'TTS 生成失败');
      if (progressTarget) {
        const seconds = Math.round((Date.now() - started) / 1000);
        progressTarget.style.display = 'block';
        progressTarget.innerHTML = `<b>${task.status === 'queued' ? 'Edge 任务排队中' : 'Edge 在线生成中'}</b><div class="muted" style="margin-top:6px">任务 ${esc(taskId)} · 已等待 ${seconds} 秒</div>`;
      }
      await sleep(750);
    }
    throw new Error('Edge 任务超过 15 分钟仍未完成');
  }

  function renderEdgeResult(task) {
    const target = $id('edgeGenerateResult');
    if (!target) return;
    target.innerHTML = `<div class="audio-result">
      <div class="audio-head"><div><b>Edge 在线 TTS · 生成成功</b><div class="muted">${esc(task.voice)} · ${esc(task.speed)}x · ${task.elapsed_ms ? (task.elapsed_ms / 1000).toFixed(2) + ' 秒' : '-'}</div></div>${engineBadge('edge')}</div>
      <audio controls autoplay src="${esc(task.audio_url)}"></audio>
      <div class="audio-actions"><a class="btn small" href="${esc(task.audio_url)}" download>下载 MP3</a><button class="btn small secondary" id="edgeGoFiles">查看 Edge 音频文件</button><button class="btn small secondary" onclick="showPage('tasks')">去生成任务</button></div>
      <div class="muted" style="margin-top:8px">任务 ${esc(task.id)} · ${esc(task.audio_filename || '')}</div>
    </div>`;
    target.querySelector('audio')?.play().catch(() => {});
    $id('edgeGoFiles')?.addEventListener('click', () => {
      showPage('files');
      setTimeout(() => $id('edgeFilePanel')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 50);
    });
  }

  async function generateEdge(voice, button) {
    const text = ($id('edgeText')?.value || '').trim();
    if (!text) return toast('请先输入 Edge 试听文本');
    const spd = edgeSpeed();
    const old = button?.textContent || '';
    if (button) { button.disabled = true; button.textContent = 'Edge 生成中…'; }
    const progress = $id('edgeProgress');
    if (progress) {
      progress.style.display = 'block';
      progress.innerHTML = `<b>正在提交 Edge 在线任务</b><div class="muted" style="margin-top:6px">${esc(voice)} · ${spd}x</div>`;
    }
    $id('edgeGenerateResult').innerHTML = '';
    try {
      const accepted = await adminApi('/admin/speech', {
        method: 'POST',
        body: JSON.stringify({ input: text, engine: 'edge', voice, speed: spd })
      });
      if (!accepted?.id) throw new Error('服务器没有返回 Edge 任务 ID');
      const task = await pollTask(accepted.id, progress);
      if (progress) {
        progress.className = 'result';
        progress.innerHTML = `<b style="color:#15803d">Edge 生成完成</b><div class="muted" style="margin-top:6px">真实耗时 ${task.elapsed_ms ? (task.elapsed_ms / 1000).toFixed(2) + ' 秒' : '-'}</div>`;
      }
      renderEdgeResult(task);
      toast('Edge TTS 生成成功');
      if (typeof loadDashboard === 'function') loadDashboard();
      return task;
    } catch (error) {
      if (progress) progress.innerHTML = `<b style="color:#b91c1c">Edge 生成失败</b><div style="margin-top:6px;color:#b91c1c">${esc(error.message || error)}</div><div class="muted" style="margin-top:6px">你仍然可以切回 Kokoro 本地试听，不受影响。</div>`;
      toast('Edge TTS 生成失败');
      return null;
    } finally {
      if (button) { button.disabled = false; button.textContent = old; }
    }
  }

  function fileCard(task) {
    const engine = task.engine === 'edge' || String(task.audio_filename || '').endsWith('.mp3') ? 'edge' : 'kokoro';
    return `<div class="file">
      <div class="section-title" style="margin-bottom:8px"><h4 style="margin:0">🎵 ${esc(task.audio_filename)}</h4>${engineBadge(engine)}</div>
      <p class="muted">${esc(task.voice)} · ${esc(task.speed)}x · ${task.duration || 0}s · ${Number(task.file_size || 0).toLocaleString()} bytes</p>
      <audio controls src="${esc(task.audio_url)}"></audio>
      <div class="row" style="margin-top:10px"><a class="btn small" href="${esc(task.audio_url)}" download>下载${engine === 'edge' ? ' MP3' : ' WAV'}</a><button class="btn small danger" data-delete-task="${esc(task.id)}">删除</button></div>
    </div>`;
  }

  function prepareFilesPage() {
    const section = $id('files');
    if (!section) return;
    section.innerHTML = `
      <div class="grid2" style="align-items:start">
        <div class="panel" id="kokoroFilePanel">
          <div class="section-title"><div><h2 style="margin-bottom:5px">Kokoro 音频文件</h2><div class="muted">本地 CPU 生成 · WAV 文件</div></div><span class="badge ok" id="kokoroFileCount">0 个</span></div>
          <div id="kokoroFileList" class="file-list" style="grid-template-columns:1fr"></div>
        </div>
        <div class="panel" id="edgeFilePanel">
          <div class="section-title"><div><h2 style="margin-bottom:5px">Edge 音频文件</h2><div class="muted">在线 TTS 生成 · MP3 文件</div></div><span class="badge processing" id="edgeFileCount">0 个</span></div>
          <div id="edgeFileList" class="file-list" style="grid-template-columns:1fr"></div>
        </div>
      </div>
      <div class="panel"><div class="row"><button class="btn secondary" id="refreshDualFiles">刷新全部音频</button><span class="muted">两个引擎的文件完全分开展示，删除时只删除对应任务和音频。</span></div></div>`;
    $id('refreshDualFiles').onclick = () => loadDualFiles();
  }

  async function loadDualFiles() {
    const data = await adminApi('/admin/tasks?limit=500&status=completed');
    const items = (data.items || []).filter(item => item.audio_url);
    const edge = items.filter(item => item.engine === 'edge' || String(item.audio_filename || '').endsWith('.mp3'));
    const kokoro = items.filter(item => !(item.engine === 'edge' || String(item.audio_filename || '').endsWith('.mp3')));
    if ($id('kokoroFileCount')) $id('kokoroFileCount').textContent = `${kokoro.length} 个`;
    if ($id('edgeFileCount')) $id('edgeFileCount').textContent = `${edge.length} 个`;
    if ($id('kokoroFileList')) $id('kokoroFileList').innerHTML = kokoro.length ? kokoro.map(fileCard).join('') : '<div class="empty">暂无 Kokoro WAV 文件</div>';
    if ($id('edgeFileList')) $id('edgeFileList').innerHTML = edge.length ? edge.map(fileCard).join('') : '<div class="empty">暂无 Edge MP3 文件</div>';
    document.querySelectorAll('[data-delete-task]').forEach(button => {
      button.onclick = async () => {
        if (!confirm('删除这个任务以及对应音频文件？')) return;
        await adminApi(`/admin/tasks/${encodeURIComponent(button.dataset.deleteTask)}`, { method: 'DELETE' });
        toast('已删除');
        await loadDualFiles();
        if (typeof loadTasks === 'function') loadTasks();
      };
    });
  }

  function installFilesOverride() {
    window.loadFiles = loadDualFiles;
    try { loadFiles = window.loadFiles; } catch (_) {}
  }

  function prepareDocsPage() {
    const section = $id('docs');
    if (!section) return;
    section.innerHTML = `<div class="panel doc">
      <div class="section-title"><div><h2 style="margin-bottom:5px">Project5 双引擎 API 文档</h2><div class="muted">同一个 API，通过 <span class="mono">engine</span> 选择 Kokoro 或 Edge。</div></div><span class="badge ok">v2 · 双引擎</span></div>

      <h3>1. 两个引擎的区别</h3>
      <table><tr><th>engine</th><th>引擎</th><th>输出</th><th>特点</th><th>默认音色</th></tr>
        <tr><td class="mono">kokoro</td><td>Kokoro-82M-v1.1-zh</td><td>WAV</td><td>本地 CPU、可离线、中英混读</td><td class="mono">zf_001</td></tr>
        <tr><td class="mono">edge</td><td>Microsoft Edge Online TTS</td><td>MP3</td><td>在线、通常更快、中文音色丰富</td><td class="mono">zh-CN-XiaoxiaoNeural</td></tr>
      </table>

      <h3>2. 请求参数</h3>
      <table><tr><th>字段</th><th>类型</th><th>必填</th><th>说明</th></tr>
        <tr><td class="mono">input</td><td>string</td><td>是</td><td>要转换的文本</td></tr>
        <tr><td class="mono">engine</td><td>string</td><td>建议填写</td><td><span class="mono">kokoro</span> 或 <span class="mono">edge</span>；不填默认 Kokoro</td></tr>
        <tr><td class="mono">voice</td><td>string</td><td>否</td><td>音色 ID；不填使用该引擎默认音色</td></tr>
        <tr><td class="mono">speed</td><td>number</td><td>否</td><td>0.5 ~ 2.0，默认 1.0</td></tr>
      </table>

      <h3>3. Kokoro 本地 TTS · cURL</h3><div class="code" id="kokoroCurlCode"></div>
      <h3>4. Edge 在线 TTS · cURL</h3><div class="code" id="edgeCurlCode"></div>
      <h3>5. Python · 可切换两个引擎</h3><div class="code" id="dualPythonCode"></div>
      <h3>6. JavaScript · Edge 示例</h3><div class="code" id="edgeJsCode"></div>

      <h3>7. 查询中文音色</h3>
      <div class="code" id="voicesCode"></div>
      <p class="muted">Kokoro 和 Edge 的音色列表已经分开。不要把 Edge 音色 ID 传给 Kokoro。</p>

      <h3>8. 异步任务流程</h3>
      <div class="tip">POST /v1/audio/speech 返回 HTTP 202 和任务 ID。随后轮询 task_url；当 status=completed 时读取 audio_url。Kokoro 返回 WAV，Edge 返回 MP3。</div>
      <div class="code" id="taskCode"></div>

      <h3>9. 公开接口</h3>
      <table><tr><th>方法</th><th>地址</th><th>作用</th></tr>
        <tr><td>POST</td><td class="mono">/v1/audio/speech</td><td>创建 Kokoro / Edge TTS 任务</td></tr>
        <tr><td>GET</td><td class="mono">/v1/voices?engine=kokoro</td><td>查看 Kokoro 中文音色</td></tr>
        <tr><td>GET</td><td class="mono">/v1/voices?engine=edge</td><td>查看 Edge 中文音色</td></tr>
        <tr><td>GET</td><td class="mono">/v1/tasks/{id}</td><td>查询 API 任务状态与音频地址</td></tr>
        <tr><td>GET</td><td class="mono">/health</td><td>查看两个引擎的运行状态</td></tr>
      </table>
    </div>`;
  }

  function renderDocs() {
    const base = location.origin;
    const key = 'sk-kokoro-xxxxxxxx';
    if ($id('kokoroCurlCode')) $id('kokoroCurlCode').textContent = `curl ${base}/v1/audio/speech \\\n  -H "Authorization: Bearer ${key}" \\\n  -H "Content-Type: application/json" \\\n  -d '{"input":"今天学习 LangChain、RAG、Agent、MCP 和 API。","engine":"kokoro","voice":"zf_001","speed":1.0}'`;
    if ($id('edgeCurlCode')) $id('edgeCurlCode').textContent = `curl ${base}/v1/audio/speech \\\n  -H "Authorization: Bearer ${key}" \\\n  -H "Content-Type: application/json" \\\n  -d '{"input":"今天学习 LangChain、RAG、Agent、MCP 和 API。","engine":"edge","voice":"zh-CN-XiaoxiaoNeural","speed":1.0}'`;
    if ($id('dualPythonCode')) $id('dualPythonCode').textContent = `import time\nimport requests\n\nBASE = "${base}"\nAPI_KEY = "${key}"\n\ndef tts(engine, voice, text):\n    r = requests.post(\n        f"{BASE}/v1/audio/speech",\n        headers={"Authorization": f"Bearer {API_KEY}"},\n        json={"input": text, "engine": engine, "voice": voice, "speed": 1.0},\n    )\n    r.raise_for_status()\n    task = r.json()\n    while True:\n        state = requests.get(task["task_url"], headers={"Authorization": f"Bearer {API_KEY}"})\n        state.raise_for_status()\n        result = state.json()\n        if result["status"] == "completed":\n            return result["audio_url"]\n        if result["status"] == "failed":\n            raise RuntimeError(result.get("error"))\n        time.sleep(1)\n\nprint(tts("kokoro", "zf_001", "你好，LangChain 和 RAG。"))\nprint(tts("edge", "zh-CN-XiaoxiaoNeural", "你好，LangChain 和 RAG。"))`;
    if ($id('edgeJsCode')) $id('edgeJsCode').textContent = `const accepted = await fetch("${base}/v1/audio/speech", {\n  method: "POST",\n  headers: {\n    "Authorization": "Bearer ${key}",\n    "Content-Type": "application/json"\n  },\n  body: JSON.stringify({\n    input: "欢迎来到 AI 技术分享频道",\n    engine: "edge",\n    voice: "zh-CN-XiaoxiaoNeural",\n    speed: 1.0\n  })\n});\nconsole.log(await accepted.json());`;
    if ($id('voicesCode')) $id('voicesCode').textContent = `GET ${base}/v1/voices?engine=kokoro\nGET ${base}/v1/voices?engine=edge`;
    if ($id('taskCode')) $id('taskCode').textContent = `POST /v1/audio/speech  ->  202 { id, engine, task_url }\nGET  /v1/tasks/{id}    ->  { status: "queued" | "processing" | "completed" | "failed" }\ncompleted              ->  { audio_url, audio_filename, duration, elapsed_ms }`;
  }

  function installDocsOverride() {
    window.docs = renderDocs;
    try { docs = window.docs; } catch (_) {}
  }

  function installTaskTableOverride() {
    const enhanced = items => {
      if (!items?.length) return '<div class="empty">暂无记录</div>';
      return `<table><tr><th>时间</th><th>任务</th><th>引擎</th><th>来源</th><th>音色</th><th>字数</th><th>耗时</th><th>状态</th></tr>${items.map(item => {
        const engine = item.engine === 'edge' ? 'edge' : 'kokoro';
        const err = item.status === 'failed' && item.error ? `<div style="color:#b91c1c;margin-top:5px;max-width:360px">${esc(item.error)}</div>` : '';
        return `<tr><td>${esc((item.created_at || '').replace('T', ' '))}</td><td class="mono">${esc(item.id)}</td><td>${engineBadge(engine)}</td><td>${esc(item.source_name || '-')}<div class="muted">${esc(item.source_ip || '')}</div></td><td>${esc(item.voice)} · ${esc(item.speed)}x</td><td>${Number(item.chars || 0).toLocaleString()}</td><td>${item.elapsed_ms ? Number(item.elapsed_ms).toLocaleString() + ' ms' : '-'}</td><td>${typeof statusBadge === 'function' ? statusBadge(item.status) : esc(item.status)}${err}</td></tr>`;
      }).join('')}</table>`;
    };
    window.taskTable = enhanced;
    try { taskTable = enhanced; } catch (_) {}
  }

  function patchShowPage() {
    const original = window.showPage;
    if (typeof original !== 'function') return;
    window.showPage = async name => {
      if (name === 'edgeGenerate') return activateEdgePage();
      const result = await original(name);
      if (name === 'files') await loadDualFiles().catch(error => toast(error.message));
      if (name === 'docs') renderDocs();
      if (name === 'generate') await loadKokoroVoices().catch(error => toast(error.message));
      return result;
    };
    try { showPage = window.showPage; } catch (_) {}
  }

  function init() {
    rewriteBrandAndDashboard();
    prepareKokoroPage();
    installKokoroOverrides();
    insertEdgeNavigationAndPage();
    prepareFilesPage();
    installFilesOverride();
    prepareDocsPage();
    installDocsOverride();
    installTaskTableOverride();
    patchShowPage();
    renderDocs();

    loadKokoroVoices().catch(error => console.warn('[Project5] Kokoro voices:', error));
    loadEdgeVoices().catch(error => console.warn('[Project5] Edge voices:', error));
    refreshDualStatus();
    setInterval(refreshDualStatus, 5000);

    // The legacy inline boot may finish after this overlay. Re-apply the separated
    // Kokoro list once more to defeat that race and ensure Edge never appears there.
    setTimeout(() => loadKokoroVoices().catch(() => {}), 1400);
    console.info('[Project5] separated Kokoro/Edge console v2 loaded');
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, { once: true });
  else init();
})();
