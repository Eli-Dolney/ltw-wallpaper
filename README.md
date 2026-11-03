# Ltw Wallpaper

A tiny, local "wallpaper engine" for macOS. A menu-bar app puts a WebKit view **behind your desktop
icons**, so any HTML/JS/WebGL page, image, or video becomes your live wallpaper. No Xcode project,
no dependencies, builds with the Command Line Tools.

## Get it

Needs a Mac on macOS 13 or newer and Apple's Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Eli-Dolney/ltw-wallpaper.git
cd ltw-wallpaper
./run.sh
```

## Run it

```bash
./run.sh
```

That compiles the app, installs it as `/Applications/LtwWallpaper.app`, launches it, and adds a ✨
icon to the menu bar. Click the icon to switch scenes, open **Customize…**, reload, save a snapshot,
or quit. Only the Applications copy is launched (by `run.sh` and by `ltw`), so you never end up with
two icons; reopen it later from Launchpad/Spotlight or `open -a LtwWallpaper`. Opening the app icon
while it is already running just brings up the Customize window. `LTW_INSTALL=0 ./run.sh` runs the
`build/` copy instead.

## Customize

**Customize…** in the menu (or `./ltw customize`) opens a small window with two tabs.

**Scene** shows a strip of scene thumbnails (captured a few seconds after each scene runs) and the
current scene's settings: color pickers, sliders, toggles and text fields. Changes
apply live and are saved per scene in `~/Library/Application Support/LtwWallpaper/settings/<scene>.json`
(only the values you changed). ↺ next to a label reverts that field; **Reset** deletes the file.

**App** holds the app-wide options:

- **Menu bar icon**: pick an SF Symbol, type an emoji or short text instead, or choose a PNG of your
  own (template-tinted unless "Keep image colors" is on). "Show scene name" adds the scene next to it.
- **Menu bar tint**: macOS tints the menu bar and the show-desktop view from the *system* wallpaper,
  so the app can set that to a snapshot of the scene (optionally darkened, optionally refreshed every
  N seconds for animated scenes), to a solid color, or leave it alone. The original wallpaper is
  remembered and restored on quit or from Advanced → Restore Original Wallpaper. The lock screen
  shows the same picture, so "Lock screen shows the last frame" grabs the frame on screen the
  moment you lock or the display sleeps.
- **Battery saver**: Auto (follows Low Power Mode), On (15 fps cap), Off.
- **Keep Mac awake**: runs `caffeinate` so the Mac and display never sleep while it is on. Also in the
  menu as **Keep Awake** (⌘K) and `./ltw awake on|off`.
- **Scenes**: change the scene automatically every 15 min … daily, optionally shuffled.
- **Shortcuts**: global hotkeys ⌃⌥N next scene, ⌃⌥P pause/resume animation, ⌃⌥K keep awake,
  ⌃⌥M mixer, ⌃⌥C customize, ⌃⌥W window wheel. Only the wheel needs the Accessibility permission.
- **Window wheel**: the GTA-style radial menu for windows (below). Size, how much to dim the screen
  behind it, and a gap to leave between tiled windows.
- **Customize window**: translucent blur or solid background, opacity, dark / light / match system,
  accent color, hide the window buttons for a clean bar (close with ⌘W or Esc), keep on top (off makes
  it an ordinary window other apps cover), hide when you click elsewhere. Customize… in the menu and
  ⌃⌥C toggle it: open when hidden, hide when it is in front.
- **Startup**: open at login (registers a login item; use the copy in /Applications) and show in Dock.

From the shell: `./ltw app <key> <json>`, e.g. `./ltw app menuIconEmoji '"🌊"'` or
`./ltw app menuBarMode '"color"'`. Keys: menuIcon, menuIconEmoji, menuIconImage, menuIconColor,
menuShowScene, menuBarMode (match | color | off), menuBarColor, menuBarDim, menuBarRefresh,
lockScreenFrame,
batterySaver (auto | on | off), panelStyle (translucent | solid), panelOpacity, panelTheme
(dark | light | system), panelAccent, panelButtons, panelOnTop, loginItem, dockIcon.

The app icon (Finder, Launchpad, Login Items) is `Resources/AppIcon.icns`, rendered by
`swift tools/make-icon.swift [accent]`.

**Permissions and rebuilds.** The build is ad-hoc signed, and macOS treats every ad-hoc build as a
new app, so permissions you grant (System Audio Recording for the mixer, folder access) are asked
again after each `./run.sh`. Run `tools/make-signing-cert.sh` once: it creates a local
"Ltw Wallpaper Dev" code-signing certificate (macOS asks for your login password to trust it) and
`build.sh` signs with it from then on, so permissions stick.

**Audio** is a volume mixer: output device, master volume and mute, and a slider per app that is
playing audio (0–200%, above 100% is a boost; double-click a slider for 100%; 🔈 mutes). macOS has
no per-app volume API, so an app is only touched once its slider leaves 100%: the app gets a Core Audio
process tap (macOS 14.2+) that silences its own output and hands the audio to Ltw Wallpaper, which
scales it and plays it through a private mixer device on your output. Apps at 100% are never tapped.
The first adjustment asks for the **System Audio Recording** permission; nothing is recorded. Levels
are remembered per app. Shell: `./ltw vol <app> <percent>` (bundle id or app name).

**Stats** shows CPU, memory, battery and network with sparklines, updated every 2 s. The same
numbers can sit at the top of the menu (Customize → App → Monitor) and a compact readout (CPU %,
memory, battery or download speed) can follow the menu bar icon.

**Dock** edits the macOS Dock's own preferences: icon size, magnification, position, auto-hide with
show delay and slide time, minimize effect, minimize into app icon, recent apps, only running apps,
dim hidden apps, running dots, launch bounce, scroll-to-show-windows, single-app mode, and buttons to
add full or half-width spacers (drag them out of the Dock to remove) or restart the Dock. Changes are
written with `defaults write com.apple.dock …` and the Dock restarts about a second later. **Reset**
removes just those keys. From the shell: `./ltw dock <key> <json>`, e.g. `./ltw dock autohide true`.
Hiding the Dock's background tray is not something macOS exposes; tools that do it inject code into
the Dock and need System Integrity Protection relaxed, which this app does not do.

The menu itself stays short: live stats, scenes, Customize…, Volume Mixer… (⌘M), Save Snapshot, Pause
Animation (⌘P, freezes every scene), Keep Awake, a **System** submenu (Hide Desktop Icons, Toggle
Dark Mode, Start Screen Saver, Sleep Display), a **Window** submenu (the wheel and its layouts as plain
menu items), an **Advanced** submenu (… plus Export / Import Settings as
one JSON file, Reload Scenes, Open Scenes Folder, Open Current Scene in Browser, Refresh Menu Bar Tint,
Restore Original Wallpaper), About, and Quit. The Customize window remembers its tab and closes with Esc
or ⌘W.

## Where scenes live

The app reads scenes from `~/Library/Application Support/LtwWallpaper/scenes`. This project's
`scenes/` folder is the source: `./build.sh` and `./ltw reload` copy it there. (Reading straight from
a folder under Desktop/Documents would make macOS show a privacy prompt on every rebuild.)

So the edit loop is: change a file in `scenes/`, then

```bash
./ltw reload
```

## The `ltw` command

```bash
./ltw scene hands        # switch scene (name as shown in the menu)
./ltw next               # next scene
./ltw reload             # copy ./scenes to the app folder and reload
./ltw customize          # open the Customize window
./ltw set <key> <json>   # change one setting of the current scene
./ltw reset              # delete the current scene's saved settings
./ltw snapshot [out.png] # save the current frame (default: ~/Pictures/Ltw Wallpaper)
./ltw sync               # re-sync the system wallpaper snapshot
```

It talks to the app through `ltw://` URLs, so Shortcuts, Raycast, cron, etc. can do the same:
`open "ltw://scene/glyphs"`, `open "ltw://next"`.

