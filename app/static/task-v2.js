(() => {
  'use strict';

  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const selectedEngine = () => (typeof window.project5CurrentEngine === 'function' ? window.project5CurrentEngine() : 'kokoro');
  const engineLabel = engine => engine === 'edge' ? 'Edge 在线' : 'Kokoro 本地';

  async function pollExactTask(taskId, startedAt) {
    const maxWaitMs = 15 * 60 * 1000;
    while (Date.now() - startedAt < maxWaitMs) {
      const task = await adminApi(`/admin/tasks/${encodeURIComponent(taskId)}`);

      if (task.status === 'completed') {
        if (!task.audio_url) throw new Error('任务已完成，但没有音频地址');
        return task;
      }
      if (task.status === 'failed') {
        throw new Error(task.error || '语音生成失败');
      }

      const elapsedSec = Math.round((Date.now() - startedAt) / 1000);
      const label = engineLabel(task.engine || selectedEngine());
      const stage = task.status === 'queued' ? `${label} · 等待生成` : `${label} · 正在生成`;
      const hint = task.status === 'queued'
        ? `任务 ${taskId} 已进入队列，不需要重复点击`
        : `任务 ${taskId} 正在服务器后台执行`;
      const p = task.status === 'queued'
        ? Math.min(25, 5 + Math.floor(elapsedSec / 2))
        : Math.min(94, 30 + Math.floor(elapsedSec / 3));
      setProgress(p, stage, hint);
      $('#singleElapsed').textContent = `已用时 ${elapsedSec} 秒`;

      await sleep(1200);
    }
    throw new Error(`任务 ${taskId} 等待超过 15 分钟，请在“生成任务”中查看最终状态`);
  }

  function renderCompleted(task, target) {
    const label = engineLabel(task.engine || selectedEngine());
    const seconds = task.elapsed_ms ? `${(task.elapsed_ms / 1000).toFixed(2)} 秒` : '-';
    $(target).innerHTML = `<div class="audio-result">
      <div class="audio-head"><div><b>${label} · 生成成功</b><div class="muted">${task.voice} · ${task.speed}x · 生成耗时 ${seconds}</div></div><span class="badge ok">成功</span></div>
      <audio controls autoplay src="${task.audio_url}"></audio>
      <div class="audio-actions"><a class="btn small" href="${task.audio_url}" download>下载音频</a><button class="btn small secondary" onclick="showPage('files')">去音频文件</button><button class="btn small secondary" onclick="showPage('tasks')">去生成任务</button></div>
      <div class="muted" style="margin-top:8px">任务 ${task.id} · ${task.audio_filename || ''}</div>
    </div>`;
    const audio = document.querySelector(`${target} audio`);
    audio?.play().catch(() => {});
  }

  window.synthesize = async function synthesize(voice, button, target = '#generateResult') {
    const text = $('#ttsText').value.trim();
    if (!text) {
      toast('请先输入试听文本');
      return null;
    }

    const engine = selectedEngine();
    const spd = speed();
    const started = Date.now();
    const old = button?.textContent || '';

    if (button) {
      button.disabled = true;
      button.textContent = '生成中…';
    }

    progressBegin(voice);
    $(target).innerHTML = '';

    try {
      setProgress(8, `提交 ${engineLabel(engine)} 任务`, '接口只负责创建任务，不再等待整段语音生成');
      const accepted = await adminApi('/admin/speech', {
        method: 'POST',
        body: JSON.stringify({ input: text, engine, voice, speed: spd })
      });

      if (!accepted?.id) throw new Error('服务器没有返回任务 ID');

      setProgress(12, '任务创建成功', `任务 ${accepted.id}，开始查询真实状态`);
      const completed = await pollExactTask(accepted.id, started);

      progressDone();
      renderCompleted(completed, target);
      toast(`${engineLabel(completed.engine || engine)}生成成功`);
      loadDashboard();
      return completed;
    } catch (e) {
      clearInterval(progressTimer);
      setProgress(100, '生成失败', e.message || '未知错误');
      $('#singleRing').style.background = 'conic-gradient(var(--red) 100%,#e5e7eb 0)';
      $(target).innerHTML = `<div class="result" style="color:#b91c1c">
        <b>${engineLabel(engine)} · 生成失败</b>
        <div style="margin-top:6px">${String(e.message || e)}</div>
        <div class="muted" style="margin-top:8px">系统已记录真实任务状态；可以直接切换另一个 TTS 引擎继续生成。</div>
      </div>`;
      toast('语音生成失败');
      loadDashboard();
      return null;
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = old;
      }
      if (typeof window.project5RefreshRuntime === 'function') window.project5RefreshRuntime();
    }
  };

  console.info('[Project5] dual-engine durable async task client loaded');
})();
