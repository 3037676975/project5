(() => {
  'use strict';

  const ENGINE_META = {
    kokoro: {
      label: 'Kokoro 本地 CPU',
      model: 'Kokoro-82M-v1.1-zh',
      defaultVoice: 'zf_001',
      note: '本地运行 · 隐私好 · 不依赖外网 · 现在支持中英混读'
    },
    edge: {
      label: 'Edge 在线 TTS',
      model: 'Microsoft Edge Online TTS',
      defaultVoice: 'zh-CN-XiaoxiaoNeural',
      note: '在线生成 · 通常更快 · 中文音色丰富 · 需要服务器能访问微软语音服务'
    }
  };

  let engineVoices = [];

  const byId = id => document.getElementById(id);
  const currentEngine = () => byId('ttsEngine')?.value || 'kokoro';
  window.project5CurrentEngine = currentEngine;

  function genderText(v) {
    if (v.gender === 'female' || String(v.id).startsWith('zf_')) return '女声';
    if (v.gender === 'male' || String(v.id).startsWith('zm_')) return '男声';
    return '中文音色';
  }

  function renderEngineVoices() {
    const q = (byId('voiceSearch')?.value || '').trim().toLowerCase();
    const visible = engineVoices.filter(v => !q || `${v.id} ${v.label} ${genderText(v)}`.toLowerCase().includes(q));
    if (byId('voiceCount')) byId('voiceCount').textContent = `${visible.length} 个音色`;
    if (!byId('voiceGrid')) return;

    byId('voiceGrid').innerHTML = visible.length
      ? visible.map(v => `<div class="voice-card" data-voice="${v.id}">
          <strong>${v.label}</strong>
          <div class="voice-meta"><span class="mono">${v.id}</span><span>${genderText(v)}</span></div>
          <button class="btn small secondary p5-engine-preview" data-voice="${v.id}">▶ 试听</button>
        </div>`).join('')
      : '<div class="empty">没有找到对应音色</div>';

    document.querySelectorAll('.p5-engine-preview').forEach(button => {
      button.onclick = async () => {
        const voice = button.dataset.voice;
        if (byId('ttsVoice')) byId('ttsVoice').value = voice;
        localStorage.setItem(`p5_voice_${currentEngine()}`, voice);
        document.querySelectorAll('.voice-card').forEach(x => x.classList.toggle('selected', x.dataset.voice === voice));
        if (typeof window.synthesize === 'function') await window.synthesize(voice, button);
      };
    });
  }

  async function loadEngineVoices() {
    const engine = currentEngine();
    const meta = ENGINE_META[engine];
    const response = await fetch(`/v1/voices?engine=${encodeURIComponent(engine)}&_=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`加载 ${engine} 音色失败 HTTP ${response.status}`);
    const data = await response.json();
    engineVoices = data.voices || [];

    const select = byId('ttsVoice');
    if (select) {
      const remembered = localStorage.getItem(`p5_voice_${engine}`);
      const preferred = engineVoices.some(v => v.id === remembered)
        ? remembered
        : (engineVoices.some(v => v.id === meta.defaultVoice) ? meta.defaultVoice : engineVoices[0]?.id);
      select.innerHTML = engineVoices.map(v => `<option value="${v.id}">${v.label} (${v.id})</option>`).join('');
      if (preferred) select.value = preferred;
      select.onchange = () => {
        localStorage.setItem(`p5_voice_${engine}`, select.value);
        document.querySelectorAll('.voice-card').forEach(x => x.classList.toggle('selected', x.dataset.voice === select.value));
      };
    }

    const model = byId('ttsModelLabel');
    if (model) model.value = meta.model;
    const note = byId('ttsEngineNote');
    if (note) note.textContent = meta.note;

    renderEngineVoices();
    if (typeof window.project5RefreshRuntime === 'function') window.project5RefreshRuntime();
  }

  async function pollTask(taskId) {
    const deadline = Date.now() + 15 * 60 * 1000;
    while (Date.now() < deadline) {
      const task = await adminApi(`/admin/tasks/${encodeURIComponent(taskId)}`);
      if (task.status === 'completed') return task;
      if (task.status === 'failed') throw new Error(task.error || `${task.engine || ''} 生成失败`);
      await new Promise(resolve => setTimeout(resolve, 1200));
    }
    throw new Error(`任务 ${taskId} 超过 15 分钟仍未完成`);
  }

  async function submitEngine(engine, voice, text, spd) {
    const accepted = await adminApi('/admin/speech', {
      method: 'POST',
      body: JSON.stringify({ input: text, engine, voice, speed: spd })
    });
    if (!accepted?.id) throw new Error(`${engine} 没有返回 task_id`);
    return pollTask(accepted.id);
  }

  function compareCard(title, task, error) {
    if (error) {
      return `<div class="result" style="border-color:#fecaca;color:#991b1b"><b>${title} · 失败</b><div style="margin-top:8px">${String(error.message || error)}</div></div>`;
    }
    const seconds = task.elapsed_ms ? `${(task.elapsed_ms / 1000).toFixed(2)} 秒` : '-';
    return `<div class="audio-result">
      <div class="audio-head"><div><b>${title}</b><div class="muted">${task.voice} · 生成耗时 ${seconds}</div></div><span class="badge ok">成功</span></div>
      <audio controls src="${task.audio_url}"></audio>
      <div class="muted" style="margin-top:8px">任务 ${task.id} · ${task.audio_filename || ''}</div>
    </div>`;
  }

  window.compareEngines = async function compareEngines() {
    const text = byId('ttsText')?.value.trim();
    if (!text) {
      toast('请先输入对比文本');
      return;
    }
    const spd = typeof speed === 'function' ? speed() : 1.0;
    const button = byId('compareEnginesBtn');
    const result = byId('compareEngineResults');
    if (!button || !result) return;

    const kokoroVoice = localStorage.getItem('p5_voice_kokoro') || ENGINE_META.kokoro.defaultVoice;
    const edgeVoice = localStorage.getItem('p5_voice_edge') || ENGINE_META.edge.defaultVoice;
    button.disabled = true;
    button.textContent = '双引擎生成中…';
    result.innerHTML = '<div class="result"><b>正在同时提交 Kokoro 和 Edge 两个任务</b><div class="muted" style="margin-top:6px">会分别记录真实生成耗时，方便你选择播客主引擎。</div></div>';

    try {
      const [kokoroResult, edgeResult] = await Promise.allSettled([
        submitEngine('kokoro', kokoroVoice, text, spd),
        submitEngine('edge', edgeVoice, text, spd)
      ]);
      const kokoroTask = kokoroResult.status === 'fulfilled' ? kokoroResult.value : null;
      const edgeTask = edgeResult.status === 'fulfilled' ? edgeResult.value : null;
      result.innerHTML = `<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px">
        ${compareCard('Kokoro 本地', kokoroTask, kokoroResult.status === 'rejected' ? kokoroResult.reason : null)}
        ${compareCard('Edge 在线', edgeTask, edgeResult.status === 'rejected' ? edgeResult.reason : null)}
      </div>`;
      if (kokoroTask && edgeTask) {
        const faster = Number(edgeTask.elapsed_ms || Infinity) < Number(kokoroTask.elapsed_ms || Infinity) ? 'Edge' : 'Kokoro';
        result.insertAdjacentHTML('beforeend', `<div class="tip">本次相同文本实测：<b>${faster}</b> 生成更快。建议同时试听自然度再决定默认引擎。</div>`);
      }
      if (typeof loadDashboard === 'function') loadDashboard();
    } finally {
      button.disabled = false;
      button.textContent = '⚖️ 双引擎对比生成';
    }
  };

  function injectUI() {
    const voiceSelect = byId('ttsVoice');
    if (!voiceSelect || byId('ttsEngine')) return;

    const formGrid = voiceSelect.closest('.form-grid');
    const voiceField = voiceSelect.closest('.field');
    if (formGrid && voiceField) {
      const engineField = document.createElement('div');
      engineField.className = 'field';
      engineField.innerHTML = `<label>TTS 引擎</label><select id="ttsEngine">
        <option value="kokoro">Kokoro · 本地 CPU</option>
        <option value="edge">Edge TTS · 在线快速</option>
      </select>`;
      formGrid.insertBefore(engineField, voiceField);
      formGrid.style.gridTemplateColumns = '1fr 2fr 1fr 1fr';

      const oldModel = Array.from(formGrid.querySelectorAll('input[disabled]')).find(el => String(el.value).includes('Kokoro'));
      if (oldModel) oldModel.id = 'ttsModelLabel';
    }

    const rememberedEngine = localStorage.getItem('p5_engine');
    if (rememberedEngine && ENGINE_META[rememberedEngine]) byId('ttsEngine').value = rememberedEngine;
    byId('ttsEngine').onchange = async () => {
      localStorage.setItem('p5_engine', currentEngine());
      await loadEngineVoices().catch(err => toast(err.message));
    };

    const voiceFieldNode = byId('ttsVoice')?.closest('.field');
    if (voiceFieldNode && !byId('ttsEngineNote')) {
      const note = document.createElement('div');
      note.id = 'ttsEngineNote';
      note.className = 'muted';
      note.style.marginTop = '7px';
      voiceFieldNode.appendChild(note);
    }

    const actions = byId('generateBtn')?.closest('.row');
    if (actions && !byId('compareEnginesBtn')) {
      const button = document.createElement('button');
      button.className = 'btn warning';
      button.id = 'compareEnginesBtn';
      button.textContent = '⚖️ 双引擎对比生成';
      button.onclick = window.compareEngines;
      actions.appendChild(button);
    }

    const generateResult = byId('generateResult');
    if (generateResult && !byId('compareEngineResults')) {
      const compare = document.createElement('div');
      compare.id = 'compareEngineResults';
      compare.style.marginTop = '14px';
      generateResult.insertAdjacentElement('afterend', compare);
    }

    if (byId('voiceSearch')) byId('voiceSearch').oninput = renderEngineVoices;
    if (byId('clearVoiceSearch')) byId('clearVoiceSearch').onclick = () => {
      byId('voiceSearch').value = '';
      renderEngineVoices();
    };

    loadEngineVoices().catch(err => toast(err.message));
    // The legacy page also loads Kokoro voices during its initial async boot. Reapply
    // the selected engine once that request has had time to settle.
    setTimeout(() => loadEngineVoices().catch(() => {}), 1200);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', injectUI, { once: true });
  } else {
    injectUI();
  }
})();