## Scenes

Anything in `scenes/` shows up in the menu:

| What                         | How                                                        |
|------------------------------|------------------------------------------------------------|
| Animated scene               | `name.html`, or a folder `name/` with `index.html`         |
| Still image                  | `photo.jpg`, `.png`, `.heic`, `.gif`, `.webp` …            |
| Looping video (muted)        | `clip.mp4`, `.mov`, `.m4v`, `.webm`                        |
| Slideshow                    | drop pictures in `scenes/images/`, pick **slideshow**      |

Files starting with `_` are internal (`_ltw.js` helper, `_panel.html` Customize UI, `_media.html` image/video wrapper).

Included:

- **glyphs** – the Claude Code-style field of shimmering letters and symbols; words resolve out of the noise.
- **hands** – the Creation-of-Adam banner: real hand cutouts drift together, spark at the touch, and
  ease apart, with soft bokeh "splats" drifting across the screen and a swappable center piece
  (3D shapes, `.obj` models, images, text). See below.
- **aurora** – a slow WebGL noise shader with five editable colors.
- **nebula** – deep-space clouds and twinkling stars in three parallax layers that follow the mouse.
- **synthwave** – striped retro sun, neon mountains and a scrolling perspective grid; the sun pumps to the bass. ♪
- **rain** – rain on a window at night: droplets slide and leave trails over blurry city lights.
- **liquid** – slow swirling fluid colors with a sheen; swells with the music. ♪
- **warp** – hyperspace star streaks; the mouse steers, the bass hits the throttle. ♪
- **fireflies** – glowing fireflies drifting over a dark meadow; they gather around the mouse.
- **terrain** – a neon wireframe landscape you fly over; the mouse tilts the camera.
- **visualizer** – a system-audio spectrum as bars, a ring or a wave, with afterglow and beat flashes. ♪
- **topo** – topographic contour lines, computed on the GPU.
- **constellation** – drifting particle network.
- **clock** – one scene, eight faces: Digital, Neon, Minimal, Seven-segment, Flip clock, Analog, Rings
  and a Word clock, each over any of fourteen animated backgrounds (gradient flow, aurora, nebula,
  liquid plasma, layered waves, hex grid, sunset sky, light streaks, drifting dust, bokeh, starfield,
  geometric mesh, ripple rings, or a solid color). Pick the font, size, weight, position on screen,
  12/24-hour, seconds, date format, a bottom note, the four-color background palette, speed and
  intensity, and how much to darken the background under the clock.
