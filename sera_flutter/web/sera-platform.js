/* Browser capability bridge. Authentication tokens never enter this module/SW. */
(() => {
  'use strict';
  const diagnostics = [];
  let currentScope = 'signed-out';
  let scopeReady = false;
  let scopeVersion = 0;
  let pushQueue = Promise.resolve();
  const queuedPush = operation => {
    const next = pushQueue.catch(() => {}).then(operation);pushQueue = next;return next;
  };
  const assertScope = (scope, version) => {
    if (!scopeReady || scope !== currentScope || version !== scopeVersion) throw fail('stale_account', '账户已切换，已停止旧账户的推送操作。');
  };
  let pcm = null;
  let registrationPromise = null;
  const fail = (code, message) => Object.assign(new Error(message), {code});
  const remember = (code, message) => {
    diagnostics.push({code, message: String(message), at: Date.now()});
    if (diagnostics.length > 50) diagnostics.shift();
  };
  async function registerWorker() {
    if (!isSecureContext || !('serviceWorker' in navigator)) throw fail('unsupported', '后台提醒需要 HTTPS/localhost 与支持 Service Worker 的浏览器。');
    if (!registrationPromise) registrationPromise = navigator.serviceWorker.register(new URL('sera-sw.js', document.baseURI), {
      scope: new URL('.', document.baseURI).pathname,
      updateViaCache: 'none',
    }).then(async reg => {
      if (reg.installing || reg.waiting || !reg.active) await new Promise((resolve, reject) => {
        const worker = reg.installing || reg.waiting;
        if (!worker) {reject(fail('worker_failed', '后台工作线程没有安装。'));return;}
        const timeout = setTimeout(() => reject(fail('worker_timeout', '后台工作线程安装超时。')), 15000);
        const check = () => {
          if (worker.state === 'activated') {clearTimeout(timeout);resolve();}
          if (worker.state === 'redundant') {clearTimeout(timeout);reject(fail('worker_failed', '后台工作线程安装失败。'));}
        };
        worker.addEventListener('statechange', check);
        check();
      });
      return reg;
    }).catch(error => {registrationPromise = null;remember(error.code || 'worker_failed', error.message);throw error;});
    return registrationPromise;
  }
  async function messageWorker(message, timeoutMs = 5000) {
    const reg = await registerWorker();
    const worker = reg.active;
    if (!worker) throw fail('worker_failed', '后台工作线程尚未激活。');
    return new Promise((resolve, reject) => {
      const channel = new MessageChannel();
      const timeout = setTimeout(() => {channel.port1.close();reject(fail('worker_timeout', '后台工作线程没有应答。'));}, timeoutMs);
      channel.port1.onmessage = event => {
        clearTimeout(timeout);channel.port1.close();
        if (event.data?.ok) resolve(event.data);
        else reject(fail('worker_failed', event.data?.error || '后台状态保存失败。'));
      };
      worker.postMessage(message, [channel.port2]);
    });
  }
  async function prepareOfflineShell() {
    try {
      const result = await messageWorker({type: 'prepare-shell'}, 20000);
      if (!result.ready) throw fail('offline_cache_unavailable', '离线资源暂未准备完成，请联网后刷新重试。');
      if (result.warning) remember('offline_cache_update_pending', result.warning);
      return result;
    } catch (error) {
      remember(error.code || 'offline_cache_failed', error.message);
      throw error;
    }
  }
  async function assertPersistedScope(scope, version) {
    assertScope(scope, version);
    const reply = await messageWorker({type: 'get-scope'});
    assertScope(scope, version);
    if (reply.activeScope !== scope) {
      scopeReady = false;
      throw fail('stale_account', '其他标签页已切换账户，已停止此页面的旧账户提醒，请重新初始化账户。');
    }
  }
  function setAccountScope(scope) {
    const next = String(scope || 'signed-out');
    const version = ++scopeVersion;scopeReady = false;
    return queuedPush(async () => {try {
      if (version !== scopeVersion) throw fail('stale_account', '账户已切换，旧初始化已取消。');
      if (next !== currentScope) await stopPcm(true);
      if (version !== scopeVersion) throw fail('stale_account', '账户已切换，旧初始化已取消。');
      const memoryPrevious = currentScope;currentScope = next;
      // Persisted SW identity survives a closed page; in-memory signed-out
      // cannot identify the previous owner of an existing Push subscription.
      const reply = await messageWorker({type: 'set-scope', scope: next});
      const previous = reply.previousScope || memoryPrevious;
      const reg = await registerWorker();
      for (const item of await reg.getNotifications()) if (item.data?.sera && item.data.scope !== next) item.close();
      if (previous !== next) {
        const old = await reg.pushManager.getSubscription();
        if (old && !(await old.unsubscribe())) throw fail('unsubscribe_failed', '旧账户浏览器推送订阅未能取消，请重试后再开启后台提醒。');
      }
      if (version === scopeVersion) scopeReady = true;
    } catch (error) {remember(error.code || 'scope_update_failed', error.message);throw error;}});
  }
  async function subscription() {
    if (!('PushManager' in globalThis)) return null;
    if (!scopeReady) throw fail('scope_unavailable', '账户推送隔离尚未确认，请重试账户初始化。');
    const scope = currentScope, version = scopeVersion;
    await assertPersistedScope(scope, version);
    const reg = await registerWorker();
    await assertPersistedScope(scope, version);
    const sub = await reg.pushManager.getSubscription();await assertPersistedScope(scope, version);
    return sub?.toJSON() || null;
  }
  async function subscribePush(publicKey) {
    if (currentScope === 'signed-out') throw fail('not_authenticated', '请先登录，再开启后台提醒。');
    if (!scopeReady) throw fail('scope_unavailable', '账户推送隔离尚未确认，请重试账户初始化。');
    if (!('PushManager' in globalThis)) throw fail('push_unsupported', '当前浏览器不支持 Web Push；iOS 需把站点添加到主屏幕并从该应用打开。');
    if (Notification.permission !== 'granted') throw fail('notification_denied', '请先允许浏览器通知。');
    const scope = currentScope, version = scopeVersion;
    return queuedPush(async () => {
    await assertPersistedScope(scope, version);
    const reg = await registerWorker();
    await assertPersistedScope(scope, version);
    const value = String(publicKey).replace(/-/g, '+').replace(/_/g, '/');
    let bytes;
    try {const raw = atob(value + '='.repeat((4 - value.length % 4) % 4));bytes = Uint8Array.from(raw, c => c.charCodeAt(0));}
    catch (_) {throw fail('invalid_vapid_key', '服务端 VAPID 公钥格式无效。');}
    if (bytes.length !== 65 || bytes[0] !== 4) throw fail('invalid_vapid_key', '服务端 VAPID 公钥不是未压缩 P-256 公钥。');
    let sub = await reg.pushManager.getSubscription();
    await assertPersistedScope(scope, version);
    if (sub) {
      const oldKey = sub.options.applicationServerKey;
      if (oldKey && (new Uint8Array(oldKey)).some((b, i) => b !== bytes[i])) {await sub.unsubscribe();await assertPersistedScope(scope, version);sub = null;}
    }
    if (!sub) sub = await reg.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: bytes});
    await assertPersistedScope(scope, version);
    return sub.toJSON();
    });
  }
  async function unsubscribePush() {
    if (!('PushManager' in globalThis)) return;
    const scope = currentScope, version = scopeVersion;
    return queuedPush(async () => {
    await assertPersistedScope(scope, version);
    const reg = await registerWorker();
    await assertPersistedScope(scope, version);
    const sub = await reg.pushManager.getSubscription();
    await assertPersistedScope(scope, version);
    if (sub && !(await sub.unsubscribe())) throw fail('unsubscribe_failed', '浏览器没有取消推送订阅，请重试。');
    const notifications = await reg.getNotifications();
    await assertPersistedScope(scope, version);
    for (const notification of notifications) if (notification.data?.sera && notification.data.scope === scope) notification.close();
    });
  }
  async function showNotification(title, body, route, id) {
    if (Notification.permission !== 'granted') throw fail('notification_denied', '浏览器通知权限未开启。');
    const scope = currentScope, version = scopeVersion;await assertPersistedScope(scope, version);
    const reg = await registerWorker();
    await assertPersistedScope(scope, version);
    await reg.showNotification(String(title), {body: String(body), icon: new URL('sera-icon.svg', document.baseURI).href,
      tag: `sera:${scope}:${id || 'test'}`, data: {sera: true, scope, route: route || '/27'}});
  }
  async function startPcm(onFrame, onError, onEnd) {
    if (pcm) throw fail('recording_busy', '已有实时录音正在运行。');
    if (!isSecureContext || !navigator.mediaDevices?.getUserMedia || !globalThis.AudioWorkletNode) throw fail('audio_unsupported', '实时语音需要 HTTPS/localhost、麦克风与 AudioWorklet 支持。');
    const state = {stream: null, context: null, node: null, source: null, gain: null, bytes: 0,
      onEnd, stopAck: null, stopping: false, cancelled: false, ended: false, failed: false};
    pcm = state;
    const ensureActive = () => {if (state.cancelled || pcm !== state) throw fail('cancelled', '已取消实时录音。');};
    try {
      const stream = await navigator.mediaDevices.getUserMedia({audio: {channelCount: 1, echoCancellation: true, noiseSuppression: true}, video: false});
      state.stream = stream;ensureActive();
      const context = new AudioContext({latencyHint: 'interactive'});state.context = context;
      await context.audioWorklet.addModule(new URL('sera-pcm-worklet.js', document.baseURI));
      ensureActive();
      const node = new AudioWorkletNode(context, 'sera-pcm');
      const source = context.createMediaStreamSource(stream);
      const gain = context.createGain();gain.gain.value = 0;
      Object.assign(state, {node, source, gain});
      node.port.onmessage = ({data}) => {
        if (data?.type === 'stopped') {state.stopAck?.();return;}
        if (data?.type === 'pcm' && data.bytes && pcm === state && !state.cancelled) {
          state.bytes += data.bytes.byteLength;
          if (state.bytes > 16000 * 2 * 60) {stopPcm(false).catch(error => onError(error.message));return;}
          onFrame(new Uint8Array(data.bytes));
        }
      };
      node.onprocessorerror = () => {onError('音频处理器失败，请重新开始录音。');stopPcm(true).catch(() => {});};
      source.connect(node);node.connect(gain);gain.connect(context.destination);
      await context.resume();
      ensureActive();
      if (context.state !== 'running') throw fail('audio_suspended', '浏览器没有启动音频处理，请点击录音按钮重试。');
      state.limit = setTimeout(() => stopPcm(false).catch(error => onError(error.message)), 60000);
      return {sampleRate: 16000, channels: 1, encoding: 'pcm_s16le'};
    } catch (error) {
      // Initialization failure must reject before Dart closes its stream.
      // Sending a normal end here would swallow microphone_denied and make
      // the UI finish an ASR session that never received any audio.
      state.failed = true;
      if (pcm === state) await stopPcm(true);
      state.stream?.getTracks().forEach(track => track.stop());
      if (state.context?.state !== 'closed') await state.context?.close().catch(() => {});
      const denied = ['NotAllowedError', 'PermissionDeniedError', 'SecurityError'].includes(error.name);
      throw fail(denied ? 'microphone_denied' : error.code || 'microphone_unavailable',
        denied ? '麦克风权限未开启，请在浏览器网站设置中允许，或改用文字输入。' : error.message || '无法打开麦克风。');
    }
  }
  async function stopPcm(cancel = false) {
    const state = pcm;
    if (!state) return;
    if (state.stopping) return state.finished;
    state.stopping = true;state.cancelled = !!cancel;clearTimeout(state.limit);
    state.finished = (async () => {
      if (state.node) await new Promise(resolve => {state.stopAck = resolve;state.node.port.postMessage({type: 'stop', cancel: !!cancel});setTimeout(resolve, 300);});
      state.source?.disconnect();state.node?.disconnect();state.gain?.disconnect();
      state.stream?.getTracks().forEach(track => track.stop());
      if (state.context?.state !== 'closed') await state.context?.close();
      if (pcm === state) pcm = null;
      if (!state.ended) {state.ended = true;if (!state.failed) state.onEnd();}
    })();
    return state.finished;
  }
  globalThis.seraPlatform = {registerWorker, prepareOfflineShell, setAccountScope, subscription, subscribePush, unsubscribePush, showNotification, startPcm, stopPcm,
    diagnostics: () => [...diagnostics], messageWorker};
  window.addEventListener('load', () => {registerWorker().catch(() => {});});
  window.addEventListener('pagehide', () => {stopPcm(true).catch(() => {});});
})();
