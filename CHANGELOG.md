# Changelog

All notable changes to Smart Dimmer are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

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