- **matrix** – the classic rain.
- **slideshow** – crossfading Ken Burns slideshow of `scenes/images/`.
- **Sample Photo.jpg** – a plain generated image, to show the image path works.

Every scene has a `CONFIG` block at the top of the file (the defaults) and a `SCHEMA` that decides
what the Customize window shows.

### The hands scene

`scenes/hands/index.html`. The hands are `scenes/hands/left.png` (points right) and `right.png`
(points left), transparent PNGs. To make your own from any clip with a black background:

```bash
tools/cut-hands.sh "/path/to/clip.mp4" 0.3      # frame time in seconds; needs ffmpeg
./ltw reload
```

Extra arguments: `tolerance` (brightness below which a pixel can be background, default 0.05),
`min_area` (opaque specks smaller than this many pixels are dropped, default 400) and `edge` (pixels of
fade where an arm leaves the frame, default 60). The matte (`tools/matte.py`) flood-fills the
background from the frame border, so dark shading enclosed by a hand stays solid instead of being
punched out. Without PNGs the scene falls back to drawn vector hands.

Customize exposes hand size, blur, glow, contrast, arm fade, the loop period and gap, splat density /
size / softness / colors, spark strength and colors, and where the center items sit
(`hide-at-touch`, `above`, `below`, `always`). The `items` list is what appears between the fingertips:

