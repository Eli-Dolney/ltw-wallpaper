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

  const style = document.createElement('style');
  style.textContent = '.ltw-paused * { animation-play-state: paused !important; }';
  (document.head || document.documentElement).appendChild(style);
  if (L.runtime.paused) document.documentElement.classList.add('ltw-paused');
})();
