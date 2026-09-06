(() => {
  const FEATURE_VERSION = 'api-key-ui-v1';
  const STORAGE_KEY = 'project5_api_keys_local_v1';

  function notify(message) {
    if (typeof toast === 'function') toast(message);
    else console.log(message);
  }

  function esc(value) {
    return String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  }

  function readCache() {
    try {
      const data = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}');
      return data && typeof data === 'object' ? data : {};
    } catch (_) {
      return {};
    }
  }

  function writeCache(data) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(data)); }
    catch (_) {}
  }

  function rememberKey(id, key) {
    const cache = readCache();
    cache[String(id)] = key;
    writeCache(cache);
  }

  function forgetKey(id) {
    const cache = readCache();
    delete cache[String(id)];
    writeCache(cache);
  }

  async function copyText(text) {
    if (!text) throw new Error('没有可复制的完整 Key');
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return;
      }
    } catch (_) {}
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand('copy');
    ta.remove();
    if (!ok) throw new Error('浏览器没有允许自动复制');
  }

  function installCss() {
    if (document.getElementById('p5ApiKeyUiCss')) return;
    const style = document.createElement('style');
    style.id = 'p5ApiKeyUiCss';
    style.textContent = `
      #keys .panel{overflow:hidden}
      .p5-key-hero{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:18px;align-items:center;margin:-4px 0 20px;padding:22px;border:1px solid #dbeafe;border-radius:18px;background:linear-gradient(135deg,#eff6ff,#fff 62%,#f0fdf4)}
      .p5-key-hero h2{font-size:20px!important;margin:0 0 7px!important}.p5-key-hero p{margin:0;color:#64748b;font-size:13px;line-height:1.75}.p5-key-hero .btn{white-space:nowrap;padding:11px 17px}
      .p5-key-list{display:grid;gap:12px}.p5-key-card{display:grid;grid-template-columns:minmax(220px,1.35fr) minmax(240px,1.6fr) 100px 100px auto;gap:14px;align-items:center;padding:16px 17px;border:1px solid #e5eaf1;border-radius:15px;background:#fff;box-shadow:0 8px 24px rgba(15,23,42,.035)}
      .p5-key-card:hover{border-color:#cbd5e1;box-shadow:0 12px 28px rgba(15,23,42,.055)}.p5-key-name{font-weight:750;color:#172033}.p5-key-meta{margin-top:4px;color:#94a3b8;font-size:11px}.p5-key-value{display:flex;align-items:center;gap:8px;min-width:0}.p5-key-code{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;padding:8px 10px;border-radius:9px;background:#f8fafc;border:1px solid #e2e8f0;font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:#334155}.p5-key-actions{display:flex;gap:6px;justify-content:flex-end;flex-wrap:wrap}.p5-copy-primary{background:#eaf2ff!important;color:#1d4ed8!important}.p5-copy-primary:disabled{background:#f1f5f9!important;color:#94a3b8!important}.p5-key-label{display:none;color:#94a3b8;font-size:11px;margin-bottom:4px}
      .p5-key-modal{position:fixed;inset:0;z-index:180;display:flex;align-items:center;justify-content:center;padding:20px;background:rgba(15,23,42,.62);backdrop-filter:blur(8px)}.p5-key-modal-card{width:min(560px,100%);border-radius:22px;background:#fff;box-shadow:0 30px 90px rgba(15,23,42,.35);overflow:hidden}.p5-key-modal-head{padding:24px 26px 14px}.p5-key-modal-head h3{margin:0 0 7px;font-size:21px}.p5-key-modal-head p{margin:0;color:#64748b;font-size:13px;line-height:1.7}.p5-key-modal-body{padding:8px 26px 26px}.p5-key-modal-actions{display:flex;gap:10px;justify-content:flex-end;margin-top:18px;flex-wrap:wrap}.p5-key-result{margin-top:12px;padding:14px;border:1px solid #bbf7d0;border-radius:13px;background:#f0fdf4}.p5-key-result-label{font-size:12px;color:#166534;margin-bottom:7px}.p5-key-result-row{display:flex;gap:8px;align-items:stretch}.p5-key-result-code{flex:1;min-width:0;overflow:auto;padding:11px 12px;border-radius:10px;background:#0f172a;color:#dbeafe;font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap}.p5-key-warning{margin-top:11px;padding:10px 12px;border-radius:10px;background:#fff7ed;color:#9a3412;font-size:12px;line-height:1.65}
      @media(max-width:1050px){.p5-key-card{grid-template-columns:1fr 1.25fr 90px 90px}.p5-key-actions{grid-column:1/-1;justify-content:flex-start}}
      @media(max-width:760px){.p5-key-hero{grid-template-columns:1fr}.p5-key-card{grid-template-columns:1fr;gap:10px}.p5-key-label{display:block}.p5-key-actions{grid-column:auto}.p5-key-result-row{flex-direction:column}.p5-key-modal{padding:12px}.p5-key-modal-head,.p5-key-modal-body{padding-left:18px;padding-right:18px}}
    `;
    document.head.appendChild(style);
  }

  function ensureHero() {
    const panel = document.querySelector('#keys .panel');
    if (!panel || document.getElementById('p5KeyHero')) return;
    const originalTitle = panel.querySelector('.section-title');
    const originalDesc = panel.querySelector('p.muted');
    if (originalTitle) originalTitle.style.display = 'none';
    if (originalDesc) originalDesc.style.display = 'none';
    const hero = document.createElement('div');
    hero.id = 'p5KeyHero';
    hero.className = 'p5-key-hero';
    hero.innerHTML = `
      <div><h2>🔑 API 密钥</h2><p>给其他项目调用 Project5 的“通行证”。同一个 Key 可以同时调用 Kokoro 和 Edge。新 Key 创建后会完整展示，并提供一键复制。</p></div>
      <button class="btn" id="p5CreateKeyBtn">+ 创建 API Key</button>`;
    panel.insertBefore(hero, panel.firstChild);
    document.getElementById('p5CreateKeyBtn').onclick = openCreateModal;
  }

  function closeModal() {
    document.getElementById('p5KeyModal')?.remove();
  }

  function openCreateModal() {
    closeModal();
    const modal = document.createElement('div');
    modal.id = 'p5KeyModal';
    modal.className = 'p5-key-modal';
    modal.innerHTML = `
      <div class="p5-key-modal-card" role="dialog" aria-modal="true">
        <div class="p5-key-modal-head"><h3>创建 API Key</h3><p>给它起一个能看懂的名字，例如“Project4 视频系统”或“自动剪辑服务”。</p></div>
        <div class="p5-key-modal-body">
          <div class="field"><label>Key 名称</label><input class="input" id="p5KeyName" maxlength="80" placeholder="例如：Project4 视频系统" autocomplete="off"></div>
          <div id="p5KeyCreateResult"></div>
          <div class="p5-key-modal-actions"><button class="btn secondary" id="p5KeyCancel">取消</button><button class="btn" id="p5KeyCreateConfirm">创建密钥</button></div>
        </div>
      </div>`;
    document.body.appendChild(modal);
    const input = document.getElementById('p5KeyName');
    input.focus();
    document.getElementById('p5KeyCancel').onclick = closeModal;
    document.getElementById('p5KeyCreateConfirm').onclick = createKeyFromModal;
    input.onkeydown = e => { if (e.key === 'Enter') createKeyFromModal(); if (e.key === 'Escape') closeModal(); };
    modal.addEventListener('click', e => { if (e.target === modal) closeModal(); });
  }

  async function createKeyFromModal() {
    const input = document.getElementById('p5KeyName');
    const btn = document.getElementById('p5KeyCreateConfirm');
    const name = input?.value?.trim() || '';
    if (!name) { input?.focus(); notify('请先填写 Key 名称'); return; }
    btn.disabled = true;
    btn.textContent = '创建中…';
    try {
      const data = await adminApi('/admin/keys', { method: 'POST', body: JSON.stringify({ name }) });
      rememberKey(data.id, data.key);
      const host = document.getElementById('p5KeyCreateResult');
      host.innerHTML = `
        <div class="p5-key-result"><div class="p5-key-result-label">✅ 创建成功 · 完整 Key</div><div class="p5-key-result-row"><div class="p5-key-result-code" id="p5NewKeyValue">${esc(data.key)}</div><button class="btn p5-copy-primary" id="p5CopyNewKey">复制 Key</button></div></div>
        <div class="p5-key-warning">服务器仍然只保存 Key 的哈希值，不能反推出完整 Key。为了让列表里也能复制，这台浏览器会在本地保存你刚创建的完整 Key。换设备或清理浏览器数据后，旧 Key 将无法再次完整显示。</div>`;
      btn.textContent = '完成';
      btn.disabled = false;
      btn.onclick = () => { closeModal(); enhancedLoadKeys(); };
      document.getElementById('p5KeyCancel').style.display = 'none';
      document.getElementById('p5CopyNewKey').onclick = async () => {
        try { await copyText(data.key); notify('完整 API Key 已复制'); }
        catch (err) { notify(err.message || '复制失败'); }
      };
      await enhancedLoadKeys();
    } catch (err) {
      btn.disabled = false;
      btn.textContent = '创建密钥';
      notify(err.message || '创建失败');
    }
  }

  function renderKeyCard(k, cached) {
    const full = cached[String(k.id)] || '';
    const shown = full ? `${full.slice(0, 15)}••••••${full.slice(-5)}` : `${k.key_prefix}••••`;
    const copyDisabled = full ? '' : 'disabled';
    const copyTitle = full ? '复制完整 API Key' : '这个 Key 创建时未保存在当前浏览器，服务器无法恢复完整值';
    return `
      <div class="p5-key-card" data-key-id="${k.id}">
        <div><div class="p5-key-label">名称</div><div class="p5-key-name">${esc(k.name)}</div><div class="p5-key-meta">创建于 ${(k.created_at || '').replace('T',' ') || '-'}</div></div>
        <div><div class="p5-key-label">API Key</div><div class="p5-key-value"><div class="p5-key-code" title="${esc(copyTitle)}">${esc(shown)}</div><button class="btn small p5-copy-primary" data-key-action="copy" ${copyDisabled} title="${esc(copyTitle)}">复制</button></div></div>
        <div><div class="p5-key-label">调用次数</div><b>${Number(k.calls || 0).toLocaleString()}</b></div>
        <div><div class="p5-key-label">状态</div>${k.active ? '<span class="badge ok">启用</span>' : '<span class="badge fail">停用</span>'}</div>
        <div class="p5-key-actions"><button class="btn small secondary" data-key-action="toggle">${k.active ? '停用' : '启用'}</button><button class="btn small danger" data-key-action="delete">删除</button></div>
      </div>`;
  }

  async function enhancedLoadKeys() {
    ensureHero();
    const host = document.getElementById('keysTable');
    if (!host) return;
    const data = await adminApi('/admin/keys');
    const items = data.items || [];
    const cached = readCache();
    window.__p5KeyItems = Object.fromEntries(items.map(x => [String(x.id), x]));
    host.innerHTML = items.length ? `<div class="p5-key-list">${items.map(k => renderKeyCard(k, cached)).join('')}</div>` : '<div class="empty">还没有 API Key，点击上面的“创建 API Key”开始。</div>';
  }

  async function onKeyAction(e) {
    const button = e.target.closest('button[data-key-action]');
    if (!button) return;
    const card = button.closest('[data-key-id]');
    if (!card) return;
    const id = String(card.dataset.keyId);
    const item = window.__p5KeyItems?.[id];
    if (!item) return;
    const action = button.dataset.keyAction;
    button.disabled = true;
    try {
      if (action === 'copy') {
        const key = readCache()[id];
        if (!key) throw new Error('这个旧 Key 没有完整值，服务器只保存哈希，无法恢复');
        await copyText(key);
        notify('完整 API Key 已复制');
      } else if (action === 'toggle') {
        await adminApi('/admin/keys/' + encodeURIComponent(id), { method: 'PATCH', body: JSON.stringify({ active: !item.active }) });
        await enhancedLoadKeys();
      } else if (action === 'delete') {
        if (!confirm(`确认删除 API Key「${item.name}」？删除后调用它的项目会立即失效。`)) return;
        await adminApi('/admin/keys/' + encodeURIComponent(id), { method: 'DELETE' });
        forgetKey(id);
        await enhancedLoadKeys();
        notify('API Key 已删除');
      }
    } catch (err) {
      notify(err.message || '操作失败');
    } finally {
      if (button.isConnected) button.disabled = false;
    }
  }

  function install() {
    installCss();
    ensureHero();
    const original = document.getElementById('newKeyBtn');
    if (original) original.onclick = openCreateModal;
    const host = document.getElementById('keysTable');
    if (host && !host.dataset.p5KeyUiBound) {
      host.dataset.p5KeyUiBound = '1';
      host.addEventListener('click', onKeyAction);
    }
    try { loadKeys = enhancedLoadKeys; } catch (_) {}
    try { newKey = openCreateModal; } catch (_) {}
  }

  install();
  setTimeout(install, 300);
  setTimeout(() => {
    if (document.getElementById('keys')?.classList.contains('active') && typeof sessionToken !== 'undefined' && sessionToken) enhancedLoadKeys().catch(err => notify(err.message));
  }, 700);

  window.Project5ApiKeyUI = { version: FEATURE_VERSION, refresh: enhancedLoadKeys, openCreateModal };
})();