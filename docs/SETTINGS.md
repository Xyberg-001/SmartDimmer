# Settings reference

Every option in Smart Dimmer, where to find it, what it does, and how it is stored. Settings live
in `SmartDimmerSettings.ini` next to `SmartDimmer.exe`; the file is created on first run and can
be edited by hand while the app is closed.

Contents
- [Flyout](#flyout)
- [Settings: Brightness](#settings-brightness)
- [Settings: Monitors & keys](#settings-monitors--keys)
- [Settings: Schedule](#settings-schedule)
- [Settings: Appearance](#settings-appearance)
- [Settings: Defaults](#settings-defaults)
- [Tray menu](#tray-menu)
- [Hotkey syntax](#hotkey-syntax)
- [INI file reference](#ini-file-reference)
- [Other files](#other-files)

---

## Flyout

Opened with a left click on the tray icon (a second click hides it); it also hides when it loses
focus. Drag it by its header, resize it at any edge. Its size is remembered separately for each
combination of independent monitors.

| Control | What it does | Stored as |
|---|---|---|
| **Targets** | Comma-separated monitor numbers that receive hardware (backlight) commands, e.g. `2` or `2,3`. Numbers are shown next to each display name. Monitor 1 is treated as the laptop panel and is driven through WMI when it is a target. | `[Settings] TargetMonitorIDs` (default `2`) |
| **Link all** | Send the hardware level to every monitor regardless of Targets. | `[Settings] LinkAllDisplays` (0/1, default 0) |
| **Schedule** switch | Enables the time-of-day schedule (see Schedule page). | `[Schedule] Enabled` |
| **Hardware backlight** | Master backlight level, 0 to 100 %. Hidden while any monitor is Independent. | `[Settings] LastHardwareBright` |
| **Software brightness** | Master software dimming level, 0 to 100 %, applied through the gamma ramp. Hidden while any monitor is Independent. | `[Settings] LastSoftwareDim` |
| **Move hardware and software together** | Moving one master slider moves the other. | `[Settings] LinkHardwareSoftware` (default 1) |
| Per display: **Dim** | Whether software dimming applies to this display. | `[Settings] Dim_M<n>` (default 1) |
| Per display: **Follows master / Independent** | Independent gives the display its own hardware and software sliders; the master sliders hide while any display is independent. Per-display hotkeys switch a display to Independent automatically. | `[MonitorSplit] Split_M<n>`, `HW_M<n>`, `SW_M<n>` |
| Header: **⇄** | Swap primary display (see Monitors & keys). | |
| Header: **👁** | Identify: shows each display's number and name on it for 2.5 s. | |
| Header: **⚙** | Opens Settings. | |

## Settings: Brightness

| Control | What it does | Stored as |
|---|---|---|
| **Monitor targets** / **Link all displays** | Same as in the flyout. | as above |
| **Hardware backlight / Software brightness / Move together** | Same as in the flyout. | as above |
| **Dimming curve: Type** | `Linear` maps the software slider straight to the gamma ramp; `Exponential` bends the mapping so the low end has finer control. The preview shows the mapping. | `[Settings] CurveType` (`linear`/`exponential`) |
| **Invert curve** | Mirrors the exponential curve (fine control at the top end instead). | `[Settings] InvertCurve` (0/1) |
| **Curve factor** | Exponent of the exponential curve, 1.0 to 5.0. | `[Settings] ExponentialFactor` (default 2.5) |
| **Max dimming (0-255)** | How dark software dimming can go: the gamma ramp at 0 % is scaled so that white maps to this value (255 = no dimming possible, 0 = fully black). | `[Settings] MaxSoftwareDarkness` (default 180) |
| **Hotkey step** | Percent added or removed per hotkey press, 1 to 20. | `[Settings] HardwareStep` (default 2) |
| **Start with Windows** | Creates or removes `SmartDimmer.lnk` in your Startup folder pointing at this exe. | the shortcut itself |
| **Load my defaults at startup** | See Defaults page. | `[Settings] UseDefaultsAtStartup` |

## Settings: Monitors & keys

| Control | What it does | Stored as |
|---|---|---|
| Per display cards | Apply dim, Follows master / Independent, own sliders (same as flyout). | as above |
| **Primary display** card | Shows the current primary (name, number, device, count of active displays) and the last power check / switch event. | |
| **Swap primary display** | Makes the next display in Windows' order the primary one (with two displays: a swap). Every display is repositioned so the new primary sits at the origin, the way Display Settings does it. Also in the tray menu and the flyout header. Note: Windows may renumber displays afterwards; the names always tell you which screen a card refers to. | |
| **Auto-switch the primary display when it stops receiving power** | Every 5 s the primary monitor is asked for its power state over DDC/CI (VCP code D6). If it reports off, or stops answering after having answered before, for 3 checks in a row while another display is not off, the next display becomes primary. Ignored while Windows itself has the displays off to save power. Laptop panels cannot be checked. | `[Settings] PrimaryGuard` (0/1, default 0) |
| **Swap hotkey** | Global hotkey for Swap primary display. | `[Settings] HotkeyFlip` |
| **Hotkeys grid** | Master row: hardware up/down and software up/down for the master level. Display rows: the same for one display only (switches it to Independent). Click a box, press the combination (mouse buttons work), Esc clears. A key can only live in one box; assigning it elsewhere clears the old box. | master: `[Settings] HotkeyUp`, `HotkeyDown`, `HotkeySWUp`, `HotkeySWDown` (defaults `^Up`, `^Down`, `#Up`, `#Down`); per display: `[MonitorHotkeys] <n>_HWUp` etc. |

## Settings: Schedule

| Control | What it does | Stored as |
|---|---|---|
| **Enable the schedule** | Turns the scheduler on (checked every 20 s). | `[Schedule] Enabled` |
| **Apply now** | Applies the entry that is currently due. | |
| **Rows 1-8**: On, Time (HH:mm), Hardware %, Software % | Each enabled row sets both levels at its time. The latest enabled time at or before now is in effect; before the first time of the day the last entry of the previous day applies (wrap past midnight). **Use current** copies the current levels into the row. | `[Schedule] Row<n>` = `on|HH:mm|hw|sw` |
| **Fade into each entry over** | Minutes over which levels move from the previous entry to the new one (0 = jump). | `[Schedule] FadeMinutes` (0-120) |
| **Also adjust Independent monitors** | Whether scheduled levels are also written to independent displays. | `[Schedule] IncludeIndependent` (default 1) |

Moving a slider or using a hotkey pauses the schedule until the next entry becomes due.

## Settings: Appearance

| Control | What it does | Stored as |
|---|---|---|
| **Theme tiles** | Lava Orange, Aqua Blue, Emerald Green, Lavender Pink, Milky Way, Wallpaper, Custom. | `[Settings] Theme` |
| **Wallpaper theme: colour intensity** (Wallpaper only) | The Wallpaper theme reads the wallpaper of the screen each window is on, ranks its colours by the area they cover (including the neutral black/grey mass), ranks the window's own colour groups by the area they cover (cards, background, buttons, lines, slider fills, accents), and pairs them in order. This slider (25-100 %) sets how far the colours are pushed into panels and surfaces. Palettes refresh when the wallpaper changes, every 30 s (slideshows), and when a window moves to another screen. | `[Settings] WpIntensity` (default 70) |
| **Frosted wallpaper behind the glass** (Wallpaper only) | With glass on: draw a frosted copy of the wallpaper area behind the window (aligned to the screen, following the window) over the real blur, so the window looks like glass on your wallpaper even when other apps are behind it. | `[Settings] WpFrost` (0/1, default 0) |
| **Transparent glass** | Windows acrylic blur behind both windows, with rounded corners. Requires Windows 10 1803+ or Windows 11. | `[Settings] Glass` (0/1, default 0) |
| **Tint opacity** | How strongly the theme's background colour covers the blur, 20-95 %. | `[Settings] GlassOpacity` (default 65) |
| **Colours of <theme>** | 14 colour pickers for the selected theme: window background; panels, cards, title bar; separators and borders; text; secondary text; accent (titles, readouts, curve); button face; button text; switches and checkboxes (on); slider track; slider filled part; slider thumb; curve preview background; curve preview grid. Changes apply live and are remembered per theme. **Reset to original** restores the built-in palette; **Copy to Custom** clones the theme into Custom. Under Wallpaper, picking a colour copies the generated palette into Custom and switches to it. | Custom: `[CustomTheme] <slot>`; presets: `[Theme_<NameWithoutSpaces>] <slot>` (e.g. `[Theme_AquaBlue]`) |

Colour slot keys: `bg`, `input`, `line`, `text`, `muted`, `accent`, `btnFace`, `btnText`, `checkOn`,
`sliderTrack`, `sliderFill`, `sliderThumb`, `graphBg`, `grid` (six-digit hex, no `#`).

## Settings: Defaults

| Control | What it does | Stored as |
|---|---|---|
| **Save current as defaults** | Snapshots everything: brightness, targets, per-display settings, hotkeys, schedule, curve, theme, theme colour edits, glass, wallpaper options. | `[Defaults]` section, `Saved=1` |
| **Restore my defaults** | Applies the snapshot. | |
| **Factory reset** | Applies the built-in factory values (keeps your saved defaults). | |
| **Load my defaults at startup instead of last-used values** | Applies the snapshot each time the app starts. | `[Settings] UseDefaultsAtStartup` |

## Tray menu

Right-click the tray icon: **Show / hide Smart Dimmer**, **Settings...**, **Swap primary display**,
**Exit**. Left click toggles the flyout.

## Hotkey syntax

Hotkeys are stored in AutoHotkey notation: `^` Ctrl, `!` Alt, `+` Shift, `#` Win, followed by the
key name (`Up`, `F9`, `NumpadAdd`, `XButton1`, ...). Examples: `^Up`, `^+F9`, `#Down`, `XButton2`.
Capture them from the UI rather than typing them; an unbindable combination is reported in the log.

## INI file reference

| Section | Keys |
|---|---|
| `[Settings]` | `LastHardwareBright`, `LastSoftwareDim`, `TargetMonitorIDs`, `LinkAllDisplays`, `LinkHardwareSoftware`, `CurveType`, `InvertCurve`, `ExponentialFactor`, `MaxSoftwareDarkness`, `HardwareStep`, `HotkeyUp`, `HotkeyDown`, `HotkeySWUp`, `HotkeySWDown`, `HotkeyFlip`, `PrimaryGuard`, `Dim_M<n>`, `Theme`, `Glass`, `GlassOpacity`, `WpIntensity`, `WpFrost`, `UseDefaultsAtStartup` |
| `[Position]` | `X`, `Y` (flyout), `W`, `H` (flyout, no independent displays), `W_Split_<n>[_<m>...]`, `H_Split_...` (flyout size per combination of independent displays), `SettingsW`, `SettingsH` |
| `[MonitorSplit]` | `Split_M<n>`, `HW_M<n>`, `SW_M<n>` |
| `[MonitorHotkeys]` | `<n>_HWUp`, `<n>_HWDown`, `<n>_SWUp`, `<n>_SWDown` |
| `[Schedule]` | `Enabled`, `FadeMinutes`, `IncludeIndependent`, `Row1` ... `Row8` |
| `[CustomTheme]` | the 14 colour slots of Custom |
| `[Theme_<Name>]` | colour slots of an edited preset (section absent = original palette) |
| `[Defaults]` | flat snapshot (`HardwareBright`, `SoftwareDim`, `Split_M<n>`, `HW_M<n>`, `SW_M<n>`, `Dim_M<n>`, `HK_<n>_<kind>`, `Custom_<slot>`, `Theme_<Name>_<slot>`, `Sched_*`, `Glass`, `GlassOpacity`, `WpIntensity`, `WpFrost`, `HotkeyFlip`, `PrimaryGuard`, ...) plus `Saved=1` |

Display numbers `<n>` follow Windows' monitor order (shown as `#1`, `#2` next to the names).

## Other files

| File | Purpose |
|---|---|
| `SmartDimmerDebug.log` (next to the exe) | Diagnostic log, recreated at every start. Contains brightness routing, hotkey binding, schedule, display and glass events. Attach it to bug reports. |
| `WebView2Loader.dll`, `SmartDimmerUI.html` (next to the exe) | Extracted from the exe on every start; do not edit, they are overwritten. |
| `%TEMP%\SmartDimmerWebView\` | WebView2 profile (cache) and, under `wallpaper\`, downscaled copies of wallpapers used by the Wallpaper theme. Safe to delete while the app is closed. |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\SmartDimmer.lnk` | Created by "Start with Windows". |
