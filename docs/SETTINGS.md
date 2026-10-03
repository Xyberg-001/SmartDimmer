# Settings reference

Every option in Smart Dimmer, where to find it, what it does, and how it is stored. Settings live
in `SmartDimmerSettings.ini` next to `SmartDimmer.exe` (or in `%LOCALAPPDATA%\SmartDimmer` when
the exe's folder is not writable, e.g. Program Files). The file is created on first run and can be
edited by hand while the app is closed.

The layout follows one rule: the **flyout** is for everyday adjusting, **Settings** is for things
you set once, and nothing appears in both. Esc closes either window.

Contents
- [Flyout](#flyout)
- [Settings: Brightness](#settings-brightness)
- [Settings: Warmth](#settings-warmth)
- [Settings: Screens](#settings-screens)
- [Settings: Hotkeys](#settings-hotkeys)
- [Settings: Schedule](#settings-schedule)
- [Settings: Appearance](#settings-appearance)
- [Settings: General](#settings-general)
- [Tray menu](#tray-menu)
- [Startup behaviour](#startup-behaviour)
- [Hotkey syntax](#hotkey-syntax)
- [INI file reference](#ini-file-reference)
- [Other files](#other-files)

---

## Flyout

Opened with a left click on the tray icon (a second click hides it); it also hides when it loses
focus or you press Esc. It first appears at the bottom-right of the main screen, next to the tray;
drag it by its header and resize it at any edge, and it remembers where you put it. Its size is
remembered separately for each combination of screens using their own sliders.

| Control | What it does | Stored as |
|---|---|---|
| **Brightness: Backlight** | Shared backlight level, 0 to 100 %, sent to every screen ticked under it. Changes the monitor itself (DDC/CI on external monitors, WMI on the laptop panel). Hidden while any screen uses its own sliders. | `[Settings] LastHardwareBright` |
| **Brightness: Software brightness** | Shared software level, 0 to 100 %, applied through the gamma ramp to every screen ticked under it. Can go darker than the monitor's minimum. Hidden while any screen uses its own sliders. | `[Settings] LastSoftwareDim` |
| **Applies to** ticks (one per screen, under each shared slider) | Untick a screen to stop that adjustment on it at once. Software brightness returns to normal immediately; the backlight stays where it is. The same two ticks also appear on a screen's own sliders, and on its card while the shared sliders are hidden, so every screen's ticks are always one click away. | Backlight: `[Settings] TargetMonitorIDs` (comma-separated screen numbers); Software: `[Settings] Dim_M<n>` |
| **Move both together** | Moving one shared slider moves the other by the same amount. | `[Settings] LinkHardwareSoftware` (default 1) |
| **Warmth** (its own section, below Brightness) | Colour temperature, shown in kelvin: *Off* (0, neutral 6500 K) to 1900 K (100, candlelight). Shifts the colours towards orange to cut blue light in the evening. Always shown, including while screens use their own sliders. Each screen has its own **Applies to** tick under the slider, separate from the Software tick: a screen can be warmed without software brightness, or dimmed without warmth. If Windows Night Light is on too, a warning under the slider says so: both tint the screen and the effects add up. Moving it while the warmth schedule is on pauses the schedule until the next part of the day. | `[Settings] Warmth` (0-100, default 0) |
| **Change warmth by time of day** | Turns the warmth schedule on or off and says what it is doing now; **Resume** appears after a manual change. **Edit ›** opens Settings on the Warmth page. | `[WarmSchedule] Enabled` |
| Per screen: **Own sliders** | Gives the screen its own Backlight and Software brightness sliders, which appear under it with their ticks; an unticked slider is greyed out. The shared sliders hide while any screen uses its own. A screen's own hotkeys switch this on automatically. | `[MonitorSplit] Split_M<n>`, `HW_M<n>`, `SW_M<n>` |
| **Schedule: Change brightness by time of day** | Turns the schedule on or off and shows which entry is in effect. **Edit ›** opens Settings on the Schedule page. | `[Schedule] Enabled` |
| Header: **⇄** | Make the next screen the main one (see Settings > Screens). | |
| Header: **👁** | Identify: shows each screen's number and name on it for 2.5 s. | |
| Header: **⚙** | Opens Settings. | |

## Settings: Brightness

How the sliders and hotkeys behave. The sliders themselves are in the flyout.

| Control | What it does | Stored as |
|---|---|---|
| **Move backlight and software brightness together** | Same switch as in the flyout. | `[Settings] LinkHardwareSoftware` |
| **Hotkey step** | Percent added or removed per hotkey press, 1 to 20. | `[Settings] HardwareStep` (default 2) |
| **Smooth transitions** | Software brightness and warmth fade over about 200 ms instead of jumping, when they change by more than 4 %. Hotkey steps and slider drags stay instant. The backlight is not faded: monitors apply DDC/CI changes at their own pace. | `[Settings] Smooth` (0/1, default 1) |
| **Software dimming curve: Type** | `Linear` maps the software slider straight to the gamma ramp; `Exponential` bends the mapping so the dark end has finer control. The preview shows the mapping. | `[Settings] CurveType` (`linear`/`exponential`) |
| **Invert curve** | Mirrors the exponential curve (fine control at the bright end instead). | `[Settings] InvertCurve` (0/1) |
| **Curve factor** | Exponent of the exponential curve, 1.0 to 5.0. | `[Settings] ExponentialFactor` (default 2.5) |
| **Darkest software level (0-255)** | How dark software brightness goes at 0 %: the gamma ramp is scaled so that white maps to this value (255 = no dimming possible, 0 = fully black). | `[Settings] MaxSoftwareDarkness` (default 180) |

## Settings: Warmth

A warmth schedule in the style of f.lux, separate from the brightness schedule. The day has three
parts, each with a start time and a warmth; the timeline shows the resulting warmth from noon to
noon, coloured like the light at each moment, with a line at the current time.

| Control | What it does | Stored as |
|---|---|---|
| **Change warmth by time of day** | Turns the warmth schedule on (checked every 15 s). Same switch as in the flyout. Turning it off leaves the warmth where it is; set the flyout slider to *Off* for neutral colour. | `[WarmSchedule] Enabled` (default 0) |
| **Daytime**: Starts at, Warmth | When the day begins and its warmth (normally *Neutral*). | `DaytimeFrom` (default 07:00), `DaytimeLevel` (default 0) |
| **Evening**: Starts at, Warmth | When the evening begins and how warm it is. | `EveningFrom` (default 20:00), `EveningLevel` (default 60, 3740 K) |
| **Bedtime**: Starts at, Warmth | When bedtime begins and how warm it is, usually the warmest part. | `BedtimeFrom` (default 23:00), `BedtimeLevel` (default 80, 2820 K) |
| **Transition** | How long each change takes: Instant, 20 min, 1 hour or 2 hours. A part of the day starts changing at its time, so with 1 hour, Bedtime at 23:00 is fully warm at midnight and Daytime at 07:00 is neutral by 08:00. A transition never runs past the start of the next part. The note under it spells this out with your own times. | `[WarmSchedule] FadeMinutes` (default 60) |

Times are 24-hour (21:30); 2130, 9 and 9:30 pm are understood too, and anything else puts the old time
back. A time is applied when you leave its field or press Enter, not while you type. Times wrap past
midnight, and the three parts can be in any order. Moving a part's slider shows that
warmth on the screens for 2 seconds as a preview. Moving the Warmth slider in the flyout pauses the
schedule until the next part of the day begins. The Warmth ticks (flyout, Screens page) choose which
screens are warmed.

## Settings: Screens

What each screen responds to, and which screen is the main one. **Identify screens** shows each
screen's number and name on it.

| Control | What it does | Stored as |
|---|---|---|
| Per screen: **Change its backlight** | Same as the flyout's Backlight tick: whether Smart Dimmer changes this screen's backlight at all (shared slider, own slider, hotkeys, schedule). Screen 1 (normally the laptop panel) is driven through WMI, the others through DDC/CI. | `[Settings] TargetMonitorIDs` (comma-separated screen numbers, default `2`); `LinkAllDisplays=1` from older versions means all screens |
| Per screen: **Change its software brightness** | Same as the flyout's Software tick: whether software brightness applies to this screen. Unticked, the screen returns to normal brightness at once. | `[Settings] Dim_M<n>` (default 1) |
| Per screen: **Apply warmth** | Same as the flyout's Warmth tick: whether the warmth filter applies to this screen. Independent of software brightness. | `[Settings] Warm_M<n>` (default 1) |
| **Main screen** card | Shows the current main (primary) screen, how many screens are connected, and the last power check or switch. | |
| **Make the next screen main** | Makes the next screen in Windows' order the primary one (with two screens: a swap). Every screen is repositioned so the new primary sits at the origin, the way Display Settings does it. Also in the tray menu, the flyout header and an optional hotkey. Windows may renumber screens afterwards; the names always tell you which screen is which. | |
| **Switch the main screen automatically when it loses power** | Every 5 s the main screen is asked for its power state over DDC/CI (VCP code D6). If it reports off, or stops answering after having answered before, for 3 checks in a row while another screen is not off, the next screen becomes main. Ignored while Windows itself has the screens off to save power. Laptop panels cannot be checked. | `[Settings] PrimaryGuard` (0/1, default 0) |

## Settings: Hotkeys

Keyboard shortcuts that work everywhere. Click a box, press the combination (mouse buttons work
too); Esc clears it. A key can only live in one box; assigning it elsewhere clears the old box.
Shortcuts are shown as you would say them ("Ctrl + Up") and stored in AutoHotkey notation.

| Row | What it does | Stored as |
|---|---|---|
| **All screens** | Backlight up/down and Software up/down for the shared level. | `[Settings] HotkeyUp`, `HotkeyDown`, `HotkeySWUp`, `HotkeySWDown` (defaults `^Up`, `^Down`, `#Up`, `#Down`) |
| One row per screen | The same for one screen only; switches that screen to its own sliders. | `[MonitorHotkeys] <n>_HWUp`, `<n>_HWDown`, `<n>_SWUp`, `<n>_SWDown` |
| **Make the next screen main** | Same as the button on the Screens page. | `[Settings] HotkeyFlip` |
| **Show an on-screen indicator** | When a brightness hotkey is used, a small bar in the theme's colours appears near the bottom of the screen with the new level, then fades after about 1.3 s. A screen's own hotkeys show it on that screen; the all-screens hotkeys show it on the screen under the mouse. It never takes focus and clicks pass through it. Switching it on shows a preview. | `[Settings] Osd` (0/1, default 1) |

## Settings: Schedule

| Control | What it does | Stored as |
|---|---|---|
| **Change brightness by time of day** | Turns the scheduler on (checked every 20 s). Same switch as in the flyout. Warmth has its own schedule (see [Settings: Warmth](#settings-warmth)). | `[Schedule] Enabled` |
| **Apply now** | Applies the entry that is currently due. | |
| **Rows 1-8**: On, Time (HH:mm), Backlight %, Software % | Each enabled row sets both levels at its time. The latest enabled time at or before now is in effect; before the first time of the day the last entry of the previous day applies (wrap past midnight). **Use current** copies the current levels into the row. | `[Schedule] Row<n>` = `on|HH:mm|backlight|software` |
| **Fade into each entry over** | Minutes over which levels move from the previous entry to the new one (0 = jump). | `[Schedule] FadeMinutes` (0-120) |
| **Also change screens that use their own sliders** | Whether scheduled levels are also written to screens using their own sliders. | `[Schedule] IncludeIndependent` (default 1) |

Moving a brightness slider or using a hotkey pauses the schedule until the next entry becomes due.

## Settings: Appearance

| Control | What it does | Stored as |
|---|---|---|
| **Theme tiles** | Lava Orange, Aqua Blue, Emerald Green, Lavender Pink, Milky Way, Amber Night, Synthwave, Tokyo Night, Nord Frost, Graphite, Cyber Neon, Northern Lights, Wallpaper, Sky, Custom. **Northern Lights** is a polar night sky: aurora green into violet over deep blue-teal; with lively effects on, aurora curtains sway slowly across the top of the window over faint stars. **Sky** is generated: its colours follow the height of the sun (night, blue hour, sunrise and sunset, golden hour, day) and are tinted by the weather (grey when cloudy, slate when raining, icy when snowing, violet with yellow when stormy, muted in fog); it is recalculated every minute. It uses the place set under Automatic theme; without one, a stand-in sun rises at 06:30 and sets at 19:30. Each theme pairs an accent with a second accent (for example orange with hot pink, aqua with indigo, amber with red, pink with gold). Amber Night contains no blue, for use at night. | `[Settings] Theme` |
| **Lively effects** | Soft, slowly drifting glows in the theme's two accents behind the cards, and two-tone gradients on sliders, switches, readouts, primary buttons and the title. Off gives the flat, single-accent look. The drift stops when Windows is set to reduce animations. | `[Settings] Lively` (0/1, default 1) |
| **Wallpaper theme: colour intensity** (Wallpaper only) | The Wallpaper theme reads the wallpaper of the screen each window is on, ranks its colours by the area they cover (including the neutral black/grey mass), ranks the window's own colour groups by the area they cover (cards, background, buttons, lines, slider fills, accents), and pairs them in order. This slider (25-100 %) sets how far the colours are pushed into panels and surfaces. Palettes refresh when the wallpaper changes, every 30 s (slideshows), and when a window moves to another screen. | `[Settings] WpIntensity` (default 70) |
| **Frosted wallpaper behind the glass** (Wallpaper only) | With glass on: draw a frosted copy of the wallpaper area behind the window (aligned to the screen, following the window) over the real blur, so the window looks like glass on your wallpaper even when other apps are behind it. | `[Settings] WpFrost` (0/1, default 0) |
| **Automatic theme: Change the theme with the time of day and the weather** | Shows a palette blended from your chosen themes, recalculated every minute, so every part of the day with every kind of weather looks different. Around dawn and dusk the neighbouring parts of the day cross-fade as the sun moves (in 5 % steps); the weather's theme is then mixed in. Surfaces, lines and text are mixed; accents are mixed when their colours are close, and when they are far apart (amber and blue, say) the leading theme keeps its accent and the other theme's accent becomes the second accent, so gradients and glows run between the two. The status line names the themes and shares. Picking a theme tile by hand turns it off; turning it off returns to the theme you had before. | `[Environment] AutoTheme` (0/1, default 0), `ManualTheme` |
| **Place** (shown while the automatic theme or Sky is in use) | Search for a city or town and pick it from the list. Sunrise, sunset and the parts of the day are calculated on the PC from its coordinates. The current weather is fetched from Open-Meteo every 20 minutes (only the coordinates are sent); **Update weather** fetches it now, **Forget place** removes it. Without a place, the parts of the day follow the clock (morning 06:00, day 09:00, evening 17:00, night 20:30) and weather is not used. Times are shown on this PC's clock. | `[Environment] Place`, `Latitude`, `Longitude` |
| **Theme for each part of the day**: Morning, Day, Evening, Night | With a place: night while the sun is more than 8 degrees below the horizon, cross-fading into morning (or from evening) between 8 and 2 degrees below; morning and evening while the sun is low; cross-fading into day around 12 degrees (less in winter and far north). Without a place: half-hour cross-fades around 06:00, 09:00, 17:00 and 20:30. Each slot's badge shows its share of the palette now (**Now** = 100 %). | `[Environment] Theme_Morning` (Lavender Pink), `Theme_Day` (Aqua Blue), `Theme_Evening` (Amber Night), `Theme_Night` (Milky Way) |
| **Theme mixed in while the weather is**: Cloudy, Rain, Snow, Storm, Fog | Mixed into the time-of-day palette while that weather lasts. **No change** leaves that weather out. Clear and partly cloudy skies add nothing. Weather older than 3 hours is ignored. | `[Environment] Theme_Cloudy` (Graphite), `Theme_Rain` (Tokyo Night), `Theme_Snow` (Nord Frost), `Theme_Storm` (Cyber Neon), `Theme_Fog` (Sky) |
| **How much the weather colours the theme** | Share of the weather's theme in the mix, 10-100 %. | `[Environment] WeatherStrength` (default 45) |
| **Weather colours the theme**: In daylight / Day and night | With *In daylight*, nights are never tinted by the weather. | `[Environment] WeatherScope` (`always` default, `day`) |
| **Transparent glass** | Windows acrylic blur behind both windows, with rounded corners. Requires Windows 10 1803+ or Windows 11. | `[Settings] Glass` (0/1, default 0) |
| **Tint opacity** | How strongly the theme's background colour covers the blur, 20-95 %. | `[Settings] GlassOpacity` (default 65) |
| **Colours of <theme>** | 15 colour pickers for the selected theme: window background; panels, cards, title bar; separators and borders; text; secondary text; accent (titles, readouts, curve); second accent (gradients and glow); button face; button text; switches and checkboxes (on); slider track; slider filled part; slider thumb; curve preview background; curve preview grid. Changes apply live and are remembered per theme. **Reset to original** restores the built-in palette; **Copy to Custom** clones the theme into Custom. Under Wallpaper or Sky, picking a colour copies the generated palette into Custom and switches to it. | Custom: `[CustomTheme] <slot>`; presets: `[Theme_<NameWithoutSpaces>] <slot>` (e.g. `[Theme_AquaBlue]`) |

Colour slot keys: `bg`, `input`, `line`, `text`, `muted`, `accent`, `accent2`, `btnFace`, `btnText`,
`checkOn`, `sliderTrack`, `sliderFill`, `sliderThumb`, `graphBg`, `grid` (six-digit hex, no `#`). A theme
saved by an older version without `accent2` uses its preset's second accent.

## Settings: General

| Control | What it does | Stored as |
|---|---|---|
| **Start with Windows** | Creates or removes `SmartDimmer.lnk` in your Startup folder. The shortcut passes `/startup`, which makes Smart Dimmer wait for the desktop before opening its windows. | the shortcut itself |
| **Free memory when the windows are closed** | A minute after both windows are closed, the window engine (Microsoft Edge WebView2) is shut down completely: none of Smart Dimmer's `msedgewebview2.exe` processes stay running, and the app itself uses about 10 MB. Hotkeys, both schedules, the automatic theme and the on-screen indicator keep working. Opening a window after that takes about a second while WebView2 starts. Off: the windows stay loaded (asleep, about 170-250 MB private, mostly paged out) and open instantly. | `[Settings] FreeMemory` (0/1, default 1) |
| **Save current as defaults** | Snapshots everything: brightness, screens, hotkeys, schedule, curve, theme, theme colour edits, glass, wallpaper options. | `[Defaults]` section, `Saved=1` |
| **Restore my defaults** | Applies the snapshot. | |
| **Factory reset** | Applies the built-in factory values (keeps your saved defaults). | |
| **Load my defaults at startup instead of last-used values** | Applies the snapshot each time the app starts. | `[Settings] UseDefaultsAtStartup` |
| **About**: Open folder / Project page | Opens the folder holding the settings and log, or the GitHub page. | |

## Tray menu

Right-click the tray icon: **Show / hide Smart Dimmer**, **Settings...**, **Swap primary display**,
**Exit**. Left click toggles the flyout.

## Startup behaviour

The brightness engine (hotkeys, schedule, main-screen guard) starts immediately and does not depend
on the windows. The windows need the Microsoft Edge WebView2 Runtime, which is sometimes not ready
right after logon or while it updates itself. Smart Dimmer then retries after 3, 5, 10, 15, 30 and 60
seconds instead of stopping; if it still cannot open them it shows a tray notification, keeps
running, and tries again when you click the tray icon. Unexpected errors are written to the log with
their details instead of interrupting you with an error dialog.

## Hotkey syntax

Hotkeys are shown as "Ctrl + Up" in the app and stored in AutoHotkey notation in the INI: `^` Ctrl,
`!` Alt, `+` Shift, `#` Win, followed by the key name (`Up`, `F9`, `NumpadAdd`, `XButton1`, ...).
Examples: `^Up`, `^+F9`, `#Down`, `XButton2` (mouse forward). Capture them from the UI rather than
typing them; an unbindable combination is reported in the log.

## INI file reference

| Section | Keys |
|---|---|
| `[Settings]` | `LastHardwareBright`, `LastSoftwareDim`, `TargetMonitorIDs`, `LinkAllDisplays`, `LinkHardwareSoftware`, `CurveType`, `InvertCurve`, `ExponentialFactor`, `MaxSoftwareDarkness`, `HardwareStep`, `HotkeyUp`, `HotkeyDown`, `HotkeySWUp`, `HotkeySWDown`, `HotkeyFlip`, `PrimaryGuard`, `Dim_M<n>`, `Warm_M<n>`, `Warmth`, `Smooth`, `Osd`, `Theme`, `Glass`, `GlassOpacity`, `WpIntensity`, `WpFrost`, `Lively`, `UseDefaultsAtStartup` |
| `[Position]` | `X`, `Y` (flyout), `W`, `H` (flyout, no independent displays), `W_Split_<n>[_<m>...]`, `H_Split_...` (flyout size per combination of independent displays), `SettingsW`, `SettingsH` |
| `[MonitorSplit]` | `Split_M<n>`, `HW_M<n>`, `SW_M<n>` |
| `[MonitorHotkeys]` | `<n>_HWUp`, `<n>_HWDown`, `<n>_SWUp`, `<n>_SWDown` |
| `[Schedule]` | `Enabled`, `FadeMinutes`, `IncludeIndependent`, `Row1` ... `Row8` |
| `[WarmSchedule]` | `Enabled`, `FadeMinutes`, `DaytimeFrom`, `DaytimeLevel`, `EveningFrom`, `EveningLevel`, `BedtimeFrom`, `BedtimeLevel` |
| `[CustomTheme]` | the 14 colour slots of Custom |
| `[Theme_<Name>]` | colour slots of an edited preset (section absent = original palette) |
| `[Environment]` | `AutoTheme`, `WeatherScope`, `WeatherStrength`, `ManualTheme`, `Place`, `Latitude`, `Longitude`, `Theme_Morning`, `Theme_Day`, `Theme_Evening`, `Theme_Night`, `Theme_Cloudy`, `Theme_Rain`, `Theme_Snow`, `Theme_Storm`, `Theme_Fog` |
| `[Defaults]` | flat snapshot (`HardwareBright`, `SoftwareDim`, `Split_M<n>`, `HW_M<n>`, `SW_M<n>`, `Dim_M<n>`, `Warm_M<n>`, `HK_<n>_<kind>`, `Custom_<slot>`, `Theme_<Name>_<slot>`, `Sched_*`, `WS_*` (warmth schedule), `Env_*` (automatic theme and place), `Glass`, `GlassOpacity`, `WpIntensity`, `WpFrost`, `Lively`, `Warmth`, `Smooth`, `Osd`, `HotkeyFlip`, `PrimaryGuard`, ...) plus `Saved=1` |

Display numbers `<n>` follow Windows' monitor order (shown as `#1`, `#2` next to the names).

## Other files

| File | Purpose |
|---|---|
| `SmartDimmerDebug.log` (next to the settings file) | Diagnostic log, recreated at every start and rolled over to `.old` past 2 MB. Contains start-up steps, brightness routing, hotkey binding, schedule, display and glass events, and any error with its call stack. Attach it to bug reports. |
| `WebView2Loader.dll`, `SmartDimmerUI.html` (next to the settings file) | Extracted from the exe on every start; do not edit, they are overwritten. |
| `%TEMP%\SmartDimmerWebView\` | WebView2 profile (cache) and, under `wallpaper\`, downscaled copies of wallpapers used by the Wallpaper theme. Safe to delete while the app is closed. |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\SmartDimmer.lnk` | Created by "Start with Windows". |
