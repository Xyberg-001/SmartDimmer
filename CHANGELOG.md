# Changelog

All notable changes to Smart Dimmer are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [1.1.0] - 2026-09-26

### Fixed
- **High CPU use in the background.** The flyout and Settings windows kept rendering their animations while
  hidden, which cost close to two CPU cores all the time. Hidden windows are now told they are hidden, then
  suspended with their memory trimmed, and receive no updates until they are shown again (then they get the
  current state at once). Measured: about 1 % of one core in the background, down from 80-180 %.
- **Lighter while open.** The drifting background glows and the title icon's glow now update a few times a
  second instead of every frame (the motion looks the same), and all ambient motion pauses while the window
  is not the active one: about 10-20 % of one core with glass and lively effects on, down from over 100 %.
- **Less memory.** Both windows share one WebView2 page process and background networking is off: one
  process and about 30 MB fewer. New *Free memory when the windows are closed* (General page, on by
  default): a minute after both windows are closed WebView2 is shut down completely, so in the
  background Smart Dimmer is a single process of about 10 MB; opening a window then takes about a second.
- **"Could not open its window: TimeoutError".** Waiting for WebView2 used the bundled promise library's
  timeout, which shrank far faster than real time while window messages were arriving, so a WebView2 start
  that took a couple of seconds (typical after the PC has been idle) was abandoned after about one.
  Smart Dimmer now waits with a real deadline, and retries once with a fresh WebView2 before showing an
  error.
- **Error dialog and exit at Windows startup.** When the Microsoft Edge WebView2 Runtime was not ready
  yet (common right after logon on slower PCs, or while the runtime updates), Smart Dimmer showed
  "Could not start the WebView2 user interface (0x8007...)" and quit, or AutoHotkey's own error dialog
  with an Abort button. It now waits for the desktop when launched at logon, retries opening its
  windows after 3, 5, 10, 15, 30 and 60 seconds, and keeps hotkeys and the schedule running
  meanwhile. If the windows still cannot open, a tray notification says why and a click on the tray
  icon tries again.
- Unexpected errors no longer interrupt with a dialog; they are written to `SmartDimmerDebug.log`
  with their call stack, and a single tray notification points to the log.
- Positioning the flyout or the wallpaper layer while a monitor was still waking up could stop with
  "Parameter #1 of MonitorGet is invalid".
- Running from a folder that is not writable (e.g. Program Files) failed at start; settings, log and
  the extracted UI files now go to `%LOCALAPPDATA%\SmartDimmer` in that case.

### Added
- **Warmth.** A colour-temperature slider in the flyout, from *Off* (neutral 6500 K) to 1900 K, that
  shifts the picture towards orange to cut blue light in the evening. Each screen has its own Warmth
  tick, separate from software brightness, so a screen can be warmed without being dimmed. If
  Windows Night Light is on as well, the flyout says so, since both tint the screen.
- **Warmth schedule, in the style of f.lux.** A new Warmth page in Settings: Daytime, Evening and
  Bedtime each get a start time and a warmth, and a transition (instant, 20 min, 1 hour or 2 hours)
  sets how gently the screens change. A noon-to-noon timeline shows the warmth over the day,
  coloured like the light, with a marker at the current time. Moving a part's slider previews its
  warmth on the screens. Moving the flyout's Warmth slider pauses the schedule until the next part
  of the day, with a Resume button. The flyout's Warmth card has the on/off switch and says what the
  schedule is doing. The brightness schedule is unchanged and separate.
- **Themes that follow the time of day and the weather.** An *Automatic theme* section on the
  Appearance page takes a theme for morning, day, evening and night and one for cloudy, rainy, snowy,
  stormy and foggy weather, and blends them: the parts of the day cross-fade at dawn and dusk and the
  weather's theme is mixed in by an adjustable amount, so every time and weather combination gets its
  own palette. The parts of the
  day come from real sunrise and sunset, calculated on the PC for a place you search for by name;
  without a place they follow the clock.
- **Sky theme.** A generated theme whose colours follow the sun (night, blue hour, sunrise and
  sunset, golden hour, day) and are tinted by the weather.
- Weather is the only thing Smart Dimmer fetches from the internet: from Open-Meteo, no account
  needed, every 20 minutes and only while the automatic theme or the Sky theme is in use.
- **On-screen indicator for hotkeys.** A small bar in the theme's colours shows the new level near
  the bottom of the screen when a brightness hotkey is used, then fades out. It shows on the screen
  that changed, or for the all-screens keys on the screen under the mouse. Switch on the Hotkeys page.
- **Smooth transitions.** Software brightness and warmth fade over about 200 ms instead of jumping
  when they change by more than a few percent. Switch on the Brightness page.