```js
items: [
  { type: 'model', src: 'icosahedron', color: '#d97757', style: 'both' },   // cube | icosahedron | sphere | torus
  { type: 'model', src: 'models/pyramid.obj', color: '#f4a27a', style: 'shaded' },  // any .obj in hands/models/
  { type: 'image', src: '../images/sample.jpg' },                            // or a transparent PNG in hands/
  { type: 'text',  text: 'LTW', color: '#ffffff' },
]
```

`style` is `shaded`, `wire`, or `both`. Models are drawn by a small built-in renderer (no libraries),
so keep .obj files to a few thousand faces.

## Writing your own scene

A scene is a normal web page. It fills the screen, mouse events never reach it, and it runs on
every display. Include the helper and register your config:

```html
<script src="_ltw.js"></script>          <!-- ../_ltw.js from a scene folder -->
<script>
const CONFIG = { bg: '#000000', speed: 1, fps: 30 };
const SCHEMA = { groups: [ { label: 'Look', fields: [
  { key: 'bg',    type: 'color', label: 'Background' },
  { key: 'speed', type: 'range', min: 0, max: 5, step: 0.1 },
  { key: 'fps',   type: 'range', min: 5, max: 60, step: 1 },
]}]};
LTW.setup(CONFIG, SCHEMA, { rebuild: () => build(), change(key, value) { /* optional */ } });
</script>
```

- `LTW.setup` merges the user's saved settings into `CONFIG` before your code runs, so just read `CONFIG`.
- Field types: `color`, `colors` (list), `range` (`min`/`max`/`step`), `toggle`, `select` (`options`),
  `text`, `list` (textarea, one item per line), `json`. Add `rebuild: true` to a field when changing it
  needs your `rebuild` hook; otherwise the value is simply updated in `CONFIG` and `change(key, value)` is called.
- `window.LTW` also carries `screen` (`index`, `count`, `width`, `height`, `scale`), `images`
  (files in `scenes/images/`), and `scenesPath`.
- **Mouse**: put `pointer: true` on the `SCHEMA` and the app pushes the pointer at ~30 Hz; read
  `LTW.pointer.x` / `.y` (−1…1, y up). Mouse events never reach the page itself. In a browser the real
  mouse is used, so previews work too.
- **Audio**: put `audio: true` on the `SCHEMA`, call `LTW.audioTick(now)` once per frame, then read
  `LTW.audio`: `level`, `bass`, `mid`, `treble` (0…1), `bands[16]` (40 Hz–16 kHz, log-spaced) and
  `beat` (1 on a kick). The app taps system output only while such a scene is visible and the App tab's
  *Audio-reactive scenes* toggle is on (it needs the same “System Audio Recording” permission as the
  mixer). With no feed (browser preview, permission not granted, toggle off) a synthetic groove plays
  instead so the scene still moves.
- `_gl.js` has a tiny helper for full-screen shader scenes (`GL(canvas, fragmentSource)` and the
  `LTWLoop(fps, fn)` frame gate) used by nebula, synthwave, rain and liquid.
- `_bg.js` is the animated-background library behind the clock. Include `_ltw.js`, `_gl.js` and
  `_bg.js`, then `const bg = BG.create('aurora', canvas, { colors: [...4 hex], speed: 1, intensity: 1,
  scale: 0.5 })` and call `bg.draw(now, dt)` from your frame loop, `bg.resize()` on resize,
  `bg.setColors(list)` when the palette changes and `bg.destroy()` before switching. `BG.list` gives
  `{id, label}` pairs for a select field. A canvas can only hold one kind of context, so create a fresh
  `<canvas>` each time you switch backgrounds.
- Scenes can `fetch()` files next to them (that is how `.obj` models load).
- Scenes also work when opened in a normal browser (menu → Open Current Scene in Browser) for devtools.

Tips that keep the fans quiet:

