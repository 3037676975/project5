(() => {
  const VERSION = 'project5-public-api-base-v1';
  const baseUrl = window.location.origin.replace(/\/$/, '');

  function copyFallback(text) {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.left = '-9999px';
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand('copy');
    area.remove();
    return ok;
  }

  async function copyText(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (_) {}
    return copyFallback(text);
  }

  function notify(text) {
    if (typeof window.toast === 'function') window.toast(text);
    else console.log(text);
  }

  function replacePlaceholders(root) {
    if (!root) return;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const nodes = [];
    let node;
    while ((node = walker.nextNode())) nodes.push(node);

    for (const textNode of nodes) {
      const before = textNode.nodeValue || '';
      const after = before
        .replaceAll('PROJECT5_BASE_URL=http://YOUR_PROJECT5_HOST', `PROJECT5_BASE_URL=${baseUrl}`)
        .replaceAll('http://YOUR_PROJECT5_HOST', baseUrl)
        .replaceAll('YOUR_PROJECT5_HOST', baseUrl);
      if (after !== before) textNode.nodeValue = after;
    }
  }

  function installAddressCard(root) {
    if (!root || document.getElementById('p5PublicApiBaseCard')) return;
    const card = document.createElement('div');
    card.id = 'p5PublicApiBaseCard';
    card.setAttribute('data-version', VERSION);
    card.innerHTML = `
      <div style="margin:14px 0 18px;padding:16px;border:1px solid #bfdbfe;border-radius:14px;background:linear-gradient(135deg,#eff6ff,#ffffff)">
        <div style="font-size:12px;font-weight:800;color:#2563eb;margin-bottom:8px">当前 Project5 公网请求地址</div>
        <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
          <code id="p5PublicBaseValue" style="font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:13px;background:#0f172a;color:#dbeafe;padding:9px 11px;border-radius:9px;word-break:break-all">${baseUrl}</code>
          <button id="p5CopyPublicBase" class="btn small secondary" type="button">复制请求地址</button>
        </div>
        <div style="margin-top:10px;color:#64748b;font-size:12px;line-height:1.7">
          以后所有公开接口都从这个地址开始。例如：<br>
          <code>${baseUrl}/v1/audio/speech</code><br>
          <code>${baseUrl}/v1/tasks/{task_id}</code><br>
          <code>${baseUrl}/v1/voices?engine=edge</code>
        </div>
      </div>`;

    const hero = root.querySelector?.('.p5-api-hero');
    if (hero && hero.parentNode) hero.parentNode.insertBefore(card, hero.nextSibling);
    else root.prepend(card);

    document.getElementById('p5CopyPublicBase')?.addEventListener('click', async () => {
      notify(await copyText(baseUrl) ? 'Project5 请求地址已复制' : '复制失败，请手动复制');
    });
  }

  function upgradeBackendGuide() {
    const root = document.getElementById('p5ApiDocsV2');
    if (!root) return false;
    replacePlaceholders(root);
    installAddressCard(root);

    const aiBlock = document.getElementById('p5AiContextBlock');
    if (aiBlock) replacePlaceholders(aiBlock);

    document.addEventListener('click', async (event) => {
      const target = event.target;
      if (!(target instanceof Element)) return;

      if (target.closest('#p5CopyAiContext')) {
        const block = document.getElementById('p5AiContextBlock');
        if (!block) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        const text = block.textContent || '';
        notify(await copyText(text) ? '已复制给 AI，里面已包含当前 Project5 请求地址' : '复制失败，请手动选择代码块');
      }

      if (target.closest('#p5CopyCurl')) {
        const btn = target.closest('#p5CopyCurl');
        const code = btn?.parentElement?.nextElementSibling;
        if (!code) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        const text = (code.textContent || '')
          .replaceAll('$PROJECT5_BASE_URL', baseUrl)
          .replaceAll('http://YOUR_PROJECT5_HOST', baseUrl);
        notify(await copyText(text) ? 'curl 示例已复制，已经带当前请求地址' : '复制失败，请手动选择代码块');
      }
    }, true);

    return true;
  }

  function upgradeStandaloneGuide() {
    if (!/\/static\/api-guide-zh\.html$/.test(window.location.pathname)) return false;
    const root = document.body;
    replacePlaceholders(root);
    if (!document.getElementById('p5PublicApiBaseCard')) {
      const firstMain = document.querySelector('main, article, .wrap, .container, body');
      installAddressCard(firstMain || root);
    }
    return true;
  }

  let tries = 0;
  const timer = setInterval(() => {
    tries += 1;
    const done = upgradeBackendGuide() || upgradeStandaloneGuide();
    if (done || tries > 40) clearInterval(timer);
  }, 200);

  upgradeBackendGuide();
  upgradeStandaloneGuide();
})();
