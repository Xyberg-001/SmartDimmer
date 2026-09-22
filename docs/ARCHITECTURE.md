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
  `setMonHW`, `setMonSW`, `toggleSplit`, `setDim`, `setTargets`, `toggleLinkAll`, `setLinkHWSW`,
  `setCurve`, `setInvert`, `setFactor`, `setMaxDark`, `setStep`, `capture`, `setTheme`,
  `setThemeColor`, `resetTheme`, `copyPreset`, `setGlass`, `setGlassOpacity`, `setWpIntensity`,
  `setWpFrost`, `uiAreas`, `sched|...`, `saveDefaults`, `restoreDefaults`, `factoryReset`,
  `setUseDefaults`, `setStartup`, `flipPrimary`, `setPrimaryGuard`, `identify`, `openSettings`,
  `hideSettings`, `resize|<hittest>` and `drag`.
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
- The web view background is transparent (`put_DefaultBackgroundColor` with alpha 0) so the page
  decides what is opaque.

## Brightness

- Hardware: `Dxva2` `SetMonitorBrightness` (DDC/CI) for external monitors, WMI `WmiSetBrightness`
  for monitor 1 (laptop panel). Targets select which monitors receive the level; `Link all` sends to
  every monitor; per-monitor "exact" writes bypass the target list.
- Software: `SetDeviceGammaRamp` per monitor, level mapped through the linear or exponential curve
  and limited by `MaxSoftwareDarkness`.
- Independent monitors keep their own levels; the master hides while any is independent.

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
