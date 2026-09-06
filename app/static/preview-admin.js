(() => {
  const DEFAULT_TEXT = '嗨，今天聊点轻松的。I really like simple tools that just work. 最近我在用 ChatGPT 和 LangChain 做 AI 小工具，and it feels pretty useful. 好，我们继续吧。';
  const state = { manifest: { text: DEFAULT_TEXT, text_hash: '', kokoro: {}, edge: {}, counts: {} }, jobs: {} };

  function engineLabel(engine) { return engine === 'edge' ? 'Edge' : 'Kokoro'; }
  function selector(engine, suffix) { return document.querySelector(`#${engine}${suffix}`); }
  function editor(engine) { return document.querySelector(`#${engine}PreviewTemplate`); }
  function selectedVoice(engine) { return selector(engine, 'Voice')?.value || ''; }
  function selectedSpeed(engine) { return Number(selector(engine, 'Speed')?.value || 1); }

  function setStatus(engine, text, kind = 'processing') {
    const el = selector(engine, 'PreviewStatus');
    if (!el) return;
    el.textContent = text;
    el.className = `badge ${kind}`;
  }

  function syncEditors(text) {
    ['kokoro', 'edge'].forEach(engine => {
      const el = editor(engine);
      if (el && document.activeElement !== el) el.value = text;
    });
  }

  function entryFor(engine, voice) {
    const value = state.manifest?.[engine]?.[voice];
    if (!value) return null;
    if (typeof value === 'string') return { url: value, stale: false };
    return value;
  }

  function refreshManualPreview(engine) {
    const voice = selectedVoice(engine);
    const entry = entryFor(engine, voice);
    const btn = selector(engine, 'PreviewBtn');
    const audio = selector(engine, 'PreviewAudio');
    const count = state.manifest?.counts?.[engine];
    const countEl = document.querySelector(`#${engine}PreviewCount`);
    if (countEl && count) countEl.textContent = `${count.current}/${count.total} 当前文案 · ${count.ready} 已保存`;

    if (entry?.url) {
      btn.disabled = false;
      btn.dataset.url = entry.url;
      if (entry.stale) setStatus(engine, '旧文案试听', 'processing');
      else setStatus(engine, '已永久保存', 'ok');
    } else {
      btn.disabled = true;
      btn.dataset.url = '';
      setStatus(engine, '未生成', '');
    }

    if (audio && audio.dataset.voice !== voice) {
      audio.pause();
      audio.removeAttribute('src');
      audio.load();
      audio.dataset.voice = voice;
    }
  }

  async function loadManualManifest(quiet = false) {
    if (typeof sessionToken !== 'undefined' && !sessionToken) return;
    try {
      const data = await adminApi('/admin/previews?_=' + Date.now());
      state.manifest = data;
      try { previewManifest = data; } catch (_) {}
      syncEditors(data.text || DEFAULT_TEXT);
      ['kokoro', 'edge'].forEach(refreshManualPreview);
    } catch (err) {
      ['kokoro', 'edge'].forEach(engine => setStatus(engine, '读取失败', 'fail'));
      if (!quiet && typeof toast === 'function') toast(err.message || '固定试听读取失败');
    }
  }

  async function saveTemplate(engine, silent = false) {
    const text = (editor(engine)?.value || '').trim();
    if (!text) throw new Error('试听文案不能为空');
    if (text === state.manifest.text) return state.manifest;
    const data = await adminApi('/admin/previews/text', {
      method: 'PUT',
      body: JSON.stringify({ text })
    });
    state.manifest = data;
    syncEditors(data.text);
    ['kokoro', 'edge'].forEach(refreshManualPreview);
    if (!silent && typeof toast === 'function') toast('试听文案已保存；旧音频保留并标记为旧版本');
    return data;
  }

  async function pollJob(jobId, engine, button) {
    while (true) {
      const job = await adminApi('/admin/previews/jobs/' + encodeURIComponent(jobId));
      state.jobs[engine] = job;
      const done = Number(job.completed || 0);
      const total = Number(job.total || 1);
      const failed = Number(job.failed || 0);
      const current = job.current_voice ? ` · ${job.current_voice}` : '';
      if (job.kind === 'batch') setStatus(engine, `手动生成 ${done}/${total}${failed ? ` · 失败${failed}` : ''}${current}`, 'processing');
      else setStatus(engine, `正在生成${current}`, 'processing');

      if (job.status === 'completed') {
        await loadManualManifest(true);
        if (typeof toast === 'function') toast(job.kind === 'batch' ? `${engineLabel(engine)} 固定试听批量任务完成` : `${engineLabel(engine)} 当前音色试听已永久保存`);
        break;
      }
      if (job.status === 'failed') throw new Error(job.error || '固定试听生成失败');
      if (job.status === 'cancelled') throw new Error('固定试听生成已取消');
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    if (button) button.disabled = false;
  }

  async function generateCurrent(engine) {
    const button = document.querySelector(`#${engine}GeneratePreview`);
    if (button) button.disabled = true;
    try {
      await saveTemplate(engine, true);
      const voice = selectedVoice(engine);
      if (!voice) throw new Error('请先选择音色');
      const job = await adminApi('/admin/previews/generate', {
        method: 'POST',
        body: JSON.stringify({ engine, voice, speed: selectedSpeed(engine) })
      });
      await pollJob(job.id, engine, button);
    } catch (err) {
      setStatus(engine, '生成失败', 'fail');
      if (typeof toast === 'function') toast(err.message || '固定试听生成失败');
      if (button) button.disabled = false;
    }
  }

  async function generateAll(engine) {
    const count = state.manifest?.counts?.[engine];
    const total = count?.total || (engine === 'kokoro' ? 103 : 14);
    if (!confirm(`手动生成/补齐 ${engineLabel(engine)} 的全部 ${total} 个固定试听？\n已是当前文案的音色会自动跳过，生成文件会永久保存在服务器本地。`)) return;
    const button = document.querySelector(`#${engine}GenerateAllPreview`);
    if (button) button.disabled = true;
    try {
      await saveTemplate(engine, true);
      const job = await adminApi('/admin/previews/generate-batch', {
        method: 'POST',
        body: JSON.stringify({ engine, priority_voice: selectedVoice(engine), speed: selectedSpeed(engine) })
      });
      await pollJob(job.id, engine, button);
    } catch (err) {
      setStatus(engine, '批量任务失败', 'fail');
      if (typeof toast === 'function') toast(err.message || '批量固定试听失败');
      if (button) button.disabled = false;
    }
  }

  async function playManualPreview(engine) {
    await loadManualManifest(true);
    const voice = selectedVoice(engine);
    const entry = entryFor(engine, voice);
    if (!entry?.url) {
      if (typeof toast === 'function') toast('这个音色还没有固定试听，请先点“生成当前音色试听”');
      return;
    }
    const audio = selector(engine, 'PreviewAudio');
    audio.src = entry.url + (entry.updated_at ? `?v=${encodeURIComponent(entry.updated_at)}` : '');
    audio.load();
    try { await audio.play(); } catch (_) { if (typeof toast === 'function') toast('请点播放器上的播放键'); }
  }

  function installPanel(engine) {
    const box = document.querySelector(`#${engine} .preview-box`);
    if (!box || box.dataset.manualPreview === '1') return;
    box.dataset.manualPreview = '1';
    const oldText = selector(engine, 'PreviewText');
    if (oldText) oldText.style.display = 'none';

    const controls = document.createElement('div');
    controls.innerHTML = `
      <div class="field" style="margin-top:10px">
        <label>固定试听文案（Kokoro / Edge 共用，可随时修改）</label>
        <textarea id="${engine}PreviewTemplate" style="min-height:112px">${DEFAULT_TEXT}</textarea>
      </div>
      <div class="row" style="margin-bottom:12px">
        <button class="btn small secondary" id="${engine}SavePreviewText">保存试听文案</button>
        <button class="btn small" id="${engine}GeneratePreview">生成 / 更新当前音色试听</button>
        <button class="btn small secondary" id="${engine}GenerateAllPreview">手动补齐全部音色</button>
        <span class="muted" id="${engine}PreviewCount">读取中</span>
      </div>
      <div class="muted" style="margin-bottom:12px">不会再自动后台生成。只有你点击生成时才工作；生成后的试听文件保存在服务器本地，部署和普通音频清理都不会删除。修改文案后，旧试听仍可播放，但会标记为“旧文案试听”。</div>`;
    const player = box.querySelector('.preview-player');
    box.insertBefore(controls, player || null);

    document.querySelector(`#${engine}SavePreviewText`).onclick = () => saveTemplate(engine).catch(err => toast(err.message));
    document.querySelector(`#${engine}GeneratePreview`).onclick = () => generateCurrent(engine);
    document.querySelector(`#${engine}GenerateAllPreview`).onclick = () => generateAll(engine);
    setStatus(engine, '未生成', '');
  }

  ['kokoro', 'edge'].forEach(installPanel);

  // Replace the old automatic-background-preview behavior without rewriting the
  // whole console. Existing page navigation and voice-change handlers resolve
  // these function names dynamically, so they now use the manual persistent mode.
  try { loadPreviewManifest = loadManualManifest; } catch (_) {}
  try { refreshPreview = refreshManualPreview; } catch (_) {}
  try { playPreview = playManualPreview; } catch (_) {}

  const kokoroVoice = selector('kokoro', 'Voice');
  const edgeVoice = selector('edge', 'Voice');
  if (kokoroVoice) kokoroVoice.onchange = () => refreshManualPreview('kokoro');
  if (edgeVoice) edgeVoice.onchange = () => refreshManualPreview('edge');
  const kokoroPlay = selector('kokoro', 'PreviewBtn');
  const edgePlay = selector('edge', 'PreviewBtn');
  if (kokoroPlay) kokoroPlay.onclick = () => playManualPreview('kokoro');
  if (edgePlay) edgePlay.onclick = () => playManualPreview('edge');

  if (typeof sessionToken !== 'undefined' && sessionToken) loadManualManifest(true);
})();
