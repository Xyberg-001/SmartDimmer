# Architecture

Smart Dimmer is two parts in one process:

- **Engine**: `src/SmartDimmer.ahk` (AutoHotkey v2). Owns all state, talks to the hardware, keeps
  the INI, binds hotkeys, runs the schedule and the primary-display guard, and hosts two frameless
  windows.
- **Interface**: `src/SmartDimmerUI.html` (HTML/CSS/JS), rendered inside those windows by
  Microsoft Edge WebView2 through thqby's `WebView2.ahk` binding. The same page serves the flyout
  and the Settings window; `window.SD_VIEW` tells it which one it is.

## Message protocol

- Engine -> page: `PostWebMessageAsJson` with `{type:"state", ...}` (the complete state, built by
  `BuildState(host)`; per host because the Wallpaper palette depends on the host's screen),
  `{type:"toast", text}`, `{type:"nav", page}` and `{type:"wpgeom", x, y}` (window offset for the
  frosted wallpaper layer while dragging).
- Page -> engine: `chrome.webview.postMessage("command|arg|arg")`, dispatched by `HandleCommand`
  on a timer so nothing runs inside a WebView2 callback. Commands include `ready`, `setHW`, `setSW`,
  `setMonHW`, `setMonSW`, `setWarmth`, `setWarm|n|0/1`, `warmSched|enabled|resume|time|level|fade...`, `env|auto|slot|scope|search|pick|clearPlace|refresh...`, `setSmooth`, `setOsd`, `setSplit|n|0/1` (own sliders; `toggleSplit|n` still works), `setDim`,
  `setBacklight|n|0/1` (edits the target list), `setTargets`, `toggleLinkAll`, `setLinkHWSW`,
  `setCurve`, `setInvert`, `setFactor`, `setMaxDark`, `setStep`, `capture`, `setTheme`,
  `setThemeColor`, `resetTheme`, `copyPreset`, `setGlass`, `setGlassOpacity`, `setWpIntensity`,
  `setWpFrost`, `uiAreas`, `sched|...`, `saveDefaults`, `restoreDefaults`, `factoryReset`,
  `setUseDefaults`, `setStartup`, `flipPrimary`, `setPrimaryGuard`, `identify`,
  `openSettings[|page]`, `hideSettings`, `hideFlyout`, `openDataFolder`, `openProject`,
  `resize|<hittest>` and `drag`.

## Startup and error handling

- Files: `ResolveDataDir()` uses the exe's folder when it is writable, otherwise
  `%LOCALAPPDATA%\SmartDimmer`, for the INI, the log and the extracted page and loader DLL.
- The engine (settings, hotkeys, tray menu, schedule, primary-display guard, display state) starts
  before and independently of the windows.
- When launched at logon (`/startup` argument, passed by the Startup shortcut, or less than 3 minutes
  of uptime) the app waits for the taskbar window plus 4 seconds before touching WebView2.
- `TryCreateHosts()` creates both windows or cleans up completely; `RetryCreateHosts()` repeats after
  3, 5, 10, 15, 30 and 60 s, then shows a tray notification. `EnsureUiReady()` retries on demand when
  the user opens a window and explains the problem if it still fails.
- WebView2 promises are awaited through `AwaitQuietly()`, which marks them as observed so a promise
  that fails after its wait timed out cannot throw later from a timer thread.
- `OnError(OnUnexpectedError)` logs any uncaught error with its call stack, shows one tray
  notification per session, and ends only the thread that failed.
- The page never rebuilds its DOM on a state push: it renders the new markup into a template and
  patches the live DOM in place (`morphChildren`), so hover, focus, scroll and animations survive.
  Rendering is deferred while a slider is being dragged or a text field edited.

## Windows

- Frameless: `WM_NCCALCSIZE` returns 0 (client = whole window), `WM_NCPAINT`/`WM_NCACTIVATE` are
  swallowed, `WM_GETMINMAXINFO` enforces a minimum size. The web view covers the whole client area.
- Dragging uses WebView2's non-client region support (`app-region: drag` on the header). Resizing is
  started by the page: a press within 6 px of an edge posts `resize|<HT code>` and the engine sends
  `WM_NCLBUTTONDOWN` with that hit-test code, so Windows runs its normal sizing loop.
- Glass: `SetWindowCompositionAttribute` with `ACCENT_ENABLE_ACRYLICBLURBEHIND` and a tint alpha
  of 1 (measured: alpha 0 gives no blur, larger alphas only darken). The accent is applied only when
  something changed, after the rounded-corner region (`SetWindowRgn`), and always through the
  disabled state first; it is never touched during a drag. The page paints the theme tint on top.
- Hidden windows sleep: `HideHost` sets the controller's `IsVisible` to false (no painting, no animation,
  `document.visibilityState` becomes hidden), and 3 s later `DeepSleepHost` sets
  `MemoryUsageTargetLevel` to low and calls `TrySuspend`. `PushState` and `Toast` skip a sleeping host;
  `ShowHostAt` wakes it (`Resume`, normal memory level, visible) and the caller pushes the current state.
  Pages loaded at startup go to sleep 1.5 s after they report ready.
- Memory saver: a sleeping host is unloaded after `MEMORY_SAVER_DELAY` (60 s) by `UnloadWebView`
  (message handler released, controller closed); when both are unloaded the environment is released
  too, so every WebView2 process exits, and the app trims its own working set. `ShowHostAt` calls
  `EnsureHostLoaded`, which runs `AttachWebView` again (window creation and web view creation are
  separate for this). Settings opened at a page while its page is still starting keeps the page in
  `pendingNav` and sends it on `ready`.