- Cap your frame rate with `requestAnimationFrame` plus a timer check (all included scenes do).
- For full-screen shaders, render at half resolution and let the canvas scale up (see `aurora.html`, `topo.html`).
- Pre-render sprites or glyph atlases instead of per-frame `fillText`/`filter` (see `glyphs.html`, `hands/`).
- `./ltw snapshot` saves the frame the wallpaper is currently showing as a PNG.

## Performance

- Scenes pause automatically while the wallpaper cannot be seen: when another window covers it
  completely (a full-screen app), when the display sleeps, when the screen is locked, or when you
  switch users. The `_ltw.js` helper holds `requestAnimationFrame` callbacks, pauses CSS animations
  and videos, and resumes when the desktop is visible again.
- **Battery saver** (Customize → App) caps every scene at 15 fps. *Auto* follows macOS Low Power Mode.
- Typical cost on a 2x display: topo/aurora ~2% CPU (GPU shader), hands ~5–8%, glyphs ~8–10%.

## Window wheel

Hold **⌃⌥W** anywhere and a radial menu opens around the cursor, like a game weapon wheel. Move the
mouse toward a wedge and let go: the front window snaps there. The eight wedges sit where the window
ends up: top = fill the screen, left/right = halves, the diagonals = quarters, bottom = bottom half.
The hub is "Center" (70 % of the screen, centered). Tap ⌃⌥W instead of holding it and the wheel stays
open so you can click a wedge; Esc, a right-click or a click outside closes it. The **Window** submenu
in the menu bar has the same layouts as plain items plus Next Display, Minimize and Restore Size (undo
the last snap), and `./ltw window left` etc. does it from the shell; `./ltw wheel` opens the wheel.

Moving other apps' windows needs the **Accessibility** permission: the first use opens System
Settings → Privacy & Security → Accessibility, where you switch on Ltw Wallpaper. Like the audio
permission, macOS forgets it after every rebuild until you run `tools/make-signing-cert.sh` once.
Customize → App → **Window wheel** sets the size, how much the screen dims behind it, and a gap to keep
between tiled windows; the wheel uses the Customize accent color.

## Menu bar tint

macOS tints the menu bar (and the show-desktop view) from the *system* wallpaper, not from what is
drawn under it. Customize → App → **Menu bar tint** (default: snapshot of the scene) sets the system
wallpaper to a snapshot a couple of seconds after the scene loads or changes, optionally darkened and
optionally refreshed on a timer, or to a solid color. Your original wallpaper is remembered and put back
when you quit, or any time via Advanced → **Restore Original Wallpaper**.

The lock screen is drawn by macOS from that same system wallpaper, and nothing can animate there
except Apple's built-in wallpapers. With **Lock screen shows the last frame** (on by default) the app
takes one more snapshot the instant the screen locks, the displays sleep or you switch users, before
the scene pauses, so the lock screen shows exactly what was on your desktop when you walked away.

## Multiple displays, spaces, startup

- One wallpaper window per display; it reloads automatically when displays change.
- Shows on every Space; stays put while switching desktops.
- Launch at login: Customize → App → **Open at login** (or System Settings → General → Login Items & Extensions).
- Quit: menu bar icon → Quit, or `pkill -x LtwWallpaper`.

## How it works

`Sources/`: `main.swift` (status menu, one borderless `NSWindow` per `NSScreen` at
`CGWindowLevelForKey(.desktopWindow)` holding a `WKWebView`, scene loading, `ltw://` URLs),
`SettingsStore.swift` (per-scene JSON overrides, injected into `window.LTW.settings` before each load),
`CustomizePanel.swift` (the Customize window, a `WKWebView` showing `scenes/_panel.html`, talking to
the app through a `webkit.messageHandlers.ltw` channel), `PowerMonitor.swift` (sleep / lock / low
power tracking; window occlusion is observed per window).

## License

MIT. The hand cutouts in `scenes/hands/` are from Michelangelo's *Creation of Adam*, which is in the
public domain.
