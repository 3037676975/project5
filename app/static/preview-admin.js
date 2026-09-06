(() => {
  const DEFAULT_TEXT = '嗨，今天聊点轻松的。I really like simple tools that just work. 最近我在用 ChatGPT 和 LangChain 做 AI 小工具，and it feels pretty useful. 好，我们继续吧。';
  const PREVIEW_SPEED = 1.0;
  const state = {
    manifest: { text: DEFAULT_TEXT, text_hash: '', kokoro: {}, edge: {}, counts: {} },
    jobs: {},
    dirty: { kokoro: false, edge: false },
    notes: { kokoro: {}, edge: {} }
  };

  function engineLabel(engine) { return engine === 'edge' ? 'Edge' : 'Kokoro'; }
  function selector(engine, suffix) { return document.querySelector(`#${engine}${suffix}`); }
  function editor(engine) { return document.querySelector(`#${engine}PreviewTemplate`); }
  function selectedVoice(engine) { return selector(engine, 'Voice')?.value || ''; }
  function noteInput(engine) { return document.querySelector(`#${engine}VoiceNote`); }
  function noteStatus(engine) { return document.querySelector(`#${engine}VoiceNoteStatus`); }

  function setStatus(engine, text, kind = 'processing') {
    const el = selector(engine, 'PreviewStatus');
    if (!el) return;
    el.textContent = text;
    el.className = `badge ${kind}`;
  }

  function syncEditors(text, force = false) {
    ['kokoro', 'edge'].forEach(engine => {
      const el = editor(engine);
      if (el && (force || !state.dirty[engine])) el.value = text;
    });
  }

  function entryFor(engine, voice) {
    const value = state.manifest?.[engine]?.[voice];
    if (!value) return null;
    if (typeof value === 'string') return { url: value, stale: false };
    return value;
  }

  function noteFor(engine, voice) {
    return state.notes?.[engine]?.[voice]?.note || '';
  }

  function decorateVoiceOptions(engine) {
    const select = selector(engine, 'Voice');
    if (!select) return;
    [...select.options].forEach(option => {
      if (!option.dataset.baseLabel) option.dataset.baseLabel = option.textContent || option.value;
      const note = noteFor(engine, option.value).trim();
      const short = note.length > 24 ? note.slice(0, 24) + '…' : note;
      option.textContent = note ? `${option.dataset.baseLabel} · 📝 ${short}` : option.dataset.baseLabel;
    });
  }

  function refreshVoiceNote(engine) {
    const input = noteInput(engine);
    const statusEl = noteStatus(engine);
    if (!input || !statusEl) return;
    const voice = selectedVoice(engine);
    const note = noteFor(engine, voice);
    input.value = note;
    input.dataset.voice = voice;
    statusEl.textContent = note ? '已保存' : '未备注';
  }

  async function loadVoiceNotes(quiet = false) {
    if (typeof sessionToken !== 'undefined' && !sessionToken) return;
    try {
      const data = await adminApi('/admin/voice-notes?_=' + Date.now());
      state.notes = data.notes || { kokoro: {}, edge: {} };
      ['kokoro', 'edge'].forEach(engine => {
        decorateVoiceOptions(engine);
        refreshVoiceNote(engine);
      });
    } catch (err) {
      ['kokoro', 'edge'].forEach(engine => {
        const el = noteStatus(engine);
        if (el) el.textContent = '备注读取失败';
      });
      if (!quiet && typeof toast === 'function') toast(err.message || '音色备注读取失败');
    }
  }

  async function saveVoiceNote(engine) {
    const voice = selectedVoice(engine);
    const input = noteInput(engine);
    if (!voice || !input) throw new Error('请先选择音色');
    const note = input.value.trim();
    const data = await adminApi('/admin/voice-notes', {
      method: 'PUT',
      body: JSON.stringify({ engine, voice, note })
    });
    state.notes[engine] = data.notes?.[engine] || {};
    decorateVoiceOptions(engine);
    refreshVoiceNote(engine);
    if (typeof toast === 'function') toast(note ? '这个音色的备注已永久保存' : '这个音色的备注已清空');
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
    if (text === state.manifest.text) {
      state.dirty.kokoro = false;
      state.dirty.edge = false;
      syncEditors(text, true);
      return state.manifest;
    }
    const data = await adminApi('/admin/previews/text', {
      method: 'PUT',
      body: JSON.stringify({ text })
    });
    state.manifest = data;
    state.dirty.kokoro = false;
    state.dirty.edge = false;
    syncEditors(data.text, true);
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
        body: JSON.stringify({ engine, voice, speed: PREVIEW_SPEED })
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
    if (!confirm(`手动生成/补齐 ${engineLabel(engine)} 的全部 ${total} 个固定试听？\n固定试听统一使用 1.0x 语速；已是当前文案的音色会自动跳过，生成文件会永久保存在服务器本地。`)) return;
    const button = document.querySelector(`#${engine}GenerateAllPreview`);
    if (button) button.disabled = true;
    try {
      await saveTemplate(engine, true);
      const job = await adminApi('/admin/previews/generate-batch', {
        method: 'POST',
        body: JSON.stringify({ engine, priority_voice: selectedVoice(engine), speed: PREVIEW_SPEED })
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

    const note = document.querySelector(`#${engine} .engine-note`);
    if (note) note.innerHTML = '<b>固定试听改为手动模式：</b>系统不会再自动跑后台任务。你保存统一试听文案后，可以只生成当前音色，也可以一键生成全部音色；固定试听统一为 1.0x，生成后的试听会永久保存在服务器本地。每个音色都可以写你自己的备注。';

    const voiceNote = document.createElement('div');
    voiceNote.className = 'field';
    voiceNote.innerHTML = `
      <label>这个音色的备注（只给你自己看，永久保存在服务器）</label>
      <div class="row">
        <input id="${engine}VoiceNote" class="input" maxlength="500" style="flex:1;min-width:260px" placeholder="例如：温柔、适合播客女声、英文自然、偏成熟……">
        <button class="btn small secondary" id="${engine}SaveVoiceNote">保存备注</button>
        <span class="muted" id="${engine}VoiceNoteStatus">未备注</span>
      </div>`;
    box.parentNode.insertBefore(voiceNote, box);

    const controls = document.createElement('div');
    controls.innerHTML = `
      <div class="field" style="margin-top:10px">
        <label>固定试听文案（Kokoro / Edge 共用，可随时修改）</label>
        <textarea id="${engine}PreviewTemplate" style="min-height:112px">${DEFAULT_TEXT}</textarea>
      </div>
      <div class="row" style="margin-bottom:12px">
        <button class="btn small secondary" id="${engine}SavePreviewText">保存试听文案</button>
        <button class="btn small" id="${engine}GeneratePreview">生成 / 更新当前音色试听</button>
        <button class="btn small secondary" id="${engine}GenerateAllPreview">一键生成全部试听</button>
        <span class="muted" id="${engine}PreviewCount">读取中</span>
      </div>
      <div class="muted" style="margin-bottom:12px">不会再自动后台生成。只有你点击生成时才工作；固定试听统一 1.0x，并永久保存在服务器本地，部署和普通音频清理都不会删除。下面的音色库表格会显示全部音色、试听状态和你的备注。</div>`;
    const player = box.querySelector('.preview-player');
    box.insertBefore(controls, player || null);

    const textEditor = editor(engine);
    if (textEditor) textEditor.addEventListener('input', () => { state.dirty[engine] = true; });
    const voiceNoteInput = noteInput(engine);
    if (voiceNoteInput) voiceNoteInput.addEventListener('input', () => {
      const el = noteStatus(engine);
      if (el) el.textContent = '未保存';
    });
    document.querySelector(`#${engine}SaveVoiceNote`).onclick = () => saveVoiceNote(engine).catch(err => toast(err.message));
    document.querySelector(`#${engine}SavePreviewText`).onclick = () => saveTemplate(engine).catch(err => toast(err.message));
    document.querySelector(`#${engine}GeneratePreview`).onclick = () => generateCurrent(engine);
    document.querySelector(`#${engine}GenerateAllPreview`).onclick = () => generateAll(engine);
    setStatus(engine, '未生成', '');
  }

  ['kokoro', 'edge'].forEach(installPanel);

  try { loadPreviewManifest = loadManualManifest; } catch (_) {}
  try { refreshPreview = refreshManualPreview; } catch (_) {}
  try { playPreview = playManualPreview; } catch (_) {}

  const kokoroVoice = selector('kokoro', 'Voice');
  const edgeVoice = selector('edge', 'Voice');
  if (kokoroVoice) kokoroVoice.onchange = () => { refreshManualPreview('kokoro'); refreshVoiceNote('kokoro'); };
  if (edgeVoice) edgeVoice.onchange = () => { refreshManualPreview('edge'); refreshVoiceNote('edge'); };
  const kokoroPlay = selector('kokoro', 'PreviewBtn');
  const edgePlay = selector('edge', 'PreviewBtn');
  if (kokoroPlay) kokoroPlay.onclick = () => playManualPreview('kokoro');
  if (edgePlay) edgePlay.onclick = () => playManualPreview('edge');

  if (typeof sessionToken !== 'undefined' && sessionToken) {
    Promise.all([loadManualManifest(true), loadVoiceNotes(true)]).then(() => {
      setTimeout(() => ['kokoro', 'edge'].forEach(engine => { decorateVoiceOptions(engine); refreshVoiceNote(engine); }), 300);
    });
  }

  // New console features live in separate first-class modules so the existing
  // TTS page remains stable. These loaders are part of the verified frontend.
  if (!document.getElementById('project5VoiceLibraryScript')) {
    const script = document.createElement('script');
    script.id = 'project5VoiceLibraryScript';
    script.src = '/static/voice-library.js?v=voice-library-retention-v1';
    script.async = false;
    document.body.appendChild(script);
  }

  if (!document.getElementById('project5ApiKeyUiScript')) {
    const script = document.createElement('script');
    script.id = 'project5ApiKeyUiScript';
    script.src = '/static/api-key-ui.js?v=api-key-ui-v1';
    script.async = false;
    document.body.appendChild(script);
  }
})();