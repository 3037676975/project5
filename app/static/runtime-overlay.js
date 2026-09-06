(() => {
  'use strict';

  const esc = (value) => String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');

  const byId = (id) => document.getElementById(id);

  function setButtonsDisabled(disabled) {
    ['generateBtn', 'previewCurrentBtn', 'batchPreviewBtn'].forEach((id) => {
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
    box.style.border = '1px solid #fecaca';
    box.style.background = '#fef2f2';
    box.style.color = '#991b1b';
    box.style.fontSize = '13px';
    box.style.lineHeight = '1.65';

    const top = document.querySelector('.main .top');
    if (top && top.parentNode) top.insertAdjacentElement('afterend', box);
    return box;
  }

  function fileSummary(files) {
    if (!files) return '';
    return Object.values(files).map((item) => {
      const size = item?.bytes ? `${(item.bytes / 1024 / 1024).toFixed(1)} MB` : '0 MB';
      return `${esc(item?.name || 'file')}: ${item?.exists ? `存在 (${size})` : '缺失'}`;
    }).join(' · ');
  }

  function renderRuntime(data) {
    const state = data?.state || 'unknown';
    const healthText = byId('healthText');
    const readyBadge = byId('modelReadyBadge');
    const modelLoaded = byId('modelLoaded');
    const box = ensureRuntimeBox();

    if (state === 'error') {
      if (healthText) healthText.textContent = '服务异常 · 模型加载失败';
      if (readyBadge) {
        readyBadge.textContent = '模型加载失败';
        readyBadge.className = 'badge fail';
      }
      if (modelLoaded) {
        modelLoaded.textContent = '加载失败';
        modelLoaded.style.color = '#b91c1c';
      }
      setButtonsDisabled(true);
      box.style.display = 'block';
      box.innerHTML = `
        <b style="display:block;margin-bottom:5px">⚠ Kokoro 模型没有正常加载，当前不能生成语音</b>
        <div><b>真实错误：</b><span class="mono">${esc(data.model_error || '未知加载错误')}</span></div>
        <div style="margin-top:5px;color:#7f1d1d">${fileSummary(data.files)}</div>
        <div style="margin-top:5px;color:#7f1d1d">后端：${esc(data.backend)} · CPU 线程：${esc(data.threads)}</div>`;
      return;
    }

    if (state === 'ready') {
      if (healthText) healthText.textContent = `服务正常 · ${String(data.device || 'cpu').toUpperCase()}`;
      if (readyBadge) {
        readyBadge.textContent = '模型已就绪';
        readyBadge.className = 'badge ok';
      }
      if (modelLoaded) {
        modelLoaded.textContent = '已加载';
        modelLoaded.style.color = '';
      }
      setButtonsDisabled(false);
      box.style.display = 'none';
      box.innerHTML = '';
      return;
    }

    if (healthText) healthText.textContent = '服务正常 · 模型加载中';
    if (readyBadge) {
      readyBadge.textContent = '模型加载中';
      readyBadge.className = 'badge processing';
    }
    if (modelLoaded) {
      modelLoaded.textContent = '加载中 / 等待加载';
      modelLoaded.style.color = '';
    }
    setButtonsDisabled(true);
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

  // The backend already stores tts_tasks.error, but the original table hid it.
  // Keep the existing table layout and append a compact failure-details block.
  if (typeof window.taskTable === 'function') {
    const originalTaskTable = window.taskTable;
    window.taskTable = function project5TaskTableWithErrors(items) {
      const base = originalTaskTable(items);
      const failed = (items || []).filter((item) => item?.status === 'failed' && item?.error);
      if (!failed.length) return base;

      const details = failed.slice(0, 10).map((item) => `
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
