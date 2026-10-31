// Tiny WebGL helper for full-screen fragment-shader scenes. Include after _ltw.js:
//   const G = GL(canvas, FRAGMENT_SOURCE); G.resize(scale); G.uniform('T', t); G.draw();
// The fragment shader gets `uniform vec2 R` (canvas size in pixels) for free.
function GL(canvas, fs) {
  const gl = canvas.getContext('webgl', { antialias: false, alpha: false, powerPreference: 'low-power', preserveDrawingBuffer: false });
  if (!gl) throw new Error('WebGL unavailable');
  const VS = 'attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }';
  const deriv = gl.getExtension('OES_standard_derivatives') ? '#extension GL_OES_standard_derivatives : enable\n' : '';
  function sh(type, src) {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  const prog = gl.createProgram();
  gl.attachShader(prog, sh(gl.VERTEX_SHADER, VS));
  gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, deriv + 'precision highp float; uniform vec2 R;\n' + fs));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
  gl.useProgram(prog);
  const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const locs = {};
  const U = (n) => (locs[n] = locs[n] || gl.getUniformLocation(prog, n));
  const hex = (c) => [1, 3, 5].map(i => parseInt((c || '#000000').slice(i, i + 2), 16) / 255);
  return {
    gl,
    uniform(n, ...v) {
      const l = U(n); if (l == null) return;
      if (v.length === 1) gl.uniform1f(l, v[0]); else if (v.length === 2) gl.uniform2f(l, v[0], v[1]);
      else if (v.length === 3) gl.uniform3f(l, v[0], v[1], v[2]); else gl.uniform4f(l, v[0], v[1], v[2], v[3]);
    },
    color(n, c) { gl.uniform3fv(U(n), hex(c)); },
    colors(prefix, list, count) { for (let i = 0; i < count; i++) gl.uniform3fv(U(prefix + i), hex(list[Math.min(i, list.length - 1)])); },
    floats(n, arr) { gl.uniform1fv(U(n), new Float32Array(arr)); },
    resize(scale) {
      const s = Math.min(devicePixelRatio || 1, 2) * (scale || 1);
      canvas.width = Math.max(1, Math.floor(innerWidth * s));
      canvas.height = Math.max(1, Math.floor(innerHeight * s));
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.uniform2f(U('R'), canvas.width, canvas.height);
    },
    draw() { gl.drawArrays(gl.TRIANGLES, 0, 3); },
  };
}
// Shared frame loop: calls fn(now, dt) at most CONFIG.fps times per second (reads fps live).
function LTWLoop(getFps, fn) {
  let last = 0, prev = performance.now();
  function frame(now) {
    requestAnimationFrame(frame);
    if (now - last < 1000 / getFps()) return;
    last = now;
    const dt = Math.min(0.1, (now - prev) / 1000); prev = now;
    fn(now, dt);
  }
  requestAnimationFrame(frame);
}
