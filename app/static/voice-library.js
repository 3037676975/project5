(() => {
  const FEATURE_VERSION = 'voice-library-retention-v1';
  const PAGE_SIZE = 20;
  const state = {
    voices: { kokoro: [], edge: [] },
    notes: { kokoro: {}, edge: {} },
    manifest: { kokoro: {}, edge: {}, counts: {} },
    query: { kokoro: '', edge: '' },
    page: { kokoro: 1, edge: 1 },
    batch: { kokoro: null, edge: null },
    audio: null,
    initialized: false,
  };

  function esc(value) {
    return String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  }
  function fmtBytes(bytes) {
    const n = Number(bytes || 0);
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / 1024 / 1024).toFixed(1)} MB`;
  }
  function engineLabel(engine) { return engine === 'edge' ? 'Edge' : 'Kokoro'; }
  function noteFor(engine, voice) { return state.notes?.[engine]?.[voice]?.note || ''; }
  function previewFor(engine, voice) { return state.manifest?.[engine]?.[voice] || null; }
  function notify(message) { if (typeof toast === 'function') toast(message); else console.log(message); }

  function installCss() {
    if (document.getElementById('p5VoiceLibraryCss')) return;
    const style = document.createElement('style');
    style.id = 'p5VoiceLibraryCss';
    style.textContent = `
      .p5-voice-library{margin-top:18px}.p5-voice-toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:12px 0 16px}
      .p5-voice-search{max-width:340px}.p5-table-wrap{overflow:auto;border:1px solid var(--line);border-radius:14px;background:#fff}
      .p5-voice-table{min-width:980px}.p5-voice-table th{position:sticky;top:0;background:#f8fafc;z-index:1}
      .p5-voice-table td{padding:9px}.p5-note-input{min-width:250px;padding:8px 9px!important}.p5-actions{display:flex;gap:6px;flex-wrap:wrap}
      .p5-preview-state{white-space:nowrap}.p5-pager{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-top:12px;flex-wrap:wrap}
      .p5-batch-box{display:flex;gap:14px;align-items:center;padding:12px 14px;border:1px solid #dbeafe;background:#f8fbff;border-radius:14px;min-height:92px}
      .p5-batch-ring{--p:0;width:72px;height:72px;border-radius:50%;display:grid;place-items:center;position:relative;flex:none;background:conic-gradient(var(--blue) calc(var(--p)*1%),#e5e7eb 0)}
      .p5-batch-ring.edge{background:conic-gradient(var(--green) calc(var(--p)*1%),#e5e7eb 0)}.p5-batch-ring:before{content:"";position:absolute;inset:7px;border-radius:50%;background:#fff}
      .p5-batch-ring span{position:relative;font-weight:800;font-size:14px}.p5-retention{margin:0 0 18px;padding:16px;border:1px solid #dbeafe;border-radius:14px;background:#f8fbff}
      .p5-switch{position:relative;display:inline-flex;width:46px;height:26px;align-items:center}.p5-switch input{display:none}.p5-switch i{position:absolute;inset:0;border-radius:999px;background:#cbd5e1;transition:.2s}.p5-switch i:after{content:"";position:absolute;width:20px;height:20px;left:3px;top:3px;border-radius:50%;background:#fff;box-shadow:0 1px 4px rgba(0,0,0,.2);transition:.2s}.p5-switch input:checked+i{background:var(--blue)}.p5-switch input:checked+i:after{transform:translateX(20px)}
      .p5-doc-v2{margin-top:20px;border-top:1px solid var(--line);padding-top:18px}.p5-doc-v2 h3{margin:18px 0 8px}.p5-inline-code{font-family:ui-monospace,SFMono-Regular,monospace;background:#eef2f7;border-radius:6px;padding:2px 6px;font-size:12px}
      @media(max-width:780px){.p5-batch-box{align-items:flex-start}.p5-voice-search{max-width:none;width:100%}}
    `;
    document.head.appendChild(style);
  }

  async function fetchVoices(engine) {
    const r = await fetch(`/v1/voices?engine=${encodeURIComponent(engine)}&_=${Date.now()}`, { cache: 'no-store' });
    if (!r.ok) throw new Error(`音色列表读取失败：${r.status}`);
    const data = await r.json();
    state.voices[engine] = data.voices || [];
  }

  async function refreshData() {
    const [manifest, notes] = await Promise.all([
      adminApi('/admin/previews?_=' + Date.now()),
      adminApi('/admin/voice-notes?_=' + Date.now()),
    ]);
    state.manifest = manifest;
    state.notes = notes.notes || { kokoro: {}, edge: {} };
    renderVoiceTable('kokoro');
    renderVoiceTable('edge');
  }

  function filteredVoices(engine) {
    const q = state.query[engine].trim().toLowerCase();
    if (!q) return state.voices[engine];
    return state.voices[engine].filter(v => {
      const note = noteFor(engine, v.id);
      return `${v.id} ${v.label || ''} ${v.gender || ''} ${v.locale || ''} ${note}`.toLowerCase().includes(q);
    });
  }

  function previewBadge(engine, voice) {
    const item = previewFor(engine, voice);
    if (!item?.url) return '<span class="badge">未生成</span>';
    if (item.stale) return '<span class="badge processing">旧文案</span>';
    return '<span class="badge ok">已保存</span>';
  }

  function renderVoiceTable(engine) {
    const host = document.getElementById(`${engine}VoiceLibraryBody`);
    const pager = document.getElementById(`${engine}VoiceLibraryPager`);
    const totalLabel = document.getElementById(`${engine}VoiceLibraryTotal`);
    if (!host || !pager) return;
    const list = filteredVoices(engine);
    const pages = Math.max(1, Math.ceil(list.length / PAGE_SIZE));
    state.page[engine] = Math.min(Math.max(state.page[engine], 1), pages);
    const start = (state.page[engine] - 1) * PAGE_SIZE;
    const rows = list.slice(start, start + PAGE_SIZE);
    const globalOffset = start;
    host.innerHTML = rows.length ? rows.map((v, i) => {
      const note = noteFor(engine, v.id);
      const meta = [v.gender === 'female' ? '女声' : v.gender === 'male' ? '男声' : v.gender || '', v.locale || ''].filter(Boolean).join(' · ');
      return `<tr data-voice="${esc(v.id)}">
        <td>${globalOffset + i + 1}</td>
        <td><b>${esc(v.label || v.id)}</b><div class="muted mono">${esc(v.id)}</div></td>
        <td>${esc(meta || '-')}</td>
        <td class="p5-preview-state">${previewBadge(engine, v.id)}</td>
        <td><input class="input p5-note-input" data-role="note" value="${esc(note)}" maxlength="500" placeholder="例如：温柔、适合播客、英文自然"></td>
        <td><div class="p5-actions">
          <button class="btn small secondary" data-action="play">▶ 试听</button>
          <button class="btn small secondary" data-action="generate">生成试听</button>
          <button class="btn small secondary" data-action="save-note">保存备注</button>
          <button class="btn small secondary" data-action="copy">复制ID</button>
        </div></td>
      </tr>`;
    }).join('') : '<tr><td colspan="6" class="empty">没有匹配的音色</td></tr>';
    if (totalLabel) totalLabel.textContent = `${list.length} 个音色 · 已保存试听 ${state.manifest?.counts?.[engine]?.ready || 0}/${state.manifest?.counts?.[engine]?.total || state.voices[engine].length}`;
    pager.innerHTML = `<span class="muted">第 ${state.page[engine]} / ${pages} 页</span><div class="row"><button class="btn small secondary" data-page-action="prev" ${state.page[engine] <= 1 ? 'disabled' : ''}>上一页</button><button class="btn small secondary" data-page-action="next" ${state.page[engine] >= pages ? 'disabled' : ''}>下一页</button></div>`;
  }

  async function saveRowNote(engine, row) {
    const voice = row.dataset.voice;
    const note = row.querySelector('[data-role="note"]')?.value?.trim() || '';
    const data = await adminApi('/admin/voice-notes', { method: 'PUT', body: JSON.stringify({ engine, voice, note }) });
    state.notes[engine] = data.notes?.[engine] || {};
    renderVoiceTable(engine);
    notify(note ? `${voice} 备注已保存` : `${voice} 备注已清空`);
  }

  async function playRow(engine, voice) {
    const item = previewFor(engine, voice);
    if (!item?.url) {
      notify('这个音色还没有固定试听，请先生成');
      return;
    }
    if (state.audio) { try { state.audio.pause(); } catch (_) {} }
    state.audio = new Audio(item.url + `?v=${encodeURIComponent(item.updated_at || Date.now())}`);
    try { await state.audio.play(); } catch (_) { notify('浏览器阻止了自动播放，请再点一次试听'); }
  }

  async function pollJob(engine, jobId, ringHost, onDone) {
    state.batch[engine] = jobId;
    while (true) {
      const job = await adminApi(`/admin/previews/jobs/${encodeURIComponent(jobId)}?_=${Date.now()}`);
      const finished = Number(job.completed || 0) + Number(job.failed || 0);
      const total = Math.max(1, Number(job.total || 1));
      const pct = Math.max(0, Math.min(100, Math.round(finished / total * 100)));
      if (ringHost) {
        const ring = ringHost.querySelector('.p5-batch-ring');
        const pctText = ringHost.querySelector('[data-role="pct"]');
        const detail = ringHost.querySelector('[data-role="detail"]');
        if (ring) ring.style.setProperty('--p', pct);
        if (pctText) pctText.textContent = `${pct}%`;
        if (detail) detail.textContent = `${finished}/${total}${job.failed ? ` · 失败 ${job.failed}` : ''}${job.skipped ? ` · 跳过 ${job.skipped}` : ''}${job.current_voice ? ` · 当前 ${job.current_voice}` : ''}`;
      }
      if (job.status === 'completed') {
        state.batch[engine] = null;
        await refreshData();
        if (onDone) onDone(job);
        return job;
      }
      if (job.status === 'failed') { state.batch[engine] = null; throw new Error(job.error || '试听生成失败'); }
      if (job.status === 'cancelled') { state.batch[engine] = null; throw new Error('任务已取消'); }
      await new Promise(resolve => setTimeout(resolve, 800));
    }
  }

  async function generateOne(engine, voice) {
    const job = await adminApi('/admin/previews/generate', { method: 'POST', body: JSON.stringify({ engine, voice, speed: 1.0 }) });
    notify(`${voice} 开始生成固定试听`);
    await pollJob(engine, job.id, null, () => notify(`${voice} 试听已永久保存`));
  }

  async function generateAll(engine) {
    if (state.batch[engine]) return notify(`${engineLabel(engine)} 已经有批量试听任务在运行`);
    const total = state.voices[engine].length;
    if (!confirm(`一键生成/补齐 ${engineLabel(engine)} 全部 ${total} 个固定试听？\n已是当前试听文案的音色会自动跳过，生成结果永久保存在服务器。`)) return;
    const box = document.getElementById(`${engine}BatchProgress`);
    box.style.display = 'flex';
    const ring = box.querySelector('.p5-batch-ring');
    if (ring) ring.style.setProperty('--p', 0);
    const pct = box.querySelector('[data-role="pct"]'); if (pct) pct.textContent = '0%';
    const detail = box.querySelector('[data-role="detail"]'); if (detail) detail.textContent = `0/${total} · 准备开始`;
    const job = await adminApi('/admin/previews/generate-batch', { method: 'POST', body: JSON.stringify({ engine, speed: 1.0 }) });
    try {
      await pollJob(engine, job.id, box, () => notify(`${engineLabel(engine)} 全部固定试听处理完成`));
    } catch (err) {
      notify(err.message || '批量试听失败');
      throw err;
    }
  }

  async function cancelBatch(engine) {
    const id = state.batch[engine];
    if (!id) return;
    await adminApi(`/admin/previews/jobs/${encodeURIComponent(id)}/cancel`, { method: 'POST' });
    state.batch[engine] = null;
    notify(`${engineLabel(engine)} 批量试听已取消`);
  }

  function installLibrary(engine) {
    const section = document.getElementById(engine);
    if (!section || document.getElementById(`${engine}VoiceLibrary`)) return;
    const panel = document.createElement('div');
    panel.className = 'panel p5-voice-library';
    panel.id = `${engine}VoiceLibrary`;
    panel.innerHTML = `
      <div class="section-title"><div><h2>${engineLabel(engine)} 音色库 / 固定试听表</h2><div class="muted">默认列出全部音色。可以逐个试听、生成、记录备注，也可以一键生成全部固定试听。音色 ID 就是 API 调用时的 <span class="p5-inline-code">voice</span> 参数。</div></div><span class="badge" id="${engine}VoiceLibraryTotal">读取中</span></div>
      <div class="p5-voice-toolbar">
        <input class="input p5-voice-search" id="${engine}VoiceLibrarySearch" placeholder="搜索音色 ID / 名称 / 备注">
        <button class="btn" id="${engine}GenerateAllLibrary">一键生成全部试听</button>
        <button class="btn secondary" id="${engine}RefreshLibrary">刷新表格</button>
      </div>
      <div class="p5-batch-box" id="${engine}BatchProgress" style="display:none">
        <div class="p5-batch-ring ${engine === 'edge' ? 'edge' : ''}"><span data-role="pct">0%</span></div>
        <div><b>批量固定试听进度</b><div class="muted" data-role="detail">等待开始</div><div class="row" style="margin-top:6px"><button class="btn small secondary" id="${engine}CancelBatch">取消批量任务</button></div></div>
      </div>
      <div class="p5-table-wrap" style="margin-top:14px"><table class="p5-voice-table"><thead><tr><th>#</th><th>音色 / API ID</th><th>类型</th><th>固定试听</th><th>我的备注</th><th>操作</th></tr></thead><tbody id="${engine}VoiceLibraryBody"><tr><td colspan="6" class="empty">读取中...</td></tr></tbody></table></div>
      <div class="p5-pager" id="${engine}VoiceLibraryPager"></div>`;
    section.appendChild(panel);

    panel.querySelector(`#${engine}VoiceLibrarySearch`).addEventListener('input', e => { state.query[engine] = e.target.value; state.page[engine] = 1; renderVoiceTable(engine); });
    panel.querySelector(`#${engine}GenerateAllLibrary`).onclick = () => generateAll(engine).catch(err => notify(err.message));
    panel.querySelector(`#${engine}RefreshLibrary`).onclick = () => refreshData().catch(err => notify(err.message));
    panel.querySelector(`#${engine}CancelBatch`).onclick = () => cancelBatch(engine).catch(err => notify(err.message));
    panel.querySelector(`#${engine}VoiceLibraryPager`).onclick = e => {
      const action = e.target?.dataset?.pageAction;
      if (!action) return;
      state.page[engine] += action === 'next' ? 1 : -1;
      renderVoiceTable(engine);
    };
    panel.querySelector(`#${engine}VoiceLibraryBody`).onclick = async e => {
      const button = e.target.closest('button[data-action]');
      if (!button) return;
      const row = button.closest('tr[data-voice]');
      if (!row) return;
      const voice = row.dataset.voice;
      button.disabled = true;
      try {
        if (button.dataset.action === 'play') await playRow(engine, voice);
        else if (button.dataset.action === 'generate') await generateOne(engine, voice);
        else if (button.dataset.action === 'save-note') await saveRowNote(engine, row);
        else if (button.dataset.action === 'copy') { await navigator.clipboard.writeText(voice); notify(`已复制 ${voice}`); }
      } catch (err) { notify(err.message || '操作失败'); }
      finally { button.disabled = false; }
    };
  }

  function installRetention() {
    const filesPanel = document.querySelector('#files .panel');
    if (!filesPanel || document.getElementById('p5AudioRetention')) return;
    const box = document.createElement('div');
    box.className = 'p5-retention';
    box.id = 'p5AudioRetention';
    box.innerHTML = `
      <div class="section-title" style="margin-bottom:8px"><div><b>音频文件保存策略</b><div class="muted">只影响正式生成的 WAV / MP3；固定音色试听永久保留，不参与 24 小时清理。</div></div><div class="row"><span id="p5RetentionMode" class="badge">读取中</span><label class="p5-switch" title="开启 24 小时自动清理"><input id="p5RetentionToggle" type="checkbox"><i></i></label></div></div>
      <div class="row"><span class="muted" id="p5RetentionStats">读取中...</span><button class="btn small secondary" id="p5RetentionCleanup">立即按 24 小时规则清理</button></div>`;
    const anchor = filesPanel.querySelector('.section-title');
    if (anchor && anchor.nextSibling) filesPanel.insertBefore(box, anchor.nextSibling); else filesPanel.prepend(box);

    document.getElementById('p5RetentionToggle').addEventListener('change', async e => {
      const enabled = e.target.checked;
      if (enabled && !confirm('开启后，已经超过 24 小时的正式生成音频会立即清理；任务记录和固定试听不会删除。确认开启？')) { e.target.checked = false; return; }
      try {
        const data = await adminApi('/admin/audio-retention', { method: 'PUT', body: JSON.stringify({ enabled }) });
        renderRetention(data);
        notify(enabled ? '已开启：正式生成音频只保留 24 小时' : '已关闭自动清理：改为手动管理');
        if (typeof loadFiles === 'function') loadFiles();
      } catch (err) { e.target.checked = !enabled; notify(err.message || '保存策略失败'); }
    });
    document.getElementById('p5RetentionCleanup').onclick = async () => {
      try {
        const data = await adminApi('/admin/audio-retention/cleanup', { method: 'POST' });
        renderRetention(data);
        notify(`24 小时规则清理完成：删除 ${data.deleted_files || 0} 个文件`);
        if (typeof loadFiles === 'function') loadFiles();
      } catch (err) { notify(err.message || '清理失败'); }
    };
  }

  function renderRetention(data) {
    const toggle = document.getElementById('p5RetentionToggle');
    const mode = document.getElementById('p5RetentionMode');
    const stats = document.getElementById('p5RetentionStats');
    if (!toggle || !mode || !stats) return;
    toggle.checked = !!data.enabled;
    mode.textContent = data.enabled ? '24小时自动清理' : '手动清理';
    mode.className = `badge ${data.enabled ? 'ok' : ''}`;
    stats.textContent = `当前正式音频 ${data.retained_files || 0} 个 / ${fmtBytes(data.retained_bytes)} · 已超过24小时 ${data.expired_files || 0} 个 · 任务历史永久保留`;
  }

  async function loadRetention() {
    try { renderRetention(await adminApi('/admin/audio-retention?_=' + Date.now())); }
    catch (err) { const s = document.getElementById('p5RetentionStats'); if (s) s.textContent = '保存策略读取失败'; }
  }

  function installDocs() {
    const panel = document.querySelector('#docs .panel');
    if (!panel || document.getElementById('p5ApiDocsV2')) return;
    const box = document.createElement('div');
    box.className = 'p5-doc-v2 doc';
    box.id = 'p5ApiDocsV2';
    box.innerHTML = `
      <h2>Project5 双引擎 API · 当前调用规范</h2>
      <p class="muted">Kokoro 与 Edge 共用同一个 API Key 和同一个异步任务接口。上方音色表里的“API ID”可直接作为 voice 参数。</p>
      <h3>1. 获取音色</h3>
      <div class="code">GET /v1/voices?engine=kokoro\nGET /v1/voices?engine=edge</div>
      <h3>2. Kokoro 本地 CPU 生成</h3>
      <div class="code">POST /v1/audio/speech\nAuthorization: Bearer YOUR_API_KEY\nContent-Type: application/json\n\n{\n  "input": "今天聊聊 ChatGPT and LangChain，然后继续中文。",\n  "engine": "kokoro",\n  "voice": "zf_001",\n  "speed": 1.0\n}</div>
      <h3>3. Edge 在线生成</h3>
      <div class="code">POST /v1/audio/speech\nAuthorization: Bearer YOUR_API_KEY\nContent-Type: application/json\n\n{\n  "input": "今天测试 Edge TTS。",\n  "engine": "edge",\n  "voice": "zh-CN-XiaoxiaoNeural",\n  "speed": 1.0\n}</div>
      <h3>4. 异步任务流程</h3>
      <div class="code">POST /v1/audio/speech  → HTTP 202\n{ "id": "tts_...", "status": "queued", "task_url": ".../v1/tasks/tts_..." }\n\nGET /v1/tasks/{id}\nAuthorization: Bearer YOUR_API_KEY\n\nstatus = completed 后读取 audio_url。</div>
      <h3>5. 固定试听与备注（后台管理）</h3>
      <div class="code">GET  /admin/previews\nPUT  /admin/previews/text\nPOST /admin/previews/generate\nPOST /admin/previews/generate-batch\nGET  /admin/voice-notes\nPUT  /admin/voice-notes</div>
      <p class="muted">固定试听是音色库资产，永久保存在服务器；正式生成音频则由「音频文件保存策略」控制。若开启 24 小时模式，audio_url 对应的正式音频会在完成 24 小时后清理，但任务历史仍保留。</p>`;
    panel.appendChild(box);
  }

  async function init() {
    if (state.initialized) return;
    if (typeof adminApi !== 'function') return;
    if (typeof sessionToken !== 'undefined' && !sessionToken) return;
    state.initialized = true;
    installCss();
    installLibrary('kokoro');
    installLibrary('edge');
    installRetention();
    installDocs();
    try {
      await Promise.all([fetchVoices('kokoro'), fetchVoices('edge')]);
      await refreshData();
      await loadRetention();
    } catch (err) {
      state.initialized = false;
      notify(err.message || '音色库初始化失败');
    }
  }

  installCss();
  installLibrary('kokoro');
  installLibrary('edge');
  installRetention();
  installDocs();

  const timer = setInterval(() => {
    if (state.initialized) { clearInterval(timer); return; }
    init().catch(() => {});
  }, 900);
  init().catch(() => {});

  window.Project5VoiceLibrary = { version: FEATURE_VERSION, refresh: refreshData, loadRetention };
})();