- The WebView2 environment is created with `WV_BROWSER_ARGS`: one shared renderer for both windows
  (`--process-per-site`, `--renderer-process-limit=1`, site isolation off because only the app's own
  local pages are shown), no background networking or component updates, and unused Edge features off.
- The page keeps ambient motion cheap: the glows move in `steps()` (3 updates a second), the title glow
  animates opacity on its own layer, and everything pauses (`html.idle`) while the window is not focused.
- The web view background is transparent (`put_DefaultBackgroundColor` with alpha 0) so the page
  decides what is opaque.

## Brightness

- Hardware: `Dxva2` `SetMonitorBrightness` (DDC/CI) for external monitors, WMI `WmiSetBrightness`
  for monitor 1 (laptop panel). Targets select which monitors receive the level; `Link all` sends to
  every monitor; per-monitor "exact" writes bypass the target list.
- Software: `SetDeviceGammaRamp` per monitor, level mapped through the linear or exponential curve
  and limited by `MaxSoftwareDarkness`.
- Warmth: the same ramp with per-channel multipliers from Tanner Helland's blackbody approximation,
  relative to 6500 K (`WarmthMultipliers`). Warmth 0-100 maps linearly to 6500-1900 K. If a driver
  refuses a ramp, the tint is softened in quarter steps until one is accepted. Each screen has its
  own warmth tick (`IsWarmTarget`), so a screen can get the tint at level 1.0 without being dimmed.
- Warmth schedule: three parts of the day (`warmPhases`). `WarmStateAt(minutes)` finds the current
  part (wrapping past midnight) and eases from the previous part's warmth over `warmFadeMin`, capped
  at the part's length so each part is reached before the next begins. `WarmScheduleTick` runs every
  15 s; a manual warmth change pauses it until the part changes. `WarmScheduleState` sends the page
  a status line and the day's curve (145 samples, noon to noon) for the timeline.
- Smooth transitions: `ApplyGammaSmooth` keeps what each screen shows (`gammaNow`); a change bigger
  than 0.04 is eased out over 8 ticks of 25 ms by `GammaAnimTick`. Unchanged values are still
  written, because Windows resets ramps after sleep or a display change.
- Windows Night Light: read-only check of the `bluelightreductionstate` CloudStore blob in HKCU
  (byte 18 is `0x15` when on), cached for 5 s.
- On-screen indicator: a native AutoHotkey window (no WebView2, so it appears at once), created in
  a per-monitor DPI-aware thread context so its text is sharp on screens with a different scale,
  with `WS_EX_NOACTIVATE | WS_EX_TRANSPARENT`, a rounded region and a short fade-out.
- Independent monitors keep their own levels; the master hides while any is independent.

## Time of day, weather, Sky theme

`SunPosition(lat, lon)` computes the sun's elevation and hour angle locally (about 1 degree
accurate); `TimeOfDayNow()` turns that into Morning, Day, Evening or Night, and `SunTimesToday()`
finds sunrise and sunset by stepping through the day. Weather and place search go through
`HttpGetAsync()` (WinHTTP, asynchronous, polled on a timer, 15 s timeout) to Open-Meteo; the JSON
replies are read with small regex helpers (`JsonNum`, `JsonText`). `EnvTick()` runs every minute
while the automatic theme or Sky is in use: it fetches the weather when 20 minutes old, recomputes
the Sky palette (`SkyTheme(elevation, kind)`: keyframes by sun height in HSL, blended towards a
weather palette) and the automatic palette: `TimeWeights()` gives each part of the day its share (two
parts cross-fade around dawn and dusk), `AutoBlendFor()` blends their themes and mixes in the
weather's theme with `BlendTheme()` (surfaces by `MixHex`; far-apart accents become accent and
second accent instead of being averaged). The result is `THEMES["Automatic"]`, which has no tile.

## Wallpaper theme

`IDesktopWallpaper` gives the wallpaper path per screen. The picture is downscaled to 96x64 and
its pixels are clustered into 24 hue bins (chroma >= 0.08) plus a neutral bin; clusters are ranked
by area. The page measures how much of the window each colour group covers and reports the order
(`uiAreas`); `ThemeFromWallpaperColours` pairs the two rankings. A 1280 px JPEG copy is written to
`%TEMP%\SmartDimmerWebView\wallpaper` and served to the page as `https://wallpaper.smartdimmer/`
through `SetVirtualHostNameToFolderMapping` for the frosted layer.

## Primary display

`EnumDisplayDevices` + `EnumDisplaySettings` give the active devices and positions;
`ChangeDisplaySettingsEx` with `CDS_SET_PRIMARY | CDS_UPDATEREGISTRY | CDS_NORESET` stages every
display relative to the new primary and a final call applies them. Names come from `QueryDisplayConfig`
+ `DisplayConfigGetDeviceInfo` (target friendly name). The guard polls VCP code `0xD6` (power mode)
over DDC/CI and subscribes to `GUID_CONSOLE_DISPLAY_STATE` to ignore Windows' own display-off.

## Testing

The project has no unit tests; features were verified with harness scripts that append a test
sequence to a stubbed copy of the engine (hardware writes, gamma writes, hotkey binding and the
display-topology change are stubbed) and drive the real page through `ExecuteScriptAsync`, taking
screenshots and reading the log. See `docs/TESTING.md`.
