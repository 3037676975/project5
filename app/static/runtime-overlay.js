(() => {
  'use strict';

  const esc = value => String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
  const byId = id => document.getElementById(id);
  const currentEngine = () => (typeof window.project5CurrentEngine === 'function' ? window.project5CurrentEngine() : 'kokoro');

  function setButtonsDisabled(disabled) {
    ['generateBtn', 'previewCurrentBtn', 'batchPreviewBtn'].forEach(id => {
      const el = byId(id);
      if (el) el.disabled = disabled;
    });
  }

  function ensureRuntimeBox() {
    let box = byId('project5RuntimeError');
    if (box) return box;
    box = document.createElement('div');
    box.id = 'project5RuntimeError';
    box.style.display = 'none';
    box.style.margin = '0 0 18px';
    box.style.padding = '14px 16px';
    box.style.borderRadius = '12px';
    box.style.fontSize = '13px';
    box.style.lineHeight = '1.65';
    const top = document.querySelector('.main .top');
    if (top?.parentNode) top.insertAdjacentElement('afterend', box);
    return box;
  }

  function fileSummary(files) {
    if (!files) return '';
    return Object.values(files).map(item => {
      const size = item?.bytes ? `${(item.bytes / 1024 / 1024).toFixed(1)} MB` : '0 MB';
      return `${esc(item?.name || 'file')}: ${item?.exists ? `存在 (${size})` : '缺失'}`;
    }).join(' · ');
  }

  function renderRuntime(data) {
    const state = data?.state || 'unknown';
    const selected = currentEngine();
    const edgeSelected = selected === 'edge';
    const healthText = byId('healthText');
    const readyBadge = byId('modelReadyBadge');
    const modelLoaded = byId('modelLoaded');
    const box = ensureRuntimeBox();

    if (state === 'error') {
      if (modelLoaded) {
        modelLoaded.textContent = 'Kokoro 加载失败 · Edge 仍可用';
        modelLoaded.style.color = '#b45309';
      }
      box.style.display = 'block';
      box.style.border = '1px solid #fed7aa';
      box.style.background = '#fff7ed';
      box.style.color = '#9a3412';
      box.innerHTML = `
        <b style="display:block;margin-bottom:5px">⚠ Kokoro 本地模型当前异常；Edge 在线 TTS 不受影响</b>
        <div><b>Kokoro 错误：</b><span class="mono">${esc(data.model_error || '未知加载错误')}</span></div>
        <div style="margin-top:5px">${fileSummary(data.files)}</div>
        <div style="margin-top:5px">后端：${esc(data.backend)} · CPU 线程：${esc(data.threads)}</div>`;

      if (edgeSelected) {
        if (healthText) healthText.textContent = 'Edge 在线 TTS 可用 · Kokoro 异常';
        if (readyBadge) {
          readyBadge.textContent = 'Edge 可生成';
          readyBadge.className = 'badge ok';
        }
        setButtonsDisabled(false);
      } else {
        if (healthText) healthText.textContent = 'Kokoro 模型加载失败';
        if (readyBadge) {
          readyBadge.textContent = 'Kokoro 不可用';
          readyBadge.className = 'badge fail';
        }
        setButtonsDisabled(true);
      }
      return;
    }

    if (state === 'ready') {
      if (healthText) healthText.textContent = edgeSelected ? 'Edge 在线 TTS · 可生成' : `Kokoro 正常 · ${String(data.device || 'cpu').toUpperCase()}`;
      if (readyBadge) {
        readyBadge.textContent = edgeSelected ? 'Edge 已就绪' : 'Kokoro 已就绪';
        readyBadge.className = 'badge ok';
      }
      if (modelLoaded) {
        modelLoaded.textContent = 'Kokoro 已加载 · Edge 在线可用';
        modelLoaded.style.color = '';
      }
      setButtonsDisabled(false);
      box.style.display = 'none';
      box.innerHTML = '';
      return;
    }

    if (edgeSelected) {
      if (healthText) healthText.textContent = 'Edge 在线 TTS · 可生成';
      if (readyBadge) {
        readyBadge.textContent = 'Edge 已就绪';
        readyBadge.className = 'badge ok';
      }
      setButtonsDisabled(false);
    } else {
      if (healthText) healthText.textContent = 'Kokoro 模型加载中';
      if (readyBadge) {
        readyBadge.textContent = 'Kokoro 加载中';
        readyBadge.className = 'badge processing';
      }
      setButtonsDisabled(true);
    }
    if (modelLoaded) {
      modelLoaded.textContent = 'Kokoro 加载中 · Edge 在线可用';
      modelLoaded.style.color = '';
    }
    box.style.display = 'none';
  }

  async function refreshRuntime() {
    try {
      const response = await fetch(`/runtime?_=${Date.now()}`, { cache: 'no-store' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      renderRuntime(await response.json());
    } catch (error) {
      const healthText = byId('healthText');
      if (healthText) healthText.textContent = '运行状态检测失败';
    }
  }
  window.project5RefreshRuntime = refreshRuntime;

  if (typeof window.taskTable === 'function') {
    const originalTaskTable = window.taskTable;
    window.taskTable = function project5TaskTableWithErrors(items) {
      let base = originalTaskTable(items);
      // Add an engine label beside task IDs without changing the legacy table structure.
      (items || []).forEach(item => {
        if (!item?.id || !item?.engine) return;
        const label = item.engine === 'edge' ? 'Edge' : 'Kokoro';
        base = base.replace(`<td class="mono">${item.id}</td>`, `<td class="mono">${item.id}<div class="muted">${label}</div></td>`);
      });
      const failed = (items || []).filter(item => item?.status === 'failed' && item?.error);
      if (!failed.length) return base;
      const details = failed.slice(0, 10).map(item => `
        <div style="padding:9px 0;border-bottom:1px solid #fee2e2">
          <span class="mono">${esc(item.id)}</span>
          <span style="margin-left:8px">${esc(item.error)}</span>
        </div>`).join('');
      return `${base}<div style="margin-top:12px;padding:12px 14px;border:1px solid #fecaca;background:#fff7f7;border-radius:10px;color:#991b1b;font-size:12px"><b>失败详情</b>${details}</div>`;
    };
  }

  refreshRuntime();
  window.setInterval(refreshRuntime, 2500);
})();