### Changed
- **Navigation reorganised.** The flyout is for everyday adjusting and Settings for things you set
  once; nothing appears in both.
  - Flyout: Brightness (shared sliders with a one-line explanation), Warmth (the warmth slider, its
    per-screen ticks and the warmth schedule switch), Screens (an *Own sliders* switch per screen),
    Schedule (on/off, what is in effect, *Edit ›* opens the Schedule page).
  - Settings pages: Brightness, Warmth, Screens, Hotkeys, Schedule, Appearance, General, each opening
    with a line saying what it is for.
  - The *Targets* number field and *Link all* button are replaced by per-screen *Backlight* and
    *Software* ticks in the flyout: under each shared slider ("Applies to"), on each screen's own
    sliders, and on a screen's card while the shared sliders are hidden. Untick to leave that
    adjustment alone on the screen at once; software brightness returns to normal immediately. The
    same ticks are on Settings > Screens. Existing settings carry over.
  - The Backlight tick now also covers a screen's own sliders, its hotkeys and the schedule (before,
    a screen on its own sliders always had its backlight changed).
  - "Follows master / Independent" buttons are replaced by the *Own sliders* switch.
  - Hotkeys are shown as "Ctrl + Up" instead of `^Up`.
  - "Hardware" is called "Backlight" throughout.
- **Six new themes:** Amber Night (warm amber into red, no blue light, for night use), Synthwave
  (hot pink into gold), Tokyo Night (soft blue into lavender), Nord Frost (ice blue into mauve),
  Graphite (near-monochrome) and Cyber Neon (cyan into yellow).
- **Northern Lights theme.** Aurora green into violet over a deep polar night; with lively effects on,
  slowly swaying aurora curtains and faint stars fill the background.
- **Milky Way redesigned** as a night sky: pale gold (the galaxy's core) blending into nebula violet
  on deep blue, so it no longer looks like Tokyo Night. Edits you made to Milky Way are kept; *Reset
  to original* gives the new palette.
- **Livelier themes.** Every theme now has a second accent colour (a new, editable colour slot), and a
  *Lively effects* switch on the Appearance page (on by default) adds soft drifting glows in both
  accents behind translucent cards plus two-tone gradients on sliders, switches, readouts, primary
  buttons and the title. The Wallpaper theme takes its second accent from the picture.
- Changing warmth, or a screen's Software or Warmth tick, only rewrites the colour ramp; it no
  longer resends the backlight to every monitor over DDC/CI, which took up to a second per monitor.
- Esc closes the flyout and the Settings window.
- On first run the flyout opens at the bottom-right of the main screen, next to the tray.
- The Startup shortcut passes `/startup`; existing shortcuts are updated automatically.
- The log rolls over to `SmartDimmerDebug.log.old` past 2 MB.

## [1.0.0] - 2026-09-23

First public release.

### Added
- Hardware backlight control over DDC/CI (external monitors) and WMI (laptop panel), plus software
  dimming through gamma ramps, per monitor or for all monitors at once.
- Flyout window from the tray icon; Settings window with Brightness, Monitors & keys, Schedule,
  Appearance and Defaults pages. Both rendered by Microsoft Edge WebView2 with animated controls.
- Independent per-monitor control ("Independent" cards) and a master mode that hides while any
  monitor is independent.
- Global hotkeys for hardware and software brightness, master and per monitor, captured from the
  keyboard or mouse buttons; a key can live in only one slot.
- Time-of-day schedule with 8 entries, optional fade, wrap past midnight and pause on manual change.
- Defaults: save the whole configuration, restore it, factory reset, and optionally load the saved
  defaults at startup.
- Themes: Lava Orange, Aqua Blue, Emerald Green, Lavender Pink, Milky Way, Custom, and Wallpaper
  (palette generated from the wallpaper of the screen each window is on, colours matched to the
  UI by the area they cover, with a colour-intensity slider). Every theme except Wallpaper can be
  edited colour by colour and reset to its original palette.
- Glass mode: Windows acrylic blur behind the windows with tint opacity, rounded corners, and an
  optional frosted copy of the wallpaper behind the glass.
- Displays shown by the names Windows reports (e.g. "Built-in display", "DELL U2720Q").
- Primary display tools: swap primary display (button, tray menu, flyout header, hotkey) and an
  optional guard that switches the primary to the next display when the current primary stops
  answering its DDC/CI power query.
- Standalone executable (no AutoHotkey installation needed), settings kept in an INI file next to
  the exe, "Start with Windows" option.

### Lineage
This release grew out of several private iterations with a native AutoHotkey GUI. The brightness
engine is carried over; the interface was rebuilt on WebView2 for the public release.
