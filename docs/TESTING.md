# Testing without touching your monitors

The engine writes to real hardware (DDC/CI backlight, WMI, gamma ramps), binds global hotkeys and
can change the display topology. To exercise the UI and the logic safely, build a stubbed copy of
the engine and append a test sequence to it:

1. Copy `src/SmartDimmer.ahk` to a scratch folder together with `src/SmartDimmerUI.html` and the
   `src/lib` folder.
2. In the copy, insert `if (true) return` as the first line of `NativeSetMonitorBrightness`,
   `SetMonitorGammaRamp` (return `true`) and `UpdateActiveHotkeys`, make `SetPrimaryDisplayDevice`
   log and return `true`, and let `QueryMonitorPowerState` return a value from a test map when one
   is set. Point `iniFile` / `logFile` at `TEST_*.ini` / `TEST_*.log`.
3. Append a `SetTimer(TestSequence, -1500)` and a `TestSequence()` that shows the windows
   (`ShowDashboard()`, `ShowSettingsWindow()`), disables the focus-loss timer, drives the page with
   `host.core.ExecuteScriptAsync("post('setHW','72')")`, reads engine globals, and takes
   screenshots. Log with `LogAction`.
4. Run it with `AutoHotkey64.exe /ErrorStdOut test.ahk` and read `TEST_SmartDimmerDebug.log`.

Things learned the hard way:

- Never call the synchronous `ExecuteScript` or `.await()` inside a WebView2 callback.
- AutoHotkey variable names are case-insensitive: a loop that uses `w` as a weight inside a loop
  bounded by `W` runs once. The same for `t` and `T`.
- A window message sequence is not a real drag: verify drag behaviour with real mouse input from a
  separate process, because the app's own thread sits inside the modal move loop.
- Measure blur with a striped backdrop (stripe sharpness), not with a flat colour (a transparent
  window and a blurred one average to the same value).
