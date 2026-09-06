(() => {
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

  async function pollExactTask(taskId, target, startedAt) {
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
      const stage = task.status === 'queued' ? '任务已提交，等待推理' : '模型正在生成语音';
      const hint = task.status === 'queued'
        ? `任务 ${taskId} 已进入队列，不需要重复点击`
        : `任务 ${taskId} 正在服务器后台执行`;
      const p = task.status === 'queued'
        ? Math.min(25, 5 + Math.floor(elapsedSec / 2))
        : Math.min(94, 30 + Math.floor(elapsedSec / 3));
      setProgress(p, stage, hint);
      $('#singleElapsed').textContent = `已用时 ${elapsedSec} 秒`;

      await sleep(1500);
    }
    throw new Error(`任务 ${taskId} 等待超过 15 分钟，请在“生成任务”中查看最终状态`);
  }

  window.synthesize = async function(voice, button, target = '#generateResult') {
    const text = $('#ttsText').value.trim();
    if (!text) {
      toast('请先输入试听文本');
      return null;
    }

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
      setProgress(8, '提交生成任务', '请求只负责创建任务，不再等待整段语音生成');
      const accepted = await adminApi('/admin/speech', {
        method: 'POST',
        body: JSON.stringify({ input: text, voice, speed: spd })
      });

      if (!accepted?.id) throw new Error('服务器没有返回任务 ID');

      setProgress(12, '任务创建成功', `任务 ${accepted.id}，开始查询真实状态`);
      const completed = await pollExactTask(accepted.id, target, started);

      progressDone();
      audioResult(completed, false, target);
      toast('语音生成成功');
      loadDashboard();
      return completed;
    } catch (e) {
      clearInterval(progressTimer);
      setProgress(100, '生成失败', e.message || '未知错误');
      $('#singleRing').style.background = 'conic-gradient(var(--red) 100%,#e5e7eb 0)';
      $(target).innerHTML = `<div class="result" style="color:#b91c1c">
        <b>生成失败</b>
        <div style="margin-top:6px">${String(e.message || e)}</div>
        <div class="muted" style="margin-top:8px">系统已经记录真实任务状态，不会再无限显示“正在找回”。</div>
      </div>`;
      toast('语音生成失败');
      loadDashboard();
      return null;
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = old;
      }
    }
  };

  console.info('[Project5] durable async task client v2 loaded');
})();