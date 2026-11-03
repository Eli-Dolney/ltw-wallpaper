// Animated background library for scenes that put something on top (clocks, widgets, text).
// Include after _ltw.js and _gl.js:
//   const bg = BG.create('aurora', canvas, { colors: ['#0b1020', '#14305a', '#1f8a7a', '#e0a85a'], speed: 1, intensity: 1, scale: 0.5 });
//   loop: bg.draw(now, dt);   on resize: bg.resize();   palette change: bg.setColors(list);   switching: bg.destroy()
// A canvas can hold only one kind of context, so hand BG.create a *fresh* <canvas> every time you switch backgrounds.
// opts is read live: change opts.speed / opts.intensity any time. BG.list is [{id, label}] for a select field.
const BG = (function () {
  const list = [], makers = {};
  const reg = (id, label, make) => { list.push({ id, label }); makers[id] = make; };
  const hex = (c) => { const s = (c || '#000000').replace('#', ''); return [0, 2, 4].map(i => parseInt(s.slice(i, i + 2), 16) || 0); };
  const rgba = (c, a) => { const [r, g, b] = hex(c); return `rgba(${r},${g},${b},${a})`; };
  const col = (o, i) => o.colors[Math.min(i, o.colors.length - 1)] || '#000000';
  const rand = (a, b) => a + Math.random() * (b - a);

  const NOISE = `
  float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  float n(vec2 p){ vec2 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);
    return mix(mix(h(i), h(i+vec2(1,0)), f.x), mix(h(i+vec2(0,1)), h(i+vec2(1,1)), f.x), f.y); }
  float fbm(vec2 p){ float v = 0.0, a = 0.5; mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < 5; i++) { v += a * n(p); p = m * p; a *= 0.5; } return v; }`;
  const HEAD = 'uniform float T, I; uniform vec3 C0, C1, C2, C3;\n' + NOISE;

  // ---- shader backgrounds: fs gets T (time, already scaled by speed), I (intensity), C0..C3, R ----
  function shader(fs) {
    return (canvas, o) => {
      const G = GL(canvas, HEAD + fs);
      let t = 0;
      const h = {
        draw(now, dt) { t += dt * (o.speed == null ? 1 : o.speed); G.uniform('T', t); G.uniform('I', o.intensity == null ? 1 : o.intensity); G.draw(); },
        resize() { G.resize(o.scale || 0.5); },
        setColors(c) { o.colors = c; G.colors('C', c, 4); },
        destroy() { const e = G.gl.getExtension('WEBGL_lose_context'); if (e) e.loseContext(); },
      };
      h.setColors(o.colors); h.resize();
      return h;
    };
  }
  // ---- 2D backgrounds: fn(ctx, o) returns {draw(w, h, now, dt), rebuild?(w, h)}; sizes in CSS px ----
  function canvas2d(maker) {
    return (canvas, o) => {
      const ctx = canvas.getContext('2d');
      let w = 0, hh = 0, dpr = 1;
      const impl = maker(ctx, o);
      const h = {
        draw(now, dt) { ctx.setTransform(dpr, 0, 0, dpr, 0, 0); impl.draw(w, hh, now, dt, (o.speed == null ? 1 : o.speed), (o.intensity == null ? 1 : o.intensity)); },
        resize() {
          dpr = Math.min(devicePixelRatio || 1, 2) * (o.scale2d || 1);
          w = innerWidth; hh = innerHeight;
          canvas.width = Math.max(1, Math.floor(w * dpr)); canvas.height = Math.max(1, Math.floor(hh * dpr));
          if (impl.rebuild) impl.rebuild(w, hh);
        },
        setColors(c) { o.colors = c; if (impl.recolor) impl.recolor(); },
        destroy() {},
      };
      h.resize();
      return h;
    };
  }
  const gradient = (ctx, o, w, h, a, b) => { const g = ctx.createLinearGradient(0, 0, 0, h); g.addColorStop(0, col(o, a)); g.addColorStop(1, col(o, b)); return g; };
  function sprite(color, size, falloff) {   // soft radial disc, pre-rendered once
    const c = document.createElement('canvas'); c.width = c.height = size;
    const x = c.getContext('2d'); const g = x.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    g.addColorStop(0, rgba(color, 1)); g.addColorStop(falloff, rgba(color, 0.55)); g.addColorStop(1, rgba(color, 0));
    x.fillStyle = g; x.fillRect(0, 0, size, size); return c;
  }

  // ---------------------------------------------------------------------------------------------
  reg('none', 'Solid color', canvas2d((ctx, o) => ({
    draw(w, h) { ctx.fillStyle = col(o, 0); ctx.fillRect(0, 0, w, h); },
  })));

  reg('flow', 'Gradient flow', shader(`
  void main(){
    vec2 uv = gl_FragCoord.xy / R; vec2 p = (uv - 0.5) * vec2(R.x / R.y, 1.0);
    vec2 b1 = vec2(sin(T*0.37)*0.55, cos(T*0.29)*0.35);
    vec2 b2 = vec2(cos(T*0.23+2.0)*0.6, sin(T*0.41+1.0)*0.4);
    vec2 b3 = vec2(sin(T*0.31+4.0)*0.5, sin(T*0.19+2.5)*0.45);
    float r = 0.35 + 0.25 * I; r *= r;
    float g1 = exp(-dot(p-b1,p-b1)/r), g2 = exp(-dot(p-b2,p-b2)/r), g3 = exp(-dot(p-b3,p-b3)/(r*1.3));
    vec3 c = C0; c = mix(c, C1, g1 * 0.95); c = mix(c, C2, g2 * 0.9); c = mix(c, C3, g3 * 0.85);
    c *= 0.9 + 0.2 * (1.0 - length(uv - 0.5));
    c += (h(gl_FragCoord.xy + fract(T)) - 0.5) * 0.02;
    gl_FragColor = vec4(c, 1.0);
  }`));

  reg('aurora', 'Aurora', shader(`
  void main(){
    vec2 uv = gl_FragCoord.xy / R; vec2 p = uv * vec2(R.x / R.y, 1.0); float t = T * 0.12;
    vec2 q = vec2(fbm(p + t * 0.10), fbm(p + vec2(5.2, 1.3) - t * 0.07));
    float f = fbm(p * 1.5 + 2.0 * q + vec2(t * 0.05, 0.0));
    float band = smoothstep(0.2, 0.9, f) * (0.5 + 0.5 * sin(uv.y * 6.0 + q.x * 4.0 + t * 0.4));
    vec3 c = mix(C0, C1, smoothstep(0.0, 0.5, f));
    c = mix(c, C2, smoothstep(0.35, 0.75, f) * uv.y * I);
    c = mix(c, C3, band * 0.6 * I);
    c = mix(c, C3 * 1.2, pow(max(0.0, f - 0.65) * 2.5, 2.0) * I);
    c *= 0.85 + 0.3 * (1.0 - length(uv - 0.5));
    c += (h(gl_FragCoord.xy + fract(T)) - 0.5) * 0.03;
    gl_FragColor = vec4(c, 1.0);
  }`));

  reg('nebula', 'Nebula', shader(`
  float stars(vec2 uv, float scale, float t) {
    vec2 g = uv * scale; vec2 id = floor(g), f = fract(g) - 0.5;
    float r = h(id); if (r < 0.9) return 0.0;
    vec2 off = vec2(h(id + 1.7), h(id + 3.1)) - 0.5;
    float d = length(f - off * 0.6);
    float tw = 0.6 + 0.4 * sin(t * (2.0 + 4.0 * h(id + 9.0)) + r * 40.0);
    return smoothstep(0.08, 0.0, d) * tw * (r - 0.9) * 10.0;
  }
  void main(){
    vec2 uv = gl_FragCoord.xy / R; vec2 p = (uv - 0.5) * vec2(R.x / R.y, 1.0); float t = T * 0.5;
    vec2 q1 = p * 1.3 + vec2(t * 0.10, t * 0.03);
    vec2 q2 = p * 2.2 + vec2(-t * 0.06, t * 0.05) + 3.7;
    float w = fbm(q1 + 0.6 * vec2(fbm(q1 + t * 0.05), fbm(q1 - 2.0)));
    float w2 = fbm(q2 + 0.4 * vec2(fbm(q2 * 1.3), fbm(q2 + 5.0)));
    float cloud = smoothstep(0.7 - 0.25 * I, 0.98, w * 0.7 + w2 * 0.45);
    vec3 c = C0;
    c = mix(c, C1, smoothstep(0.15, 0.7, w) * 0.9);
    c = mix(c, C2, cloud);
    c = mix(c, C3, pow(cloud, 2.5) * (0.5 + 0.5 * w2));
    float s = stars(p, 28.0, t * 3.0) * 0.8 + stars(p + 4.2, 60.0, t * 3.0) * 0.5;
    c += vec3(1.0) * s * (1.0 - cloud * 0.7);
    c *= 0.8 + 0.4 * (1.0 - length(uv - 0.5) * 0.9);
    c += (h(gl_FragCoord.xy + fract(T)) - 0.5) * 0.02;
    gl_FragColor = vec4(c, 1.0);
  }`));

  reg('plasma', 'Liquid plasma', shader(`
  void main(){
    vec2 uv = gl_FragCoord.xy / R; vec2 p = (uv - 0.5) * vec2(R.x / R.y, 1.0) * 3.0; float t = T * 0.4;
    for (int i = 1; i < 6; i++) {
      float fi = float(i); vec2 q = p;
      p.x += (0.2 + 0.3 * I) / fi * sin(fi * q.y * 1.3 + t * (0.7 + 0.1 * fi) + fi * 1.7);
      p.y += (0.2 + 0.3 * I) / fi * cos(fi * q.x * 1.1 + t * (0.5 + 0.13 * fi) + fi * 0.9);
    }
    float v = 0.5 + 0.5 * sin(p.x * 1.2 + p.y * 0.8 + t * 0.4);
    float w = 0.5 + 0.5 * cos(length(p) * 1.5 - t * 0.6);
    float f = pow(mix(v, w, 0.5), 1.4);
    vec3 c = mix(C0, C1, smoothstep(0.0, 0.45, f));
    c = mix(c, C2, smoothstep(0.4, 0.8, f));
    c = mix(c, C3, smoothstep(0.78, 1.0, f));
    c *= 0.85 + 0.3 * (1.0 - length(uv - 0.5));
    gl_FragColor = vec4(c, 1.0);
  }`));

  reg('waves', 'Layered waves', shader(`
  void main(){
    vec2 uv = gl_FragCoord.xy / R; float asp = R.x / R.y; vec3 c = C0; float t = T * 0.5;
    for (int i = 0; i < 5; i++) {
      float fi = float(i);
      float y = 0.12 + 0.14 * fi + (0.05 + 0.04 * I) * sin(uv.x * asp * (2.0 + fi * 0.9) + t * (0.6 + 0.15 * fi) + fi * 1.3)
                + 0.025 * sin(uv.x * asp * (5.0 + fi) - t * (0.9 + 0.1 * fi) + fi);
      float d = uv.y - y;
      float fill = smoothstep(0.0, -0.3, d) * 0.55;
      float line = smoothstep(0.006, 0.0, abs(d)) * 0.9;
      vec3 lc = i == 0 ? C1 : (i == 1 ? C2 : (i == 2 ? C3 : (i == 3 ? C1 : C2)));
      c = mix(c, mix(C0, lc, 0.75), fill);
      c = mix(c, lc, line);
    }
    c *= 0.9 + 0.2 * (1.0 - length(uv - vec2(0.5, 0.6)));
    gl_FragColor = vec4(c, 1.0);
  }`));

  reg('hex', 'Hex grid pulse', shader(`
  float hexDist(vec2 p){ p = abs(p); return max(dot(p, normalize(vec2(1.0, 1.732))), p.x); }
  vec4 hexCoords(vec2 uv){
    vec2 r = vec2(1.0, 1.732), hh = r * 0.5;
    vec2 a = mod(uv, r) - hh, b = mod(uv - hh, r) - hh;
    vec2 gv = dot(a, a) < dot(b, b) ? a : b;
    return vec4(gv, uv - gv);
  }
  void main(){
    vec2 uv = gl_FragCoord.xy / R; vec2 p = (uv - 0.5) * vec2(R.x / R.y, 1.0);
    vec4 hc = hexCoords(p * 9.0);
    float d = 0.5 - hexDist(hc.xy);
    float edge = smoothstep(0.08, 0.0, d);
    float dist = length(hc.zw) / 9.0;
    float pulse = pow(0.5 + 0.5 * sin(dist * 10.0 - T * 1.5), 6.0);
    float flick = step(0.93, h(hc.zw + floor(T * 0.5)));
    vec3 c = C0;
    c = mix(c, C1, edge * (0.25 + 0.5 * I));
    c = mix(c, C2, pulse * (0.35 + 0.45 * I) * (1.0 - edge * 0.5));
    c = mix(c, C3, flick * (1.0 - edge) * 0.6);
    c *= 0.85 + 0.3 * (1.0 - length(uv - 0.5));
    gl_FragColor = vec4(c, 1.0);
  }`));

  reg('sky', 'Sunset sky', shader(`
  void main(){
    vec2 uv = gl_FragCoord.xy / R; float asp = R.x / R.y; float t = T * 0.3;
    vec3 c = mix(C1, C0, smoothstep(0.35, 1.0, uv.y));
    vec2 sp = vec2(0.5 * asp, 0.42); vec2 p = vec2(uv.x * asp, uv.y);
    float d = length(p - sp);
    float sun = smoothstep(0.19, 0.185, d);
    float stripes = smoothstep(0.3, 0.7, 0.5 + 0.5 * sin(uv.y * 90.0 + t)) * smoothstep(0.42, 0.25, uv.y);
    vec3 sc = mix(C3, C2, smoothstep(0.25, 0.42, uv.y));
    c = mix(c, sc, sun * (1.0 - stripes * 0.9));
    c += C3 * exp(-d * 6.0) * 0.5 * I;
    float stars = step(0.985, h(floor(p * 160.0))) * smoothstep(0.45, 0.9, uv.y) * (0.5 + 0.5 * sin(t * 4.0 + h(floor(p * 160.0) + 1.0) * 60.0));
    c += stars * 0.8;
    float haze = smoothstep(0.42, 0.3, uv.y) * smoothstep(0.1, 0.3, uv.y);
    c = mix(c, C2, haze * 0.25 * I);
    c = mix(c, C0 * 0.5, smoothstep(0.3, 0.0, uv.y));
    gl_FragColor = vec4(c, 1.0);
  }`));

  reg('streaks', 'Light streaks', shader(`
  float layer(vec2 uv, float cols, float t, float seed){
    float x = uv.x * cols; float id = floor(x), f = fract(x);
    float sp = 0.4 + 0.8 * h(vec2(id, seed));
    float y = fract(h(vec2(id, seed + 1.0)) + uv.y * (0.6 + 0.4 * h(vec2(id, seed + 2.0))) + t * sp * 0.25);
    float tail = pow(y, 10.0);
    float line = smoothstep(0.18, 0.0, abs(f - 0.5 - (h(vec2(id, seed + 3.0)) - 0.5) * 0.4));
    return tail * line * step(0.35, h(vec2(id, seed + 4.0)));
  }
  void main(){
    vec2 uv = gl_FragCoord.xy / R; float asp = R.x / R.y;
    vec3 c = mix(C0, C1, uv.y * 0.6);
    float a = layer(vec2(uv.x * asp, uv.y), 36.0, T, 1.0);
    float b = layer(vec2(uv.x * asp + 0.37, uv.y), 70.0, T * 1.6, 7.0);
    c += C2 * a * (0.8 + 0.6 * I);
    c += C3 * b * (0.5 + 0.4 * I);
    c *= 0.9 + 0.2 * (1.0 - length(uv - 0.5));
    gl_FragColor = vec4(c, 1.0);
  }`));

  reg('dust', 'Drifting dust', canvas2d((ctx, o) => {
    let P = [];
    return {
      rebuild(w, h) {
        P = []; const n = Math.round(90 + 110 * (o.intensity == null ? 1 : o.intensity));
        for (let i = 0; i < n; i++) P.push({ x: rand(0, w), y: rand(0, h), r: rand(0.6, 2.4), vx: rand(-6, 6), vy: rand(-10, -2), ph: rand(0, 6.28), sp: rand(0.5, 2), c: Math.random() < 0.5 ? 2 : 3 });
      },
      draw(w, h, now, dt, speed, inten) {
        ctx.fillStyle = gradient(ctx, o, w, h, 0, 1); ctx.fillRect(0, 0, w, h);
        const t = now / 1000;
        for (const p of P) {
          p.x += p.vx * dt * speed; p.y += p.vy * dt * speed;
          if (p.y < -4) { p.y = h + 4; p.x = rand(0, w); } if (p.x < -4) p.x = w + 4; else if (p.x > w + 4) p.x = -4;
          const a = (0.25 + 0.75 * (0.5 + 0.5 * Math.sin(t * p.sp + p.ph))) * Math.min(1, inten);
          ctx.fillStyle = rgba(col(o, p.c), a * 0.8);
          ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, 6.2832); ctx.fill();
        }
      },
    };
  }));

  reg('bokeh', 'Bokeh', canvas2d((ctx, o) => {
    let P = [], S = {};
    const sp = (ci, size) => { const k = ci + ':' + size; return S[k] || (S[k] = sprite(col(o, ci), size, 0.5)); };
    return {
      recolor() { S = {}; },
      rebuild(w, h) {
        P = []; const n = Math.round(22 + 26 * (o.intensity == null ? 1 : o.intensity));
        for (let i = 0; i < n; i++) P.push({ x: rand(0, w), y: rand(0, h), s: Math.round(rand(60, 260) / 20) * 20, vx: rand(-8, 8), vy: rand(-8, 8), ph: rand(0, 6.28), c: 1 + (i % 3), a: rand(0.25, 0.6) });
      },
      draw(w, h, now, dt, speed, inten) {
        ctx.globalCompositeOperation = 'source-over';
        ctx.fillStyle = gradient(ctx, o, w, h, 0, 0); ctx.fillRect(0, 0, w, h);
        ctx.globalCompositeOperation = 'lighter';
        const t = now / 1000;
        for (const p of P) {
          p.x += (p.vx + 6 * Math.sin(t * 0.3 + p.ph)) * dt * speed; p.y += p.vy * dt * speed;
          const m = p.s; if (p.x < -m) p.x = w + m; else if (p.x > w + m) p.x = -m; if (p.y < -m) p.y = h + m; else if (p.y > h + m) p.y = -m;
          ctx.globalAlpha = p.a * (0.7 + 0.3 * Math.sin(t * 0.5 + p.ph)) * Math.min(1, 0.4 + 0.6 * inten);
          ctx.drawImage(sp(p.c, p.s), p.x - p.s / 2, p.y - p.s / 2);
        }
        ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over';
      },
    };
  }));

  reg('stars', 'Starfield', canvas2d((ctx, o) => {
    let P = [], shoot = null, nextShoot = 0;
    return {
      rebuild(w, h) {
        P = []; const n = Math.round((w * h) / 4500 * (0.6 + 0.6 * (o.intensity == null ? 1 : o.intensity)));
        for (let i = 0; i < n; i++) P.push({ x: rand(0, w), y: rand(0, h), r: Math.pow(Math.random(), 2.2) * 1.8 + 0.3, ph: rand(0, 6.28), sp: rand(0.3, 1.5), c: Math.random() < 0.8 ? 2 : 3 });
      },
      draw(w, h, now, dt, speed, inten) {
        ctx.fillStyle = gradient(ctx, o, w, h, 0, 1); ctx.fillRect(0, 0, w, h);
        const t = now / 1000, dx = 2 * dt * speed, dy = 1 * dt * speed;
        for (const p of P) {
          p.x += dx; p.y += dy; if (p.x > w + 2) p.x = -2; if (p.y > h + 2) p.y = -2;
          const a = 0.35 + 0.65 * (0.5 + 0.5 * Math.sin(t * p.sp + p.ph));
          ctx.fillStyle = rgba(col(o, p.c), a);
          ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, 6.2832); ctx.fill();
        }
        if (!shoot && now > nextShoot) {
          shoot = { x: rand(w * 0.1, w * 0.9), y: rand(0, h * 0.4), vx: rand(500, 900) * (Math.random() < 0.5 ? -1 : 1), vy: rand(250, 450), life: 0 };
          nextShoot = now + rand(6000, 16000) / Math.max(0.2, inten);
        }
        if (shoot) {
          shoot.life += dt; shoot.x += shoot.vx * dt; shoot.y += shoot.vy * dt;
          const a = Math.max(0, 1 - shoot.life / 0.9);
          ctx.strokeStyle = rgba(col(o, 3), a * 0.9); ctx.lineWidth = 1.5; ctx.lineCap = 'round';
          ctx.beginPath(); ctx.moveTo(shoot.x, shoot.y); ctx.lineTo(shoot.x - shoot.vx * 0.12, shoot.y - shoot.vy * 0.12); ctx.stroke();
          if (a <= 0) shoot = null;
        }
      },
    };
  }));

  reg('mesh', 'Geometric mesh', canvas2d((ctx, o) => {
    let P = [];
    return {
      rebuild(w, h) {
        P = []; const n = Math.round((w * h) / 26000 * (0.6 + 0.5 * (o.intensity == null ? 1 : o.intensity)));
        for (let i = 0; i < n; i++) P.push({ x: rand(0, w), y: rand(0, h), vx: rand(-14, 14), vy: rand(-14, 14) });
      },
      draw(w, h, now, dt, speed, inten) {
        ctx.fillStyle = gradient(ctx, o, w, h, 0, 1); ctx.fillRect(0, 0, w, h);
        const link = Math.min(w, h) * 0.16 * (0.8 + 0.4 * inten), l2 = link * link;
        for (const p of P) {
          p.x += p.vx * dt * speed; p.y += p.vy * dt * speed;
          if (p.x < 0 || p.x > w) p.vx *= -1; if (p.y < 0 || p.y > h) p.vy *= -1;
        }
        ctx.lineWidth = 1;
        for (let i = 0; i < P.length; i++) for (let j = i + 1; j < P.length; j++) {
          const a = P[i], b = P[j], dx = a.x - b.x, dy = a.y - b.y, d2 = dx * dx + dy * dy;
          if (d2 > l2) continue;
          ctx.strokeStyle = rgba(col(o, 2), (1 - d2 / l2) * 0.5);
          ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
        }
        ctx.fillStyle = rgba(col(o, 3), 0.9);
        for (const p of P) { ctx.beginPath(); ctx.arc(p.x, p.y, 1.8, 0, 6.2832); ctx.fill(); }
      },
    };
  }));

  reg('rings', 'Ripple rings', shader(`
  void main(){
    vec2 uv = gl_FragCoord.xy / R; vec2 p = (uv - 0.5) * vec2(R.x / R.y, 1.0);
    float d = length(p); float t = T * 0.6;
    float w = 0.5 + 0.5 * sin(d * 22.0 - t * 2.0 + 0.8 * fbm(p * 2.0 + t * 0.2));
    float ring = pow(w, 4.0 + 6.0 * (1.0 - I));
    float fade = smoothstep(1.1, 0.0, d);
    vec3 c = mix(C0, C1, smoothstep(0.0, 1.0, d) * 0.6);
    c = mix(c, C2, ring * fade * 0.8);
    c = mix(c, C3, pow(ring, 3.0) * fade);
    c += (h(gl_FragCoord.xy + fract(T)) - 0.5) * 0.02;
    gl_FragColor = vec4(c, 1.0);
  }`));

  function create(id, canvas, opts) {
    const make = makers[id] || makers.flow;
    const o = Object.assign({ colors: ['#0c0a08', '#2a1b3d', '#3b5a9a', '#d97757'], speed: 1, intensity: 1, scale: 0.5 }, opts || {});
    try { return make(canvas, o); }
    catch (e) { console.error('BG ' + id + ' failed, falling back to solid', e); return makers.none(canvas, o); }
  }
  return { list, create, ids: () => list.map(b => b.id) };
})();
