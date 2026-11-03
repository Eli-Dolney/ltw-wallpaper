// Ltw Wallpaper scene helper. Include it in every scene:  <script src="_ltw.js"></script>
// Then after CONFIG/SCHEMA:   LTW.setup(CONFIG, SCHEMA, { rebuild, change(key, value) })
// Works in a plain browser too (window.LTW is created with no settings).
(function () {
  const L = window.LTW = window.LTW || {};
  L.settings = L.settings || {};
  L.runtime = Object.assign({ paused: false, maxFps: 0 }, L.runtime || {});

  const getPath = (o, k) => k.split('.').reduce((a, p) => (a == null ? a : a[p]), o);
  const setPath = (o, k, v) => {
    const p = k.split('.'), last = p.pop(); let t = o;
    for (const q of p) { if (t[q] == null || typeof t[q] !== 'object') t[q] = {}; t = t[q]; }
    t[last] = v;
  };
  function coerce(field, v) {
    if (!field) return v;
    if (field.type === 'list' && typeof v === 'string') return v.split('\n').map(s => s.trim()).filter(Boolean);
    if (field.type === 'json' && typeof v === 'string') { try { return JSON.parse(v); } catch (e) { return undefined; } }
    if (field.type === 'range' && typeof v === 'string') return parseFloat(v);
    if (field.type === 'toggle' && typeof v === 'string') return v === 'true';
    return v;
  }

  // Merge saved settings into CONFIG (in place) and remember the defaults.
  L.setup = function (config, schema, hooks) {
    L.config = config; L.schema = schema || null; L.hooks = hooks || {};
    L.defaults = JSON.parse(JSON.stringify(config));
    L.fields = {};
    for (const g of (schema && schema.groups) || []) for (const f of g.fields || []) L.fields[f.key] = f;
    for (const [k, v] of Object.entries(L.settings)) {
      const c = coerce(L.fields[k], v);
      if (c !== undefined) setPath(config, k, c);
    }
    return config;
  };
  L.describe = () => ({ schema: L.schema, defaults: L.defaults, config: L.config });
  L.get = (k) => getPath(L.config, k);

  // Live changes from the Customize panel.
  window.__ltwApply = function (patch) {
    if (!L.config) return;
    let rebuild = false;
    for (const [k, v] of Object.entries(patch || {})) {
      const f = L.fields[k]; const c = coerce(f, v);
      if (c === undefined) continue;
      setPath(L.config, k, c);
      if (f && f.rebuild) rebuild = true;
      if (L.hooks.change) { try { L.hooks.change(k, getPath(L.config, k)); } catch (e) { console.error(e); } }
    }
    if (rebuild && L.hooks.rebuild) L.hooks.rebuild();
  };

  // requestAnimationFrame gate: hold frames while paused (window covered, screen asleep, locked)
  // and enforce a global fps ceiling. Scenes keep calling requestAnimationFrame as usual.
  const nativeRAF = window.requestAnimationFrame.bind(window);
  let queue = [], scheduled = false, nextId = 1, lastFlush = 0;
  function flush(ts) {
    scheduled = false;
    if (L.runtime.paused) return;
    const minMs = L.runtime.maxFps > 0 ? 1000 / L.runtime.maxFps - 1 : 0;
    if (ts - lastFlush < minMs) { schedule(); return; }
    lastFlush = ts;
    const q = queue; queue = [];
    for (const e of q) { try { e.cb(ts); } catch (err) { console.error(err); } }
  }
  function schedule() {
    if (!scheduled && !L.runtime.paused && queue.length) { scheduled = true; nativeRAF(flush); }
  }
  window.requestAnimationFrame = function (cb) { const id = nextId++; queue.push({ id, cb }); schedule(); return id; };
  window.cancelAnimationFrame = function (id) { queue = queue.filter(e => e.id !== id); };

  window.__ltwRuntime = function (r) {
    Object.assign(L.runtime, r || {});
    document.documentElement.classList.toggle('ltw-paused', !!L.runtime.paused);
    document.querySelectorAll('video').forEach(v => { if (L.runtime.paused) v.pause(); else v.play().catch(() => {}); });
    if (!L.runtime.paused) schedule();
  };
  // Pointer: the app pushes the mouse position (normalized -1..1 per screen) at ~30 Hz for scenes whose
  // SCHEMA has `pointer: true`. In a plain browser the mouse is used directly. Read LTW.pointer.x/y.
  L.pointer = { x: 0, y: 0, live: false };
  window.__ltwPointer = function (x, y) { L.pointer.x = x; L.pointer.y = y; L.pointer.live = true; };
  if (!L.scenesPath) addEventListener('mousemove', e => {
    __ltwPointer((e.clientX / innerWidth) * 2 - 1, 1 - (e.clientY / innerHeight) * 2);
  });

  // Audio: the app taps system output (needs "System Audio Recording") and pushes levels at ~30 Hz for
  // scenes whose SCHEMA has `audio: true`: level/bass/mid/treble 0..1, 16 log-spaced bands and a beat flag.
  // Until the first real frame arrives (browser preview, or no permission) a gentle synthetic groove runs
  // so audio scenes never look dead.
  L.audio = { level: 0, bass: 0, mid: 0, treble: 0, beat: 0, bands: new Array(16).fill(0), live: false };
  let lastAudio = 0;
  window.__ltwAudio = function (a) {
    const A = L.audio; A.live = true; lastAudio = performance.now();
    A.level = a.level; A.bass = a.bass; A.mid = a.mid; A.treble = a.treble; A.beat = a.beat || 0;
    if (a.bands) for (let i = 0; i < 16; i++) A.bands[i] = a.bands[i] || 0;
  };
  L.audioTick = function (now) {   // scenes call this once per frame before reading LTW.audio
    const A = L.audio;
    if (A.live && now - lastAudio > 1500) A.live = false;   // feed stopped: fade to the demo groove
    if (A.live) return;
    const t = now / 1000, bpm = 96, beatPhase = (t * bpm / 60) % 1;
    const kick = Math.pow(1 - beatPhase, 6);
    A.bass = 0.25 + 0.6 * kick;
    A.mid = 0.3 + 0.2 * Math.sin(t * 1.7) + 0.15 * Math.sin(t * 5.3);
    A.treble = 0.2 + 0.15 * Math.sin(t * 3.1 + 1) + 0.1 * (Math.sin(t * 23) > 0.6 ? 1 : 0);
    A.level = 0.3 + 0.4 * kick + 0.1 * Math.sin(t * 0.7);
    A.beat = beatPhase < 0.08 ? 1 : 0;
    for (let i = 0; i < 16; i++) {
      const f = i / 15;
      A.bands[i] = Math.max(0, Math.min(1, (1 - f) * A.bass * 0.9 + Math.sin(t * (2 + i * 0.7) + i) * 0.15 + 0.25 * Math.exp(-Math.pow((f - 0.5) * 4, 2)) * A.mid + f * A.treble * 0.6));
    }
  };

  // System stats: the app pushes a sample every 1–10 s (Customize → App → Monitor) to scenes whose SCHEMA
  // has `stats: true`. Read LTW.stats (null until the first sample) or pass hooks.stats(sample) to LTW.setup.
  // In a plain browser, or before the first real sample, a plausible demo sample is generated every 2 s.
  L.stats = null; L.statsLive = false;
  let statsAt = 0;
  window.__ltwStats = function (s) {
    L.stats = s; L.statsLive = true; statsAt = performance.now();
    if (L.hooks && L.hooks.stats) { try { L.hooks.stats(s); } catch (e) { console.error(e); } }
  };
  (function demoStats() {
    let t = 0, cpu = 0.18, gpu = 0.12, down = 2e5, up = 4e4, bat = 0.78;
    const cores = 10;
    setInterval(() => {
      if (L.scenesPath) return;                                            // inside the app the real feed drives this
      if (L.statsLive && performance.now() - statsAt < 15000) return;
      if (!L.schema || !L.schema.stats) return;                              // only scenes that asked for stats
      t += 2;
      cpu = Math.max(0.03, Math.min(0.97, cpu + (Math.random() - 0.5) * 0.12 + (Math.sin(t / 40) * 0.01)));
      gpu = Math.max(0.02, Math.min(0.95, gpu + (Math.random() - 0.5) * 0.1));
      down = Math.max(0, down * 0.8 + Math.random() * 1.2e6 * (Math.random() < 0.15 ? 4 : 1) * 0.2);
      up = Math.max(0, up * 0.85 + Math.random() * 2e5 * 0.15);
      bat = Math.max(0.05, bat - 0.0004);
      const total = 32e9, app = 9.6e9 + cpu * 2e9, wired = 2.9e9, comp = 1.4e9, cache = 6e9;
      const coresArr = Array.from({ length: cores }, (_, i) => Math.max(0, Math.min(1, cpu * (i < 4 ? 1.6 : 0.6) + (Math.random() - 0.5) * 0.3)));
      __ltwStats({
        cpu, cpuUser: cpu * 0.7, cpuSystem: cpu * 0.3, cores: coresArr, loadAvg: [cpu * cores * 0.6, cpu * cores * 0.5, cpu * cores * 0.45],
        memUsed: app + wired + comp, memTotal: total, memApp: app, memWired: wired, memCompressed: comp, memCached: cache, swapUsed: 0, swapTotal: 0,
        battery: bat, charging: false, pluggedIn: false, timeRemaining: Math.round(bat * 620), cycles: 139, health: 0.93, watts: -(5 + cpu * 18), batteryTemp: 30 + cpu * 6,
        gpu, diskRead: Math.random() * 4e6, diskWrite: Math.random() * 1.5e6, diskFree: 212e9, diskTotal: 994e9,
        netIn: down, netOut: up, netTotalIn: 48e9 + t * down, netTotalOut: 9e9 + t * up, netInterface: 'en0',
        thermal: cpu > 0.9 ? 'fair' : 'nominal', uptime: 86400 * 3 + 4000 + t, processes: 612 + Math.round(Math.random() * 6),
        self: { cpu: 0.02 + Math.random() * 0.03, mem: 1.1e8 },
        top: [['WindowServer', 0.18], ['Claude', 0.12 + cpu * 0.3], ['Safari', 0.09], ['WebContent', 0.07 + gpu * 0.1], ['kernel_task', 0.05], ['Music', 0.03]].map(([name, c], i) => ({ pid: 100 + i, name, cpu: c, mem: 2e8 + i * 1.3e8 })),
      });
      L.statsLive = false;
    }, 2000);
  })();

  const style = document.createElement('style');
  style.textContent = '.ltw-paused * { animation-play-state: paused !important; }';
  (document.head || document.documentElement).appendChild(style);
  if (L.runtime.paused) document.documentElement.classList.add('ltw-paused');
})();
