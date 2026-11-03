# Changelog

## 0.5 — 2026-11-03

- **App wheel, your way.** Pin apps so they keep a fixed slot (and launch when not running), hide apps
  from the wheel, pick alphabetical order, or run a pinned-only launcher wheel. A picker in Customize →
  App → *Apps on the wheel*, "Pin *App* to App Wheel" in the Window menu, and `./ltw apps pin|unpin|hide|show|list`.
- **Keyboard on the wheels.** With a wheel held open: 1–9 pick a wedge, 0 the hub, arrows / Tab move,
  Return picks.
- **System monitor rebuilt.** Per-core CPU, user/system split, load average, GPU utilization, memory
  breakdown (app / wired / compressed / cached, swap), disk throughput and free space, battery time
  left, watts, health, cycles and temperature, network interface and totals, thermal state, process
  count, the wallpaper's own cost, and top processes. Update interval 1–10 s. Many more menu bar
  readouts. `./ltw stats [--json]`.
- **Monitor scene.** The stats as a dashboard on the wallpaper: grid, sidebar, edge bar or corner
  layouts; glass, flat, outline or terminal styles; alert thresholds; any `_bg.js` background.
- **Stats feed for scene authors.** `stats: true` on a SCHEMA streams samples to `LTW.stats`.
- **Polish.** HUD confirmations (pins, failed snaps, missing Accessibility), *Check for Updates…* and
  *Copy Diagnostics* under Advanced.

## 0.4

- Window wheel (⌃⌥W) with eight layouts and a center hub; App wheel (⌃⌥Tab) with apps or windows mode.
- Clock scene: eight faces over fourteen animated backgrounds (`_bg.js`).
- Stable local code-signing identity (`tools/make-signing-cert.sh`) so privacy grants survive rebuilds.

## 0.3

- Lock screen shows the last frame of the scene.
- Clean public repository.

## 0.2

- Customize window, per-scene settings, power-aware pausing, hands scene, volume mixer, Dock settings,
  audio-reactive scenes, menu bar tint, slideshow, snapshots, `ltw` CLI.
