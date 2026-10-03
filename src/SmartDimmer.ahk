; =========================================================================================
; Smart Dimmer - hardware backlight and software dimming for every monitor (Windows 10/11)
;
; https://github.com/Xyberg-001/SmartDimmer               Licence: MIT (see LICENSE)
;
; Engine (this file, AutoHotkey v2) + user interface (SmartDimmerUI.html rendered by Microsoft
; Edge WebView2). The page renders from a JSON state pushed by the engine and sends back
; "command|arg|arg" strings. See docs/ARCHITECTURE.md for the message protocol.
;
; Layout: src/SmartDimmer.ahk, src/SmartDimmerUI.html, src/lib/ (WebView2 binding by thqby, MIT;
; WebView2Loader.dll by Microsoft). Build with build.ps1 (Ahk2Exe embeds the page and the DLL).
; =========================================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
;@Ahk2Exe-SetName Smart Dimmer
;@Ahk2Exe-SetDescription Smart Dimmer - hardware backlight and software dimming for every monitor
;@Ahk2Exe-SetVersion 1.1.0.0
;@Ahk2Exe-SetProductName Smart Dimmer
;@Ahk2Exe-SetCopyright Copyright (c) 2026 Munib Uddin - MIT License
#Include lib\WebView2.ahk
ProcessSetPriority "High"
A_IconTip := "Smart Dimmer 1.1"

global APP_VERSION := "1.1"
; Settings, log and the extracted UI files live next to the exe when that folder is writable (portable use),
; otherwise (e.g. Program Files) in %LOCALAPPDATA%\SmartDimmer.
ResolveDataDir() {
    probe := A_ScriptDir . "\.smartdimmer-write-test"
    try {
        FileAppend("", probe)
        FileDelete(probe)
        return A_ScriptDir
    }
    dir := EnvGet("LOCALAPPDATA") . "\SmartDimmer"
    try DirCreate(dir)
    return dir
}
global dataDir := ResolveDataDir()
global iniFile := dataDir . "\SmartDimmerSettings.ini"
global startupLink := A_Startup . "\SmartDimmer.lnk"
global logFile := dataDir . "\SmartDimmerDebug.log"
global uiHtmlPath := dataDir . "\SmartDimmerUI.html"
global wvLoaderPath := dataDir . "\WebView2Loader.dll"
global wvDataDir := A_Temp . "\SmartDimmerWebView"
global wpImgDir := wvDataDir . "\wallpaper"          ; downscaled wallpaper copies served to the page as https://wallpaper.smartdimmer/

; ---- brightness state ----
global hardwareStep := 2, minHardwareBrightness := 0, maxHardwareBrightness := 100
global maxSoftwareDarkness := 180, dimmingCurve := "linear", exponentialFactor := 2.5, invertCurve := 0
global fallbackBrightness := 50, externalMonitorNum := "2", linkAllDisplays := 0, linkHardwareSoftware := 1
global hotkeyUpString := "^Up", hotkeyDoString := "^Down", hotkeySWUpString := "#Up", hotkeySWDoString := "#Down"
global monitorHotkeys := Map()          ; "mIdx:kind" -> hotkey
global monitorSplitMode := Map(), monitorHW := Map(), monitorSW := Map(), dimStates := Map()
global warmStates := Map()               ; per screen: does the warmth filter apply (independent of the Software tick)
global useDefaultsAtStartup := 0
global warmth := 0                       ; colour warmth 0..100 (0 = neutral 6500 K, 100 = 1900 K), through the software (gamma) path
global smoothTransitions := 1            ; fade software brightness and warmth changes over ~200 ms
global memorySaver := 1                  ; shut WebView2 down a minute after both windows are closed (a few MB instead of ~250 MB)
global MEMORY_SAVER_DELAY := 60000
global osdEnabled := 1                      ; on-screen indicator when a brightness hotkey is used
global WARMTH_K_NEUTRAL := 6500, WARMTH_K_WARMEST := 1900
; Warmth schedule (f.lux style): three parts of the day, each starting at its time with its own warmth; every
; change starts at the part's time and takes warmFadeMin minutes. Separate from the brightness schedule.
global warmSchedEnabled := 0, warmFadeMin := 60
global warmPhases := DefaultWarmPhases()
global warmPausedPhase := "", warmLastKey := "", warmPreviewFrom := ""
; Weather and time of day: an automatic theme per part of the day / kind of weather, and the Sky theme. The place is
; chosen once by name (Open-Meteo geocoding); sunrise and sunset are computed locally from its coordinates, and only
; the current weather is fetched (Open-Meteo, no key), every 20 minutes and only while one of the features is on.
global AUTO_SLOTS := ["Morning", "Day", "Evening", "Night", "Cloudy", "Rain", "Snow", "Storm", "Fog"]
global autoThemeEnabled := 0, autoWeatherScope := "always", autoThemeMap := DefaultAutoThemeMap()
global locName := "", locLat := "", locLon := "", locResults := [], locSearching := 0
global weatherNow := {kind: "", code: "", text: "", temp: "", at: "", tick: 0, error: ""}, weatherFetchTick := 0, envLastSig := ""
global autoWeatherStrength := 45                  ; % of the weather theme mixed into the time-of-day theme
global manualTheme := "Lava Orange"               ; the theme to go back to when the automatic theme is turned off
global autoLastSig := "", autoLastLabel := ""
global lastKnownMonitorCount := MonitorGetCount()
global capturing := ""                  ; "master:HWUp" / "mon:2:SWUp" while a hotkey capture is running

; ---- schedule ----
global SCHED_ROWS := 8
global schedEnabled := 0, schedFade := 0, schedIncludeIndependent := 1
global schedRows := DefaultScheduleRows()
global schedPausedIdx := 0, schedLastApplied := ""

; ---- themes ----
global THEME_ORDER := ["Lava Orange", "Aqua Blue", "Emerald Green", "Lavender Pink", "Milky Way",
                       "Amber Night", "Synthwave", "Tokyo Night", "Nord Frost", "Graphite", "Cyber Neon", "Northern Lights", "Wallpaper", "Sky", "Custom"]
global COLOR_SLOTS := [
    ["bg", "Window background"], ["input", "Panels, cards, title bar"], ["line", "Separators and borders"],
    ["text", "Text"], ["muted", "Secondary text"], ["accent", "Accent (titles, readouts, curve)"],
    ["accent2", "Second accent (gradients and glow)"],
    ["btnFace", "Button face"], ["btnText", "Button text"], ["checkOn", "Switches and checkboxes (on)"],
    ["sliderTrack", "Slider track"], ["sliderFill", "Slider filled part"], ["sliderThumb", "Slider thumb"],
    ["graphBg", "Curve preview background"], ["grid", "Curve preview grid"]]
; accent2 is the second hue each theme blends into (gradients, ambient glow); it defaults to the accent itself
MakeTheme(bg, text, muted, accent, line, input, graphBg, grid, accent2 := "") {
    return {bg: bg, text: text, muted: muted, accent: accent, accent2: (accent2 != "" ? accent2 : accent), line: line, input: input, graphBg: graphBg, grid: grid,
            btnFace: input, btnText: text, checkOn: accent, sliderTrack: line, sliderFill: accent, sliderThumb: accent}
}
CloneTheme(t) {
    global COLOR_SLOTS
    c := {}
    for slot in COLOR_SLOTS
        c.%slot[1]% := t.%slot[1]%
    return c
}
; Palettes (bg, text, muted, accent, line, panel, graphBg, grid, second accent): deep bases, each with an accent
; that blends into a neighbouring second hue.
global THEMES := Map(
    "Lava Orange",   MakeTheme("141417", "F5F5F7", "9A9AA6", "FF8A3D", "2A2A32", "1F1F25", "1A1A1F", "55555F", "FF4D6D"),
    "Aqua Blue",     MakeTheme("0A131B", "EAF4FA", "88A9BB", "38BDF8", "1A2D3B", "11202D", "0E1A24", "31536A", "818CF8"),
    "Emerald Green", MakeTheme("0A1510", "E9F6EE", "86B398", "34D399", "173124", "10211A", "0D1B15", "2E5A45", "A3E635"),
    "Lavender Pink", MakeTheme("16111D", "F6EEF9", "AE97C2", "EC7FD6", "2D2238", "20182D", "1A1425", "56447A", "A78BFA"),
    ; night-sky blue with the galaxy's warm core (pale gold) blending into nebula violet
    "Milky Way",     MakeTheme("070A16", "EEF0FA", "98A0C8", "F5C572", "1D2340", "11162C", "0C1024", "39406E", "B98AF7"),
    ; warm amber into red with no blue in it: easy on the eyes at night
    "Amber Night",   MakeTheme("150D06", "FFF1E0", "C4A07E", "FFA41B", "33220F", "22170C", "1C130A", "6B4A26", "FF5A36"),
    "Synthwave",     MakeTheme("170C24", "F7EEFF", "B39AD0", "FF2E88", "33204A", "221434", "1C1030", "5A3F7E", "FFB547"),
    "Tokyo Night",   MakeTheme("16161E", "E6E8F7", "9AA0C3", "7AA2F7", "2A2C3D", "1E2030", "1A1B26", "414868", "BB9AF7"),
    "Nord Frost",    MakeTheme("1B222C", "ECEFF4", "9AA7B8", "88C0D0", "313B4A", "242D3A", "1F2733", "4C566A", "B48EAD"),
    "Graphite",      MakeTheme("121315", "EDEDEF", "9C9DA3", "E4E4E7", "2A2B2F", "1C1D20", "18191B", "4B4C52", "A1A1AA"),
    "Cyber Neon",    MakeTheme("0B0B12", "F2F2FF", "9A9AB8", "00E5FF", "23233A", "15152A", "11111F", "3A3A66", "F5F500"),
    ; a polar night sky lit by the aurora: luminous green into violet over deep blue-teal (the page adds moving
    ; aurora curtains and faint stars behind it when lively effects are on)
    "Northern Lights", MakeTheme("030912", "ECFFF8", "93D3C8", "2BFFA3", "123848", "071628", "05101E", "1E6475", "C25BFF"),
    "Wallpaper",     MakeTheme("141417", "F5F5F7", "9A9AA6", "FF8A3D", "2A2A32", "1F1F25", "1A1A1F", "55555F", "FF4D6D"),   ; placeholder: computed per screen (see WALLPAPER THEME)
    "Sky",           MakeTheme("0B1624", "EAF1F8", "8FA6BC", "3FB2F5", "20344A", "13233A", "0E1B2C", "3A5773", "4FD1C0"),   ; placeholder: computed from the sun and the weather (see SKY)
    "Custom",        MakeTheme("141417", "F5F5F7", "9A9AA6", "FF8A3D", "2A2A32", "1F1F25", "1A1A1F", "55555F", "FF4D6D"),
    "Automatic",     MakeTheme("141417", "F5F5F7", "9A9AA6", "FF8A3D", "2A2A32", "1F1F25", "1A1A1F", "55555F", "FF4D6D"))   ; computed: blend by time of day and weather (not a tile)
global themeName := "Lava Orange"
; the built-in palettes, kept for "reset to original" (every theme except Wallpaper and Sky can be edited by the user)
global THEME_DEFAULTS := Map()
for _name in THEME_ORDER
    THEME_DEFAULTS[_name] := CloneTheme(THEMES[_name])
; ---- glass (transparent, blur-behind windows) ----
global glassEnabled := 0, glassOpacity := 65      ; opacity of the page tint over the blurred desktop, 20..95 %
global livelyEffects := 1                         ; ambient glows and two-tone gradients from each theme's two accents
global GLASS_RADIUS := 14                         ; px corner radius of the windows in glass mode (the page uses the same value)
global wpIntensity := 70                          ; Wallpaper theme: how strongly the picture's colours are pushed into the UI (25..100)
global wpFrost := 0                               ; Wallpaper theme + glass: draw a frosted copy of the wallpaper behind the window (instead of the live blur only)
; ---- primary display guard + flipper ----
global primaryGuardEnabled := 0, hotkeyFlipString := ""
global PRIMARY_GUARD_INTERVAL := 5000, PRIMARY_GUARD_THRESHOLD := 3     ; 3 bad polls in a row (~15 s) before switching
global guardFailCount := 0, guardBaselineOk := false, guardLastPower := "", guardLastEvent := ""
global consoleDisplayOn := true, powerNotifyHandle := 0                  ; Windows' own display power state (idle timeout / sleep)

; ---- windows ----
global flyout := "", settings := ""     ; host window objects (see CreateHostWindow)
global wvEnv := ""                      ; shared WebView2 environment
; Both windows share one page process (site isolation only matters for web content; these are the app's own
; local pages), no spare process kept warm, no background networking (the pages load nothing from the internet),
; and Edge extras a settings page does not need are off.
global WV_BROWSER_ARGS := "--disable-site-isolation-trials --process-per-site --renderer-process-limit=1 --disable-background-networking --disable-component-update"
    . " --disable-features=SpareRendererForSitePerProcess,Translate,msEdgeTranslate,AutofillServerCommunication,msSmartScreenProtection,OptimizationHints,MediaRouter,msWebOOUI,msPdfOOUI"
global framelessHwnds := Map()          ; hwnd -> {minW, minH}
global WV_INSET := 0                    ; the web view covers the whole client area; the page starts edge resizes itself ("resize" command)

if FileExist(logFile)
    try FileDelete(logFile)
LogAction(message) {
    global logFile
    static writes := 0
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") . " - " . message . "`n", logFile)
    OutputDebug("SmartDimmer: " . message . "`n")
    ; keep the log bounded in long sessions: past 2 MB it is moved to .old and a new one is started
    if (Mod(++writes, 500) == 0)
        try {
            if (FileGetSize(logFile) > 2 * 1024 * 1024)
                FileMove(logFile, logFile . ".old", 1)
        }
}
ErrText(e) => Type(e) . ": " . e.Message . (e.Extra != "" ? " [" . e.Extra . "]" : "") . " (in " . e.What . ", line " . e.Line . ")"

; Any error nobody caught ends up here: it is logged with its call stack and the thread that raised it
; stops, but the app keeps running instead of showing AutoHotkey's error dialog and aborting.
OnError(OnUnexpectedError)
OnUnexpectedError(e, mode) {
    static notified := false
    LogAction("[Error] " . ErrText(e) . " | stack: " . StrReplace(Trim(e.Stack, "`r`n"), "`n", " <- "))
    if (!notified) {
        notified := true
        try TrayTip("Smart Dimmer recovered from an unexpected error. Details are in SmartDimmerDebug.log.", "Smart Dimmer", "Iconi Mute")
    }
    return -1
}
LogAction("Initializing Smart Dimmer v" . APP_VERSION . " (data folder: " . dataDir . ", uptime " . (A_TickCount // 1000) . " s, args: " . (A_Args.Length ? Join(A_Args, " ") : "none") . ")")

global currentHardwareBright := IniRead(iniFile, "Settings", "LastHardwareBright", fallbackBrightness)
global currentSoftwareDim := IniRead(iniFile, "Settings", "LastSoftwareDim", fallbackBrightness)
LoadSettings()
if (useDefaultsAtStartup && IniRead(iniFile, "Defaults", "Saved", "0") == "1") {
    SetGlobalsFromState(ReadStateFromIni("Defaults"))
    LogAction("Applied saved defaults at startup")
}
initialStartupCheck := FileExist(startupLink) ? 1 : 0
UpdateActiveHotkeys()

; =========================================================================
; 🌐 WEBVIEW2 HOST WINDOWS
; =========================================================================
EnsureUiFiles() {
    global wvLoaderPath, uiHtmlPath, dataDir
    ; Compiled: extract the embedded files into the data folder. Uncompiled (data folder = script folder):
    ; the files are already there; point at the sources if the data folder is elsewhere.
    ; NOTE: each FileInstall must start its own line - Ahk2Exe only embeds files for calls written that way
    ; (a "try FileInstall(...)" one-liner is silently NOT embedded).
    try {
        FileInstall("lib\WebView2Loader.dll", dataDir . "\WebView2Loader.dll", 1)
    }
    try {
        FileInstall("SmartDimmerUI.html", dataDir . "\SmartDimmerUI.html", 1)
    }
    if (!A_IsCompiled) {
        if !FileExist(wvLoaderPath)
            wvLoaderPath := A_ScriptDir . "\lib\WebView2Loader.dll"
        if !FileExist(uiHtmlPath)
            uiHtmlPath := A_ScriptDir . "\SmartDimmerUI.html"
    }
    ok := FileExist(wvLoaderPath) && FileExist(uiHtmlPath)
    LogAction("[UI] files ready=" . (ok ? 1 : 0) . " (" . dataDir . ")")
    return ok
}

; Waits for a WebView2 promise. Marks it as observed first: otherwise a promise that fails AFTER the wait
; timed out throws its error from a timer thread later, with nobody left to catch it.
; Waits for a WebView2 promise with a real deadline. (The bundled Promise.await shrinks its remaining time by the
; total elapsed time on every pass of its message loop, so while messages keep arriving a 45 s allowance ran out
; after about a second: a WebView2 start that took 2 s failed with "TimeoutError".) Sleep keeps messages and the
; WebView2 completion callbacks flowing while waiting. Marking the promise as observed stops a late rejection from
; being raised from a timer thread.
AwaitQuietly(p, timeoutMs) {
    p.thrown := true
    deadline := A_TickCount + timeoutMs
    while !ObjHasOwnProp(p, "status") {
        if (A_TickCount > deadline)
            throw TimeoutError("WebView2 did not answer within " . Round(timeoutMs / 1000) . " s")
        Sleep(15)
    }
    if (p.status == "fulfilled")
        return p.result
    throw p.result
}

; Creates a frameless host window with a WebView2 showing the UI page for `view` ("flyout"|"settings").
CreateHostWindow(view, minW, minH) {
    global wvEnv, framelessHwnds, wvDataDir, wvLoaderPath, THEMES, themeName, GLASS_RADIUS, wpImgDir, WV_BROWSER_ARGS
    LogAction("[UI] creating " . view . " window")
    ; (local is named 'win', not 'gui': a local called gui would shadow the Gui class)
    win := Gui("-Caption -MinimizeBox +Resize" . (view == "flyout" ? " +ToolWindow" : " -MaximizeBox"), "Smart Dimmer" . (view == "settings" ? "  -  Settings" : ""))
    win.BackColor := THEMES[themeName].bg
    framelessHwnds[win.Hwnd] := {minW: minW, minH: minH}
    ApplyFramelessNow(win.Hwnd)
    ApplyGlass(win.Hwnd, win)
    host := {view: view, gui: win, hwnd: win.Hwnd, ctl: "", core: "", token: "", ready: false, loaded: false, asleep: false,
             wpTheme: "", wpMon: 0, wpPath: "", areaOrder: "", pendingNav: ""}
    host.sleepTimer := DeepSleepHost.Bind(host)
    host.unloadTimer := UnloadWebView.Bind(host)
    host.geomTimer := PushWallpaperGeometry.Bind(host)
    host.glassTimer := ReapplyGlassForHost.Bind(host)
    win.OnEvent("Size", OnHostSize.Bind(host))
    win.OnEvent("Close", (*) => HideHost(host))
    try {
        AttachWebView(host)
    } catch as e {
        ; leave nothing half-made behind: the caller retries from scratch
        framelessHwnds.Delete(win.Hwnd)
        try win.Destroy()
        throw e
    }
    return host
}

; Creates the web view inside a host window and loads the page. Done at startup, and again when a window is opened
; after its web view was shut down to save memory (see UnloadWebView).
AttachWebView(host) {
    global wvEnv, wvDataDir, wvLoaderPath, GLASS_RADIUS, wpImgDir, WV_BROWSER_ARGS, uiHtmlPath
    view := host.view
    try {
        if (wvEnv == "") {
            DirCreate(wvDataDir)
            wvEnv := AwaitQuietly(WebView2.CreateEnvironmentAsync({AdditionalBrowserArguments: WV_BROWSER_ARGS}, wvDataDir, , wvLoaderPath), 45000)
            LogAction("[UI] WebView2 runtime " . wvEnv.BrowserVersionString)
        }
        ctl := AwaitQuietly(wvEnv.CreateCoreWebView2ControllerAsync(host.hwnd), 45000)
    } catch as e {
        wvEnv := ""
        throw e
    }
    ctl.IsVisible := true            ; a controller created on a hidden window starts invisible
    ; Transparent web view background (ICoreWebView2Controller2::put_DefaultBackgroundColor, A=0):
    ; the page paints its own background, opaque or translucent depending on the glass option.
    try {
        ctl2 := ComObjQuery(ctl, "{c979903e-d4ca-4228-92eb-47ee3fa96eab}")
        ComCall(27, ctl2, "uint", 0)
    }
    LogAction("[UI] " . view . " controller ready")
    core := ctl.CoreWebView2
    st := core.Settings
    st.AreDefaultContextMenusEnabled := false
    st.IsStatusBarEnabled := false
    st.IsZoomControlEnabled := false
    st.AreBrowserAcceleratorKeysEnabled := false
    ; Native drag regions: the page marks its header with "app-region: drag" and WebView2 moves the window.
    nativeDrag := 0
    try st.IsNonClientRegionSupportEnabled := true, nativeDrag := 1
    ; Render at the system DPI everywhere (the process is system-DPI-aware, so Windows scales the
    ; window on other monitors). Done through ICoreWebView2Controller3 explicitly.
    try {
        ctl3 := ComObjQuery(ctl, "{f9614724-5d2b-41dc-aef7-73d62b51543b}")
        ComCall(31, ctl3, "int", 0)                         ; put_ShouldDetectMonitorScaleChanges(false)
        ComCall(29, ctl3, "double", A_ScreenDPI / 96)       ; put_RasterizationScale
    }
    AwaitQuietly(core.AddScriptToExecuteOnDocumentCreatedAsync("window.SD_VIEW='" . view . "'; window.SD_NATIVE_DRAG=" . nativeDrag . "; window.SD_RADIUS=" . GLASS_RADIUS . ";"), 10000)
    ; the page can load downscaled wallpaper copies (glass + Wallpaper theme) from this folder
    try {
        DirCreate(wpImgDir)
        core.SetVirtualHostNameToFolderMapping("wallpaper.smartdimmer", wpImgDir, 1)      ; COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW
    } catch as e {
        LogAction("[UI] wallpaper folder mapping failed: " . e.Message)
    }
    host.ctl := ctl, host.core := core, host.ready := false, host.loaded := true, host.asleep := false
    host.token := core.WebMessageReceived(OnPageMessage.Bind(host))
    rc := Buffer(16, 0)                                          ; (works while the window is hidden, unlike WinGetClientPos)
    DllCall("GetClientRect", "Ptr", host.hwnd, "Ptr", rc)
    FitWebView(host, NumGet(rc, 8, "Int"), NumGet(rc, 12, "Int"))
    core.NavigateToString(FileRead(uiHtmlPath, "UTF-8"))
    LogAction("[UI] " . view . " page loading")
}

OnHostSize(host, guiObj, minMax, w, h) {
    global WV_INSET, glassEnabled
    if (minMax == -1)
        return
    FitWebView(host, w, h)
    if (ApplyWindowShape(host.hwnd, w, h) && glassEnabled)
        SetTimer(host.glassTimer, -80)          ; region changed: set the acrylic again once the resizing pauses
    if (minMax == 0)
        SaveHostSize(host, w, h)
}
ReapplyGlassForHost(host) {
    try ApplyGlass(host.hwnd, host.gui, HostTheme(host).bg, true)
}

FitWebView(host, w, h) {
    global WV_INSET
    rc := Buffer(16, 0)
    NumPut("Int", WV_INSET, "Int", WV_INSET, "Int", Max(WV_INSET + 1, w - WV_INSET), "Int", Max(WV_INSET + 1, h - WV_INSET), rc)
    try host.ctl.Bounds := rc
}

SaveHostSize(host, w, h) {
    global iniFile
    if (host.view == "flyout") {
        suffix := GetFlyoutSizeKeySuffix()
        try IniWrite(w, iniFile, "Position", "W" . suffix), IniWrite(h, iniFile, "Position", "H" . suffix)
    } else {
        try IniWrite(w, iniFile, "Position", "SettingsW"), IniWrite(h, iniFile, "Position", "SettingsH")
    }
}

; Page -> script. Every command is handed to a timer so nothing blocking runs inside the COM callback.
OnPageMessage(host, sender, args) {
    msg := ""
    try msg := args.TryGetWebMessageAsString()
    if (msg == "")
        return
    SetTimer(HandleCommand.Bind(host, msg), -1)
}

PushState(host := "") {
    global flyout, settings
    for h in (host != "" ? [host] : [flyout, settings]) {
        if (h == "" || !h.ready || h.asleep)                     ; a hidden window gets the state when it is shown again
            continue
        try h.core.PostWebMessageAsJson(Jsn(BuildState(h)))     ; per host: the Wallpaper palette depends on the host's screen
    }
}

Toast(text, host := "") {
    global flyout, settings
    for h in (host != "" ? [host] : [flyout, settings]) {
        if (h == "" || !h.ready || h.asleep)
            continue
        try h.core.PostWebMessageAsJson('{"type":"toast","text":' . JsnStr(text) . '}')
    }
}

ApplyThemeToHosts() {
    global flyout, settings, themeName
    for h in [flyout, settings] {
        if (h == "")
            continue
        if (themeName == "Wallpaper")
            try RefreshHostWallpaperTheme(h)
        try ApplyGlass(h.hwnd, h.gui, HostTheme(h).bg)
    }
}

; ---- glass: DWM accent blur behind the host window (Windows 10 1803+ / 11) ----
; The host paints black where the web view does not cover it (the resize ring); with an accent
; policy active, black GDI pixels are fully transparent, so the ring shows the tinted blur too.
SetWindowAccent(hwnd, state, tintABGR) {
    accent := Buffer(16, 0)
    NumPut("Int", state, "Int", 2, "Int", tintABGR, "Int", 0, accent)      ; AccentState, AccentFlags, GradientColor, AnimationId
    data := Buffer(A_PtrSize * 3, 0)
    NumPut("Int", 19, data), NumPut("Ptr", accent.Ptr, data, A_PtrSize), NumPut("Ptr", 16, data, A_PtrSize * 2)   ; WCA_ACCENT_POLICY
    return DllCall("user32\SetWindowCompositionAttribute", "Ptr", hwnd, "Ptr", data)
}
; bg = the window's background colour (a host on the Wallpaper theme has its own; see HostTheme).
; Everything here is applied only when it actually changes: re-setting the accent, the region or the background
; brush makes Windows redraw the frame of the frameless window, which shows as a white edge flash (noticeable
; while dragging the opacity or colour-intensity sliders, which call this on every step).
ApplyGlass(hwnd, guiObj, bg := "", force := false) {
    global glassEnabled, THEMES, themeName
    static last := Map()                        ; hwnd -> {accent, bg}
    if (bg == "")
        bg := THEMES[themeName].bg
    st := last.Has(hwnd) ? last[hwnd] : {accent: "", bg: ""}
    if (force)                                  ; e.g. the window was just shown: the accent must be set while visible
        st.accent := ""
    ; the region must be set BEFORE the accent: changing a window's region makes DWM rebuild its surface, which
    ; discards the acrylic rendering until the accent policy is set again
    if (ApplyWindowShape(hwnd))
        st.accent := ""
    if (glassEnabled) {
        ; ACCENT_ENABLE_ACRYLICBLURBEHIND (4) always. (Switching to the plain blur state while dragging, a common
        ; workaround for Windows 10 acrylic drag lag, made the glass flicker to sharp during real drags.)
        state := 4
        if (st.accent != state) {
            ; DWM ignores an accent policy set on a window that already has one (or had one while hidden), and
            ; switching straight between the acrylic and blur states leaves plain transparency (a sharp flicker
            ; while dragging): every change goes through "disabled" first
            SetWindowAccent(hwnd, 0, 0)
            ; tint alpha 1: measured on Windows 10, acrylic with alpha 0 renders as plain transparency (no blur at all),
            ; alpha 1 blurs fully with almost no darkening, and larger alphas darken the glass. The page paints the
            ; theme tint at the chosen opacity on top, so the DWM tint itself stays minimal.
            ok := SetWindowAccent(hwnd, state, 0x01000000)
            LogAction("[UI] window " . hwnd . " accent -> " . state)
            st.accent := state
            wantBg := ok ? "000000" : bg
            if (!ok)
                LogAction("[UI] glass not supported on this Windows build; using solid background")
            if (st.bg != wantBg)
                guiObj.BackColor := wantBg, st.bg := wantBg
        }
    } else if (st.accent != 0 || st.bg == "") {
        SetWindowAccent(hwnd, 0, 0)
        LogAction("[UI] window " . hwnd . " accent -> off")
        st.accent := 0
        if (st.bg != bg)
            guiObj.BackColor := bg, st.bg := bg
    }
    ; (solid mode: the web view covers the whole client area, so the brush never shows and is not updated for
    ;  theme changes - only when leaving glass mode)
    ; An accent set on a hidden window does not survive being shown: keep it pending so the next call (from
    ; ShowHostAt) applies it again while the window is visible.
    if (!DllCall("IsWindowVisible", "Ptr", hwnd, "Int"))
        st.accent := ""
    last[hwnd] := st
}
; Rounded corners in glass mode (Windows 10 has no per-window corner preference, so a window region is used;
; the client area equals the window rectangle because WM_NCCALCSIZE returns 0). Applied only when the shape
; (glass on/off, size) changed; returns true when the region was changed (the accent must then be set again).
ApplyWindowShape(hwnd, w := 0, h := 0) {
    global glassEnabled, GLASS_RADIUS
    static last := Map()                        ; hwnd -> "solid" | "w x h"
    if (!glassEnabled) {
        if (!last.Has(hwnd) || last[hwnd] != "solid") {
            DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", 0, "Int", 1)
            last[hwnd] := "solid"
            return true
        }
        return false
    }
    if (!w || !h) {
        rc := Buffer(16, 0)
        DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rc)
        w := NumGet(rc, 8, "Int") - NumGet(rc, 0, "Int"), h := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
    }
    if (w <= 0 || h <= 0)
        return false
    key := w . "x" . h
    if (last.Has(hwnd) && last[hwnd] == key)
        return false
    rgn := DllCall("gdi32\CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1, "Int", GLASS_RADIUS * 2, "Int", GLASS_RADIUS * 2, "Ptr")
    DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", rgn, "Int", 1)      ; the system owns the region from here on
    LogAction("[UI] window " . hwnd . " rounded region " . key)
    last[hwnd] := key
    return true
}
OnHostEnterSizeMove(wParam, lParam, msg, hwnd) {
    global framelessHwnds, flyout, settings, glassEnabled, themeName
    if (!IsSet(framelessHwnds) || !framelessHwnds.Has(hwnd))
        return
    for h in [flyout, settings] {
        if (h == "" || h.hwnd != hwnd)
            continue
        ; (nothing touches the glass accent during a move; a resize re-applies it through OnHostSize)
        if (msg == 0x0232 && themeName == "Wallpaper") {        ; the window may now sit on another screen
            SetTimer(RefreshHostWallpaperTheme.Bind(h, true), -50)
            SetTimer(h.geomTimer, -60)
        }
    }
}
; While a window moves, keep the frosted wallpaper layer aligned with the screen behind it (glass + Wallpaper theme).
OnHostMove(wParam, lParam, msg, hwnd) {
    global flyout, settings, glassEnabled, themeName, wpFrost
    if (!glassEnabled || !wpFrost || themeName != "Wallpaper")
        return
    for h in [flyout, settings]
        if (h != "" && h.hwnd == hwnd)
            SetTimer(h.geomTimer, -40)
}
OnMessage(0x0003, OnHostMove)                                                      ; WM_MOVE
PushWallpaperGeometry(host) {
    if (!host.ready)
        return
    g := WallpaperLayerState(host)
    try host.core.PostWebMessageAsJson('{"type":"wpgeom","x":' . g.x . ',"y":' . g.y . '}')
}
; What the page needs to draw the wallpaper behind the window: image URL, screen size, window offset on that screen.
WallpaperLayerState(host) {
    global glassEnabled, themeName, wpFrost
    if (host == "" || !glassEnabled || !wpFrost || themeName != "Wallpaper")
        return {img: "", sw: 0, sh: 0, x: 0, y: 0}
    pal := WallpaperThemeForHost(host)
    idx := (host.wpMon && host.wpMon <= MonitorGetCount()) ? host.wpMon : HostMonitorIndex(host)
    MonitorGet(idx, &mL, &mT, &mR, &mB)            ; (not L/T: variable names are case-insensitive, T would clobber a theme variable t)
    x := 0, y := 0
    try WinGetPos(&x, &y, , , "ahk_id " . host.hwnd)
    img := (pal.HasOwnProp("img") && pal.img != "") ? "https://wallpaper.smartdimmer/" . pal.img : ""
    return {img: img, sw: mR - mL, sh: mB - mT, x: x - mL, y: y - mT}
}

; ---- minimal JSON serializer (Map/Array/plain object/number/string) ----
Jsn(v) {
    if (v is Array) {
        parts := []
        for x in v
            parts.Push(Jsn(x))
        return "[" . Join(parts, ",") . "]"
    }
    if (v is Map) {
        parts := []
        for k, x in v
            parts.Push(JsnStr(k) . ":" . Jsn(x))
        return "{" . Join(parts, ",") . "}"
    }
    if IsObject(v) {
        parts := []
        for k, x in v.OwnProps()
            parts.Push(JsnStr(k) . ":" . Jsn(x))
        return "{" . Join(parts, ",") . "}"
    }
    if (v == "")
        return '""'
    if (v is Integer || v is Float)
        return String(v)
    return JsnStr(v)
}
JsnStr(s) {
    s := String(s)
    s := StrReplace(s, "\", "\\"), s := StrReplace(s, '"', '\"'), s := StrReplace(s, "`n", "\n"), s := StrReplace(s, "`r", "\r"), s := StrReplace(s, "`t", "\t")
    return '"' . s . '"'
}
Join(arr, sep) {
    out := ""
    for i, x in arr
        out .= (i > 1 ? sep : "") . x
    return out
}

; The whole UI state in one object.
BuildState(host := "") {
    global APP_VERSION, currentHardwareBright, currentSoftwareDim, linkHardwareSoftware, linkAllDisplays, externalMonitorNum
    global monitorSplitMode, monitorHW, monitorSW, dimStates, dimmingCurve, invertCurve, exponentialFactor, maxSoftwareDarkness, hardwareStep, warmStates
    global hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, monitorHotkeys, capturing, hotkeyFlipString
    global THEME_ORDER, THEMES, themeName, COLOR_SLOTS, useDefaultsAtStartup, startupLink, glassEnabled, glassOpacity, wpIntensity, wpFrost, livelyEffects
    global schedEnabled, schedFade, schedIncludeIndependent, schedRows, dataDir, warmth, smoothTransitions, osdEnabled, memorySaver
    mons := []
    names := MonitorNamesByIndex()
    Loop MonitorGetCount() {
        n := A_Index
        mons.Push({idx: n, name: names.Has(n) ? names[n] : "Display " . n, split: (monitorSplitMode.Has(n) && monitorSplitMode[n] == 1) ? 1 : 0,
                   backlight: IsBacklightTarget(n), primary: (n == MonitorGetPrimary()) ? 1 : 0,
                   hw: monitorHW.Has(n) ? monitorHW[n] : currentHardwareBright,
                   sw: monitorSW.Has(n) ? monitorSW[n] : currentSoftwareDim,
                   dim: dimStates.Has(n) ? dimStates[n] : 1, warm: IsWarmTarget(n)})
    }
    monHK := Map()
    Loop MonitorGetCount() {
        n := A_Index, o := {}
        for kind in ["HWUp", "HWDown", "SWUp", "SWDown"]
            o.%kind% := GetMonitorHotkey(n, kind)
        monHK[String(n)] := o
    }
    themeMap := Map()               ; (not 'themes': variable names are case-insensitive and would clobber THEMES)
    for name in THEME_ORDER
        themeMap[name] := (name == "Wallpaper") ? WallpaperThemeForTile(host) : THEMES[name]
    if (themeName == "Automatic")
        themeMap["Automatic"] := THEMES["Automatic"]
    lines := ScheduleStatusLines()
    rows := []
    for r in schedRows
        rows.Push({on: r.on, time: r.time, hw: r.hw, sw: r.sw})
    return {type: "state", version: APP_VERSION,
        hw: Integer(currentHardwareBright), sw: Integer(currentSoftwareDim), linkHWSW: linkHardwareSoftware, linkAll: linkAllDisplays,
        targets: externalMonitorNum, monitors: mons,
        curve: dimmingCurve, invert: invertCurve, factor: Integer(Round(exponentialFactor * 10)), maxDark: maxSoftwareDarkness, step: hardwareStep,
        hotkeys: {master: {HWUp: hotkeyUpString, HWDown: hotkeyDoString, SWUp: hotkeySWUpString, SWDown: hotkeySWDoString, Flip: hotkeyFlipString}, monitors: monHK},
        capturing: capturing, primary: PrimaryDisplayState(),
        theme: themeName, themeOrder: THEME_ORDER, themes: themeMap, colorSlots: COLOR_SLOTS,
        glass: glassEnabled, glassOpacity: glassOpacity, wp: WallpaperLayerState(host), wpIntensity: wpIntensity, wpFrost: wpFrost, lively: livelyEffects,
        warmth: warmth, warmthK: WarmthToKelvin(warmth), nightLight: WindowsNightLightOn(), smooth: smoothTransitions, osd: osdEnabled,
        warmSched: WarmScheduleState(), env: EnvState(), memSaver: memorySaver,
        startup: FileExist(startupLink) ? 1 : 0, useDefaults: useDefaultsAtStartup, dataDir: dataDir,
        sched: {enabled: schedEnabled, fade: schedFade, includeIndependent: schedIncludeIndependent, rows: rows, status1: lines[1], status2: lines[2]}}
}

; ---- commands from the page ----
HandleCommand(host, msg) {
    global currentHardwareBright, currentSoftwareDim, linkHardwareSoftware, linkAllDisplays, externalMonitorNum
    global monitorSplitMode, monitorHW, monitorSW, dimStates, dimmingCurve, invertCurve, exponentialFactor, maxSoftwareDarkness, hardwareStep
    global useDefaultsAtStartup, themeName, THEMES, schedRows, glassEnabled, glassOpacity, wpIntensity, wpFrost, settings, dataDir, livelyEffects
    global warmth, smoothTransitions, osdEnabled, warmStates, autoThemeEnabled, manualTheme, memorySaver, flyout
    p := StrSplit(msg, "|")
    cmd := p[1]
    a := (p.Length >= 2) ? p[2] : "", b := (p.Length >= 3) ? p[3] : "", c := (p.Length >= 4) ? p[4] : "", d := (p.Length >= 5) ? p[5] : "", e := (p.Length >= 6) ? p[6] : ""
    switch cmd {
        case "ready":
            host.ready := true
            PushState(host)
            if (host.pendingNav != "")
                try host.core.PostWebMessageAsJson('{"type":"nav","page":' . JsnStr(host.pendingNav) . '}')
            host.pendingNav := ""
            if !IsHostVisible(host)
                SetTimer(SetHostAsleep.Bind(host), -1500)            ; windows are created hidden at startup
        case "drag":
            DllCall("ReleaseCapture")
            PostMessage(0xA1, 2, 0, , "ahk_id " . host.hwnd)          ; WM_NCLBUTTONDOWN, HTCAPTION
            if (host.view == "flyout")
                SetTimer(SaveCurrentPosition, -600)
        case "resize":
            ; the page detected a press within a few px of the window edge; a = hit-test code
            ; (HTLEFT 10 .. HTBOTTOMRIGHT 17). Windows runs its normal sizing loop from here.
            ht := Integer(a)
            LogAction("[UI] resize from page edge, hit code " . ht)
            if (ht >= 10 && ht <= 17) {
                DllCall("ReleaseCapture")
                PostMessage(0xA1, ht, 0, , "ahk_id " . host.hwnd)
                if (host.view == "flyout")
                    SetTimer(SaveCurrentPosition, -600)
            }
        case "hideSettings":
            HideHost(host)
        case "openSettings":
            ShowSettingsWindow()
            if (a != "" && settings != "") {          ; open straight at a page, e.g. from the flyout's schedule card
                if (settings.ready) {
                    try settings.core.PostWebMessageAsJson('{"type":"nav","page":' . JsnStr(a) . '}')
                } else {
                    settings.pendingNav := a            ; the page is starting up: sent once it is ready
                }
            }
        case "setBacklight":
            ; a = display number, b = 1/0: whether the shared backlight level is sent to that display
            SetBacklightTarget(Integer(a), Integer(b))
            SaveSettings(), UpdateDisplayState(), PushState()
        case "openDataFolder":
            try Run(dataDir)
        case "openProject":
            try Run("https://github.com/Xyberg-001/SmartDimmer")
        case "hideFlyout":
            CloseDashboard()
        case "identify":
            IdentifyConnectedMonitors()
        case "setHW":
            SetMasterHW(Clamp(a))
        case "setSW":
            SetMasterSW(Clamp(a))
        case "setWarmth":
            ; by hand: pauses the warmth schedule (not the brightness one) until the next part of the day
            warmth := Clamp(a), NoteWarmManual()
            SetTimer(ApplyWarmthChange, -60)
        case "warmSched":
            HandleWarmSchedCommand(a, b, c)
        case "setSmooth":
            smoothTransitions := Integer(a) ? 1 : 0, SaveSettings(), PushState()
        case "setMemSaver":
            memorySaver := Integer(a) ? 1 : 0, SaveSettings(), PushState()
            for h in [flyout, settings]
                if (h != "" && !IsHostVisible(h))
                    ScheduleUnload(h)
        case "setOsd":
            osdEnabled := Integer(a) ? 1 : 0, SaveSettings(), PushState()
            if (osdEnabled)
                ShowOsd("Backlight", currentHardwareBright)          ; a preview on the screen under the mouse
        case "setMonHW":
            monitorHW[Integer(a)] := Clamp(b), ScheduleApply()
        case "setMonSW":
            monitorSW[Integer(a)] := Clamp(b), ScheduleApply()
        case "toggleSplit", "setSplit":
            ; toggleSplit|n flips; setSplit|n|0/1 sets ("Own sliders" switch)
            n := Integer(a)
            monitorSplitMode[n] := (cmd == "setSplit") ? (Integer(b) ? 1 : 0) : ((monitorSplitMode.Has(n) && monitorSplitMode[n] == 1) ? 0 : 1)
            if (monitorSplitMode[n] == 1) {
                if (!monitorHW.Has(n))
                    monitorHW[n] := currentHardwareBright
                if (!monitorSW.Has(n))
                    monitorSW[n] := currentSoftwareDim
            }
            UpdateDisplayState(), SaveSettings(), PushState()
        case "setWarm":
            ; a = display number, b = 1/0: whether the warmth filter applies to that display
            warmStates[Integer(a)] := Integer(b) ? 1 : 0
            UpdateDisplayState(true), SaveSettings(), PushState()
        case "setDim":
            dimStates[Integer(a)] := Integer(b) ? 1 : 0
            UpdateDisplayState(true), SaveSettings(), PushState()
        case "setTargets":
            externalMonitorNum := Trim(a)
            SaveSettings(), UpdateDisplayState(), PushState()
        case "toggleLinkAll":
            linkAllDisplays := !linkAllDisplays
            if (linkAllDisplays) {
                list := ""
                Loop MonitorGetCount()
                    list .= (A_Index > 1 ? "," : "") . A_Index
                externalMonitorNum := list
            } else {
                externalMonitorNum := "2"
            }
            SaveSettings(), UpdateDisplayState(), PushState()
        case "setLinkHWSW":
            linkHardwareSoftware := Integer(a) ? 1 : 0, SaveSettings(), PushState()
        case "setCurve":
            dimmingCurve := (a == "exponential") ? "exponential" : "linear", UpdateDisplayState(), SaveSettings(), PushState()
        case "setInvert":
            invertCurve := Integer(a) ? 1 : 0, UpdateDisplayState(), SaveSettings(), PushState()
        case "setFactor":
            exponentialFactor := Max(1.0, Min(5.0, Integer(a) / 10)), ScheduleApply()
        case "setMaxDark":
            maxSoftwareDarkness := Max(0, Min(255, Integer(a))), ScheduleApply()
        case "setStep":
            hardwareStep := Max(1, Min(20, Integer(a))), SetTimer(SaveSettings, -300)
        case "capture":
            StartHotkeyCapture(p)
        case "setTheme":
            if (autoThemeEnabled) {                          ; picking a theme by hand ends the automatic choice
                autoThemeEnabled := 0
                SyncEnvWatch()
                Toast("Automatic theme turned off: you picked " . a . ".")
            }
            manualTheme := a
            SelectTheme(a)
        case "env":
            HandleEnvCommand(a, b, c)
        case "setGlass":
            glassEnabled := Integer(a) ? 1 : 0
            SaveSettings(), ApplyThemeToHosts(), PushState()
        case "setGlassOpacity":
            glassOpacity := Max(20, Min(95, Integer(a)))
            ApplyThemeToHosts(), SetTimer(SaveSettings, -300), PushState()
        case "uiAreas":
            ; the page measured how much of the window each colour group covers: a = "panel>bg>btn>line>fill>accent", b = percentages
            if (a != host.areaOrder) {
                host.areaOrder := a
                LogAction("[Wallpaper] " . host.view . " UI areas: " . b)
                if (themeName == "Wallpaper")
                    RefreshHostWallpaperTheme(host, true)
            }
        case "setWpIntensity":
            wpIntensity := Max(25, Min(100, Integer(a)))
            ApplyThemeToHosts(), SetTimer(SaveSettings, -300), PushState()
        case "setLively":
            livelyEffects := Integer(a) ? 1 : 0
            SaveSettings(), PushState()
        case "setWpFrost":
            wpFrost := Integer(a) ? 1 : 0
            SaveSettings(), PushState()
        case "flipPrimary":
            FlipPrimaryDisplay()
        case "setPrimaryGuard":
            SetPrimaryGuard(Integer(a))
            SaveSettings(), PushState()
        case "setCustomColor":
            if RegExMatch(b, "^[0-9A-Fa-f]{6}$") {
                THEMES["Custom"].%a% := StrUpper(b)
                SaveThemeColours("Custom")
                SelectTheme("Custom")
            }
        case "setThemeColor":
            ; a = slot, b = RRGGBB: edits the selected theme in place. The Wallpaper palette is generated, so an
            ; edit there copies the current palette into Custom, applies the colour and switches to Custom.
            if RegExMatch(b, "^[0-9A-Fa-f]{6}$") {
                target := themeName
                if (themeName == "Wallpaper" || themeName == "Sky" || themeName == "Automatic") {
                    if (themeName == "Automatic")                      ; editing the blend ends the automatic mode
                        autoThemeEnabled := 0, SyncEnvWatch()
                    THEMES["Custom"] := CloneTheme(themeName == "Wallpaper" ? WallpaperThemeForHost(host) : THEMES[themeName])
                    target := "Custom"
                }
                THEMES[target].%a% := StrUpper(b)
                SaveThemeColours(target)
                SelectTheme(target)
            }
        case "resetTheme":
            if (themeName != "Wallpaper" && themeName != "Sky" && themeName != "Automatic") {
                ResetTheme(themeName)
                SelectTheme(themeName)
                Toast(themeName . " is back to its original colours.")
            }
        case "copyPreset":
            src := (themeName == "Custom") ? "Lava Orange" : themeName
            if (src == "Automatic")
                autoThemeEnabled := 0, SyncEnvWatch()
            THEMES["Custom"] := CloneTheme(src == "Wallpaper" ? WallpaperThemeForHost(host) : THEMES[src])
            SaveThemeColours("Custom")
            SelectTheme("Custom")
        case "sched":
            HandleScheduleCommand(a, b, c, d, e)
        case "saveDefaults":
            WriteStateToIni("Defaults", CollectState())
            Toast("Current values saved as your defaults.")
        case "restoreDefaults":
            if (IniRead(iniFile, "Defaults", "Saved", "0") != "1") {
                Toast("No saved defaults yet.")
            } else {
                ApplyStateAndRefresh(ReadStateFromIni("Defaults"))
                Toast("Defaults restored.")
            }
        case "factoryReset":
            if (MsgBox("Reset every setting to factory values?`n`nYour saved defaults are kept.", "Smart Dimmer", "YesNo Icon? Owner" . host.hwnd) == "Yes") {
                ApplyStateAndRefresh(FactoryState())
                Toast("Factory settings applied.")
            }
        case "setUseDefaults":
            useDefaultsAtStartup := Integer(a) ? 1 : 0, SaveSettings(), PushState()
        case "setStartup":
            SetStartup(Integer(a))
        default:
            LogAction("[UI] unknown command: " . msg)
    }
}

Clamp(v) => Max(0, Min(100, Integer(v)))

; The shared backlight level goes to the displays listed in externalMonitorNum ("targets", e.g. "1,2");
; the UI shows that list as a "Backlight" checkbox on each display.
IsBacklightTarget(n) {
    global externalMonitorNum, linkAllDisplays
    if (linkAllDisplays)
        return 1
    for id in StrSplit(StrReplace(externalMonitorNum, " "), ",")
        if (IsNumber(id) && Integer(id) == n)
            return 1
    return 0
}
; Warmth has its own per-screen tick (default on), separate from the Software brightness tick.
IsWarmTarget(n) {
    global warmStates
    return (!warmStates.Has(n) || warmStates[n] == 1) ? 1 : 0
}
SetBacklightTarget(n, on) {
    global externalMonitorNum, linkAllDisplays
    list := []
    Loop Max(MonitorGetCount(), n) {
        i := A_Index
        if ((i == n) ? on : IsBacklightTarget(i))
            list.Push(i)
    }
    linkAllDisplays := 0
    externalMonitorNum := Join(list, ",")
}

SetMasterHW(v) {
    global currentHardwareBright, currentSoftwareDim, linkHardwareSoftware
    old := currentHardwareBright
    currentHardwareBright := v
    if (linkHardwareSoftware)
        currentSoftwareDim := Clamp(currentSoftwareDim + (v - old))
    ScheduleApply()
}
SetMasterSW(v) {
    global currentHardwareBright, currentSoftwareDim, linkHardwareSoftware
    old := currentSoftwareDim
    currentSoftwareDim := v
    if (linkHardwareSoftware)
        currentHardwareBright := Clamp(currentHardwareBright + (v - old))
    ScheduleApply()
}

; The Startup shortcut passes /startup so the app knows to wait for the desktop before opening WebView2.
StartupShortcutArgs() => A_IsCompiled ? "/startup" : "`"" . A_ScriptFullPath . "`" /startup"
StartupShortcutTarget() => A_IsCompiled ? A_ScriptFullPath : A_AhkPath
UpdateStartupShortcut() {
    global startupLink
    if !FileExist(startupLink)
        return
    try {
        FileGetShortcut(startupLink, &target, , &args)
        if (target = StartupShortcutTarget() && !InStr(args, "/startup")) {
            FileCreateShortcut(StartupShortcutTarget(), startupLink, A_ScriptDir, StartupShortcutArgs(), "Smart Dimmer")
            LogAction("[Startup] shortcut updated to pass /startup")
        }
    }
}
SetStartup(on) {
    global startupLink
    if (on) {
        try FileCreateShortcut(StartupShortcutTarget(), startupLink, A_ScriptDir, StartupShortcutArgs(), "Smart Dimmer")
        catch
            Toast("Could not create the Startup shortcut.")
    } else {
        try {
            if FileExist(startupLink)
                FileDelete(startupLink)
        } catch {
            Toast("Could not remove the Startup shortcut.")
        }
    }
    PushState()
}

; Hardware writes are debounced: sliders send a step on every pixel.
ScheduleApply() {
    NoteManualAdjust()
    SetTimer(ApplyPendingChanges, -120)
}
ApplyWarmthChange() {
    UpdateDisplayState(true), SetTimer(SaveSettings, -500), PushState()
}
ApplyPendingChanges() {
    UpdateDisplayState(), SaveSettings(), PushState()
}
; Hotkeys: at most one hardware update per 100 ms while a key auto-repeats.
RequestDisplayUpdate() {
    static lastApply := 0, pending := false
    NoteManualAdjust()
    flush() {
        pending := false, lastApply := A_TickCount
        UpdateDisplayState(), PushState()
    }
    if (A_TickCount - lastApply >= 100)
        flush()
    else if (!pending)
        pending := true, SetTimer(flush, -100)
}

; ---- show / hide ----
ShowHostAt(host, x, y, w, h) {
    global themeName
    if !EnsureHostLoaded(host)
        return
    SetHostAwake(host)
    host.gui.Show((x != "" ? "X" . x . " Y" . y . " " : "") . "w" . w . " h" . h)
    if (x != "")
        WinMove(x, y, w, h, "ahk_id " . host.hwnd)
    else
        WinMove(, , w, h, "ahk_id " . host.hwnd)
    FitWebView(host, w, h)
    try host.ctl.IsVisible := true
    try ApplyGlass(host.hwnd, host.gui, HostTheme(host).bg, true)         ; (re)applies the acrylic now that the window is visible
    if (themeName == "Wallpaper")
        try RefreshHostWallpaperTheme(host, true)
}
HideHost(host) {
    try host.gui.Hide()
    SetHostAsleep(host)
}
; A hidden window's web view is told it is hidden, so it stops painting and animating (before this, the hidden
; windows kept rendering at full frame rate). Three seconds later, if it is still hidden, the page is suspended
; (its timers stop) and WebView2 is asked to keep its memory low. Showing the window wakes it.
SetHostAsleep(host) {
    if (host == "" || IsHostVisible(host))
        return
    host.asleep := true
    try host.ctl.IsVisible := false
    SetTimer(host.sleepTimer, -3000)
    ScheduleUnload(host)
}
ScheduleUnload(host) {
    global memorySaver, MEMORY_SAVER_DELAY
    SetTimer(host.unloadTimer, (memorySaver && host.loaded) ? -MEMORY_SAVER_DELAY : 0)
}
; Memory saver: a window closed for a minute gets its web view shut down; when both are, WebView2 itself exits
; (all msedgewebview2 processes of Smart Dimmer end). Opening the window starts it again (EnsureHostLoaded).
UnloadWebView(host) {
    global flyout, settings, wvEnv
    if (!host.loaded || IsHostVisible(host))
        return
    host.ready := false, host.loaded := false, host.asleep := false
    SetTimer(host.sleepTimer, 0)
    host.token := ""                                             ; unhooks the page's message handler
    try host.ctl.Close()
    host.ctl := "", host.core := ""
    LogAction("[UI] " . host.view . " web view shut down to save memory")
    if ((flyout == "" || !flyout.loaded) && (settings == "" || !settings.loaded)) {
        wvEnv := ""                                              ; last reference: the WebView2 processes exit
        LogAction("[UI] WebView2 closed; it starts again when a window is opened")
        SetTimer(TrimOwnMemory, -5000)
    }
}
TrimOwnMemory() {
    DllCall("psapi\EmptyWorkingSet", "Ptr", DllCall("GetCurrentProcess", "Ptr"))
}
; Makes sure a window has its web view before it is shown.
EnsureHostLoaded(host) {
    global uiLastError
    SetTimer(host.unloadTimer, 0)
    if (host.loaded)
        return true
    t0 := A_TickCount
    Loop 2 {                                                   ; one quiet retry with a fresh WebView2 environment
        try {
            AttachWebView(host)
            LogAction("[UI] " . host.view . " web view started again in " . (A_TickCount - t0) . " ms")
            return true
        } catch as e {
            uiLastError := e.Message
            LogAction("[UI] could not start the " . host.view . " web view again (attempt " . A_Index . "): " . ErrText(e))
            ResetWebView2()
        }
    }
    MsgBox("Smart Dimmer could not open its window:`n`n" . uiLastError . "`n`nHotkeys and the schedule keep working. Try again in a moment; if it keeps happening, restart Smart Dimmer.", "Smart Dimmer", "Iconx")
    return false
}
; Drops the WebView2 environment so the next attempt starts it fresh, unless the other window is still using it.
ResetWebView2() {
    global flyout, settings, wvEnv
    for h in [flyout, settings]
        if (h != "" && h.loaded)
            return
    wvEnv := ""
    Sleep(500)                                                 ; give the old WebView2 processes a moment to exit
}
DeepSleepHost(host) {
    if (!host.asleep || IsHostVisible(host))
        return
    try host.core.MemoryUsageTargetLevel := 1                     ; COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_LOW
    try {
        p := host.core.TrySuspendAsync()
        p.thrown := true                                         ; nothing waits for it; a refusal must not raise later
    }
}
SetHostAwake(host) {
    SetTimer(host.sleepTimer, 0)
    if (host.asleep) {
        host.asleep := false
        try host.core.MemoryUsageTargetLevel := 0                 ; normal
        try host.core.Resume()
    }
    try host.ctl.IsVisible := true
}
IsHostVisible(host) {
    return host != "" && DllCall("IsWindowVisible", "Ptr", host.hwnd, "Int")
}

GetFlyoutSizeKeySuffix() {
    global monitorSplitMode
    suffix := ""
    Loop MonitorGetCount() {
        if (monitorSplitMode.Has(A_Index) && monitorSplitMode[A_Index] == 1)
            suffix .= "_" . A_Index
    }
    return (suffix != "") ? "_Split" . suffix : ""
}
GetFlyoutSize() {
    global iniFile
    suffix := GetFlyoutSizeKeySuffix()
    w := IniRead(iniFile, "Position", "W" . suffix, IniRead(iniFile, "Position", "W", "")), h := IniRead(iniFile, "Position", "H" . suffix, IniRead(iniFile, "Position", "H", ""))
    return {W: IsNumber(w) ? Max(340, Integer(w)) : 420, H: IsNumber(h) ? Max(380, Integer(h)) : 660}
}
ConstrainToScreenBoundaries(X, Y, W, H) {
    targetMonitor := MonitorGetPrimary(), midX := X + (W / 2), midY := Y + (H / 2)
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
        if (midX >= Left && midX <= Right && midY >= Top && midY <= Bottom) {
            targetMonitor := A_Index
            break
        }
    }
    try {
        MonitorGetWorkArea(targetMonitor, &wLeft, &wTop, &wRight, &wBottom)
    } catch {
        return {X: Integer(X), Y: Integer(Y)}                ; displays are being reconfigured: leave it as is
    }
    return {X: Integer(Max(wLeft + 4, Min(X, wRight - W - 4))), Y: Integer(Max(wTop + 4, Min(Y, wBottom - H - 4)))}
}
ShowDashboard() {
    global flyout, iniFile
    if (!EnsureUiReady())
        return
    sz := GetFlyoutSize()
    lastX := IniRead(iniFile, "Position", "X", "Default"), lastY := IniRead(iniFile, "Position", "Y", "Default")
    if (lastX == "Default" || lastY == "Default" || !IsNumber(lastX) || !IsNumber(lastY)) {
        ; first run: bottom-right of the primary screen's work area, next to the tray like other tray flyouts
        MonitorGetWorkArea(MonitorGetPrimary(), &wLeft, &wTop, &wRight, &wBottom)
        posX := wRight - sz.W - 12, posY := wBottom - sz.H - 12
    } else {
        posX := Integer(lastX), posY := Integer(lastY)
    }
    coords := ConstrainToScreenBoundaries(posX, posY, sz.W, sz.H)
    ShowHostAt(flyout, coords.X, coords.Y, sz.W, sz.H)
    PushState(flyout)
    SetTimer(CheckFocusLoss, 150)
}
CloseDashboard() {
    global flyout
    SetTimer(CheckFocusLoss, 0)
    SaveCurrentPosition()
    HideHost(flyout)
}
ToggleDashboard() {
    global flyout
    if (flyout != "" && IsHostVisible(flyout) && WinActive("ahk_id " . flyout.hwnd))
        CloseDashboard()
    else
        ShowDashboard()
}
SaveCurrentPosition() {
    global flyout, iniFile
    if (flyout == "" || !IsHostVisible(flyout))
        return
    WinGetPos(&x, &y, &w, &h, "ahk_id " . flyout.hwnd)
    coords := ConstrainToScreenBoundaries(x, y, w, h)
    if (coords.X != x || coords.Y != y)
        WinMove(coords.X, coords.Y, , , "ahk_id " . flyout.hwnd)
    try IniWrite(coords.X, iniFile, "Position", "X"), IniWrite(coords.Y, iniFile, "Position", "Y")
}
CheckFocusLoss() {
    global flyout, settings
    if (flyout == "" || !IsHostVisible(flyout))
        return
    active := WinActive("A")
    if (active == flyout.hwnd || (settings != "" && active == settings.hwnd))
        return
    ; a MsgBox we own counts too
    if (WinExist("ahk_id " . active) && WinGetPID("ahk_id " . active) == ProcessExist())
        return
    CloseDashboard()
}
ShowSettingsWindow() {
    global settings, iniFile
    if (!EnsureUiReady())
        return
    w := IniRead(iniFile, "Position", "SettingsW", ""), h := IniRead(iniFile, "Position", "SettingsH", "")
    w := IsNumber(w) ? Max(760, Integer(w)) : 900, h := IsNumber(h) ? Max(540, Integer(h)) : 660
    if (IsHostVisible(settings)) {
        WinActivate("ahk_id " . settings.hwnd)
        return
    }
    ShowHostAt(settings, "", "", w, h)
    PushState(settings)
}

; ---- frameless handling (client = whole window; edge hit-testing in the WV_INSET margin) ----
OnFramelessNcCalcSize(wParam, lParam, msg, hwnd) {
    global framelessHwnds
    if (wParam && IsSet(framelessHwnds) && framelessHwnds.Has(hwnd))
        return 0
}
OnFramelessNcHitTest(wParam, lParam, msg, hwnd) {
    global framelessHwnds
    if (!IsSet(framelessHwnds) || !framelessHwnds.Has(hwnd))
        return
    x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
    if (x > 32767)
        x -= 65536
    if (y > 32767)
        y -= 65536
    rc := Buffer(16, 0)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rc)
    l := NumGet(rc, 0, "Int"), t := NumGet(rc, 4, "Int"), r := NumGet(rc, 8, "Int"), b := NumGet(rc, 12, "Int")
    g := 6
    onL := (x < l + g), onR := (x >= r - g), onT := (y < t + g), onB := (y >= b - g)
    if (onT && onL)
        return 13
    if (onT && onR)
        return 14
    if (onB && onL)
        return 16
    if (onB && onR)
        return 17
    if (onL)
        return 10
    if (onR)
        return 11
    if (onT)
        return 12
    if (onB)
        return 15
    return 1
}
OnFramelessNcPaint(wParam, lParam, msg, hwnd) {
    global framelessHwnds
    if (IsSet(framelessHwnds) && framelessHwnds.Has(hwnd))
        return 0
}
OnFramelessNcActivate(wParam, lParam, msg, hwnd) {
    global framelessHwnds
    if (IsSet(framelessHwnds) && framelessHwnds.Has(hwnd))
        return 1
}
OnFramelessMinMax(wParam, lParam, msg, hwnd) {
    global framelessHwnds
    if (!IsSet(framelessHwnds) || !framelessHwnds.Has(hwnd))
        return
    info := framelessHwnds[hwnd]
    NumPut("Int", info.minW, "Int", info.minH, lParam, 24)
    return 0
}
ApplyFramelessNow(hwnd) {
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x37)
}
OnMessage(0x0024, OnFramelessMinMax)
OnMessage(0x0083, OnFramelessNcCalcSize)
OnMessage(0x0084, OnFramelessNcHitTest)
OnMessage(0x0085, OnFramelessNcPaint)
OnMessage(0x0086, OnFramelessNcActivate)
OnMessage(0x007E, OnDisplayChange)
OnMessage(0x0231, OnHostEnterSizeMove)      ; WM_ENTERSIZEMOVE
OnMessage(0x0232, OnHostEnterSizeMove)      ; WM_EXITSIZEMOVE

IdentifyConnectedMonitors() {
    global THEMES, themeName
    idWindows := []
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
        idGui := Gui("+AlwaysOnTop -Caption +ToolWindow +Disabled -DPIScale")
        t := ThemeForMonitor(A_Index)
        idGui.BackColor := t.bg
        idGui.SetFont("s90 bold c" . t.accent, "Segoe UI")
        idGui.AddText("Center x0 y" . Round(((Bottom - Top) // 2) - 110) . " w" . (Right - Left), String(A_Index))
        idGui.SetFont("s26 c" . t.text, "Segoe UI")
        idGui.AddText("Center x0 y" . Round(((Bottom - Top) // 2) + 50) . " w" . (Right - Left), MonitorName(A_Index))
        idGui.Show("X" . Left . " Y" . Top . " w" . (Right - Left) . " h" . (Bottom - Top) . " NoActivate")
        WinSetTransparent(200, "ahk_id " . idGui.Hwnd)
        idWindows.Push(idGui)
    }
    SetTimer(() => KillOverlays(idWindows), -2500)
}
KillOverlays(arr) {
    for g in arr
        try g.Destroy()
}

SetupTrayMenu() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Show / hide Smart Dimmer", (*) => ToggleDashboard())
    A_TrayMenu.Add("Settings...", (*) => ShowSettingsWindow())
    A_TrayMenu.Add("Swap primary display", (*) => FlipPrimaryDisplay())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_TrayMenu.Default := "Show / hide Smart Dimmer"
    A_TrayMenu.ClickCount := 1
}

; =========================================================================
; ⌨️ HOTKEYS
; =========================================================================

; p = ["capture","master",kind] or ["capture","mon",idx,kind]
StartHotkeyCapture(p) {
    global capturing
    if (p[2] == "master")
        capturing := "master:" . p[3], onDone := (k) => SetMasterHotkey(p[3], k)
    else
        capturing := "mon:" . p[3] . ":" . p[4], onDone := (k) => SetMonitorHotkey(Integer(p[3]), p[4], k)
    PushState()
    ; the click that started the capture may still be held: wait for all mouse buttons to be released
    t0 := A_TickCount
    while ((GetKeyState("LButton", "P") || GetKeyState("RButton", "P") || GetKeyState("MButton", "P")) && A_TickCount - t0 < 1500)
        Sleep(20)
    ih := InputHook("L1 M V")
    ih.VisibleNonChars := true
    ih.KeyOpt("{All}", "E")
    ih.Start()
    while (ih.InProgress) {
        for btn in ["LButton", "RButton", "MButton"] {
            if GetKeyState(btn, "P") {
                capturedKey := btn
                break
            }
        }
        if IsSet(capturedKey)
            break
        Sleep(10)
    }
    if (!IsSet(capturedKey)) {
        ih.Stop()
        capturedKey := ih.EndKey
        if (capturedKey == "")
            capturedKey := ih.Input
    } else {
        ih.Stop()
    }
    if (capturedKey = "Escape") {
        finalBind := ""
    } else {
        prefix := ""
        if GetKeyState("Ctrl", "P") && !InStr(capturedKey, "Control")
            prefix .= "^"
        if GetKeyState("Alt", "P") && !InStr(capturedKey, "Alt")
            prefix .= "!"
        if GetKeyState("Shift", "P") && !InStr(capturedKey, "Shift")
            prefix .= "+"
        if GetKeyState("LWin", "P") && !InStr(capturedKey, "Win")
            prefix .= "#"
        finalBind := prefix . capturedKey
    }
    capturing := ""
    onDone.Call(finalBind)
}
ReleaseHotkeyEverywhere(keyStr) {
    global hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, monitorHotkeys, hotkeyFlipString
    if (keyStr == "")
        return
    if (hotkeyFlipString = keyStr)
        hotkeyFlipString := ""
    if (hotkeyUpString = keyStr)
        hotkeyUpString := ""
    if (hotkeyDoString = keyStr)
        hotkeyDoString := ""
    if (hotkeySWUpString = keyStr)
        hotkeySWUpString := ""
    if (hotkeySWDoString = keyStr)
        hotkeySWDoString := ""
    for k, s in monitorHotkeys.Clone()
        if (s = keyStr)
            monitorHotkeys.Delete(k)
}
SetMasterHotkey(kind, keyStr) {
    global hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, hotkeyFlipString
    ReleaseHotkeyEverywhere(keyStr)
    switch kind {
        case "HWUp": hotkeyUpString := keyStr
        case "HWDown": hotkeyDoString := keyStr
        case "SWUp": hotkeySWUpString := keyStr
        case "SWDown": hotkeySWDoString := keyStr
        case "Flip": hotkeyFlipString := keyStr
    }
    UpdateActiveHotkeys(), SaveSettings(), PushState()
}
GetMonitorHotkey(mIdx, kind) {
    global monitorHotkeys
    k := mIdx . ":" . kind
    return monitorHotkeys.Has(k) ? monitorHotkeys[k] : ""
}
SetMonitorHotkey(mIdx, kind, keyStr) {
    global monitorHotkeys
    ReleaseHotkeyEverywhere(keyStr)
    k := mIdx . ":" . kind
    if (keyStr == "") {
        if (monitorHotkeys.Has(k))
            monitorHotkeys.Delete(k)
    } else {
        monitorHotkeys[k] := keyStr
    }
    UpdateActiveHotkeys(), SaveSettings(), PushState()
}
MonitorHotkeyAction(mIdx, kind, *) {
    global monitorSplitMode, monitorHW, monitorSW, hardwareStep, currentHardwareBright, currentSoftwareDim
    if (mIdx > MonitorGetCount())
        return
    if (!monitorHW.Has(mIdx))
        monitorHW[mIdx] := currentHardwareBright
    if (!monitorSW.Has(mIdx))
        monitorSW[mIdx] := currentSoftwareDim
    delta := (kind == "HWUp" || kind == "SWUp") ? hardwareStep : -hardwareStep
    if (SubStr(kind, 1, 2) == "HW")
        monitorHW[mIdx] := Clamp(monitorHW[mIdx] + delta)
    else
        monitorSW[mIdx] := Clamp(monitorSW[mIdx] + delta)
    monitorSplitMode[mIdx] := 1        ; a per-monitor hotkey implies Independent
    RequestDisplayUpdate()
    SetTimer(SaveSettings, -300)
    names := MonitorNamesByIndex(), isHW := SubStr(kind, 1, 2) == "HW"
    ShowOsd((names.Has(mIdx) ? names[mIdx] : "Display " . mIdx) . "  ·  " . (isHW ? "Backlight" : "Software brightness"),
            isHW ? monitorHW[mIdx] : monitorSW[mIdx], mIdx)
}
UpdateActiveHotkeys() {
    global hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, monitorHotkeys, hotkeyFlipString
    static active := []
    for k in active
        try Hotkey(k, "Off")
    active := []
    for pair in [[hotkeyUpString, ExecuteVolumeUpAction], [hotkeyDoString, ExecuteVolumeDownAction], [hotkeySWUpString, ExecuteSoftwareUpAction], [hotkeySWDoString, ExecuteSoftwareDownAction], [hotkeyFlipString, FlipPrimaryDisplay]]
        BindHotkey(pair[1], pair[2], active)
    for k, s in monitorHotkeys {
        parts := StrSplit(k, ":")
        BindHotkey(s, MonitorHotkeyAction.Bind(Integer(parts[1]), parts[2]), active)
    }
}
BindHotkey(keyStr, fn, active) {
    if (keyStr == "")
        return
    try {
        Hotkey(keyStr, fn, "On")
        active.Push(keyStr)
    } catch as e {
        LogAction("[Hotkey] could not bind '" . keyStr . "': " . e.Message)
    }
}
ExecuteVolumeUpAction(*) {
    global currentHardwareBright, hardwareStep, maxHardwareBrightness
    if (currentHardwareBright < maxHardwareBrightness)
        SetMasterHWStep(Min(maxHardwareBrightness, currentHardwareBright + hardwareStep))
    ShowOsd("Backlight", currentHardwareBright)
}
ExecuteVolumeDownAction(*) {
    global currentHardwareBright, hardwareStep, minHardwareBrightness
    if (currentHardwareBright > minHardwareBrightness)
        SetMasterHWStep(Max(minHardwareBrightness, currentHardwareBright - hardwareStep))
    ShowOsd("Backlight", currentHardwareBright)
}
SetMasterHWStep(v) {
    global currentHardwareBright, currentSoftwareDim, linkHardwareSoftware
    old := currentHardwareBright, currentHardwareBright := v
    if (linkHardwareSoftware)
        currentSoftwareDim := Clamp(currentSoftwareDim + (v - old))
    RequestDisplayUpdate()
}
ExecuteSoftwareUpAction(*) {
    global currentSoftwareDim, hardwareStep, maxHardwareBrightness
    if (currentSoftwareDim < maxHardwareBrightness)
        currentSoftwareDim := Min(maxHardwareBrightness, currentSoftwareDim + hardwareStep), RequestDisplayUpdate()
    ShowOsd("Software brightness", currentSoftwareDim)
}
ExecuteSoftwareDownAction(*) {
    global currentSoftwareDim, hardwareStep, minHardwareBrightness
    if (currentSoftwareDim > minHardwareBrightness)
        currentSoftwareDim := Max(minHardwareBrightness, currentSoftwareDim - hardwareStep), RequestDisplayUpdate()
    ShowOsd("Software brightness", currentSoftwareDim)
}

; ---- on-screen indicator ----
; A small themed bar near the bottom of the screen, shown when a brightness hotkey is used. Native window (no
; WebView2) so it appears instantly; click-through, never takes focus, fades out after OSD_HOLD_MS.
global osdGui := "", osdCtl := {}, OSD_HOLD_MS := 1300
OsdMonitorUnderMouse() {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    Loop MonitorGetCount() {
        try {
            MonitorGet(A_Index, &L, &T, &R, &B)
            if (mx >= L && mx < R && my >= T && my < B)
                return A_Index
        }
    }
    return MonitorGetPrimary()
}
OsdTheme(mIdx) {
    global THEMES, themeName
    try return (themeName == "Wallpaper") ? WallpaperThemeForMonitor(mIdx) : THEMES[themeName]
    return THEMES["Lava Orange"]
}
ShowOsd(label, value, mIdx := 0) {
    global osdGui, osdCtl, osdEnabled, OSD_HOLD_MS, GLASS_RADIUS
    static builtDpi := 0
    if (!osdEnabled)
        return
    if (!mIdx || mIdx > MonitorGetCount())
        mIdx := OsdMonitorUnderMouse()
    th := OsdTheme(mIdx)
    hMon := GetHMonitorFromIndex(mIdx)
    ; the bar is built per-monitor DPI aware so its text stays sharp on screens scaled differently from the
    ; main one (the rest of the app is system-DPI aware and would be stretched by Windows there)
    oldCtx := DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    try {
        dpi := 96, dpiY := 96
        try DllCall("shcore\GetDpiForMonitor", "Ptr", hMon, "Int", 0, "UInt*", &dpi, "UInt*", &dpiY)
        sc := dpi / 96, fs := dpi / A_ScreenDPI          ; AutoHotkey sizes fonts for the system DPI
        W := Round(340 * sc), H := Round(78 * sc), pad := Round(18 * sc), barH := Round(6 * sc)
        if (osdGui != "" && builtDpi != dpi)
            osdGui.Destroy(), osdGui := ""
        if (osdGui == "") {
            builtDpi := dpi
            ; WS_EX_NOACTIVATE (0x08000000) + WS_EX_TRANSPARENT (0x20): never focused, clicks go through
            osdGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000020 +Owner")
            osdGui.MarginX := 0, osdGui.MarginY := 0
            osdGui.SetFont("s" . Round(10 * fs, 1) . " w600", "Segoe UI")
            osdCtl.label := osdGui.Add("Text", "x" pad " y" Round(14 * sc) " w" (W - pad * 2 - Round(80 * sc)) " h" Round(24 * sc) " BackgroundTrans")
            osdGui.SetFont("s" . Round(15 * fs, 1) . " w700", "Segoe UI")
            osdCtl.value := osdGui.Add("Text", "x" (W - pad - Round(90 * sc)) " y" Round(8 * sc) " w" Round(90 * sc) " h" Round(32 * sc) " Right BackgroundTrans")
            osdCtl.track := osdGui.Add("Text", "x" pad " y" (H - pad - barH) " w" (W - pad * 2) " h" barH)
            osdCtl.fill := osdGui.Add("Text", "x" pad " y" (H - pad - barH) " w1 h" barH)
            osdGui.Show("Hide w" W " h" H)
            WinSetTransparent(0, osdGui)
            DllCall("SetWindowRgn", "Ptr", osdGui.Hwnd, "Ptr", DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", W + 1, "Int", H + 1, "Int", Round(GLASS_RADIUS * 2 * sc), "Int", Round(GLASS_RADIUS * 2 * sc), "Ptr"), "Int", 1)
        }
        osdGui.BackColor := th.bg
        osdCtl.label.SetFont("c" . th.muted), osdCtl.label.Text := label
        osdCtl.value.SetFont("c" . th.text), osdCtl.value.Text := Round(value) . "%"
        osdCtl.track.Opt("+Background" . th.line)
        osdCtl.fill.Opt("+Background" . th.accent)
        osdCtl.fill.Move(, , Max(1, Round((W - pad * 2) * Max(0, Min(100, value)) / 100)))
        osdCtl.track.Redraw(), osdCtl.fill.Redraw()
        ; work area in physical pixels (this thread is per-monitor aware right now)
        mi := Buffer(40, 0), NumPut("UInt", 40, mi)
        DllCall("GetMonitorInfoW", "Ptr", hMon, "Ptr", mi)
        L := NumGet(mi, 20, "Int"), R := NumGet(mi, 28, "Int"), B := NumGet(mi, 32, "Int")
        DllCall("SetWindowPos", "Ptr", osdGui.Hwnd, "Ptr", -1, "Int", L + (R - L - W) // 2, "Int", B - H - Round(56 * sc), "Int", W, "Int", H, "UInt", 0x0010 | 0x0040)   ; HWND_TOPMOST, SWP_NOACTIVATE | SWP_SHOWWINDOW
        WinSetTransparent(242, osdGui)
    } finally {
        DllCall("SetThreadDpiAwarenessContext", "Ptr", oldCtx, "Ptr")
    }
    SetTimer(OsdFade, 0)
    SetTimer(OsdFade, -OSD_HOLD_MS)
}
OsdFade() {
    global osdGui
    static alpha := 242
    if (osdGui == "")
        return
    try alpha := WinGetTransparent(osdGui)
    alpha := (alpha == "") ? 242 : alpha - 40
    if (alpha <= 0) {
        osdGui.Hide()
        return
    }
    WinSetTransparent(alpha, osdGui)
    SetTimer(OsdFade, -30)
}

; =========================================================================
; 🎨 THEMES
; =========================================================================
SelectTheme(name) {
    global THEMES, themeName
    if (!THEMES.Has(name))
        name := "Lava Orange"
    themeName := name
    if (name == "Sky")
        UpdateSkyPalette()
    SyncWallpaperWatch(), SyncEnvWatch()
    SaveSettings()
    ApplyThemeToHosts()
    PushState()
}

; =========================================================================
; 🖼️ WALLPAPER THEME - a palette built from the wallpaper of the screen each window is on
; =========================================================================
global WALLPAPER_CACHE := Map()               ; "path|mtime|size" -> image colour analysis

; Per-monitor wallpaper paths through IDesktopWallpaper (Windows 8+), keyed by AutoHotkey monitor index.
WallpaperPathsByMonitor() {
    static CLSID := "{C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD}", IID := "{B92B56A9-8B55-4E14-9A89-0199BBB6F93B}"
    static cache := Map(), cachedAt := 0
    if (cache.Count && A_TickCount - cachedAt < 1000)
        return cache
    paths := Map()
    try {
        dw := ComObject(CLSID, IID)
        n := 0
        ComCall(6, dw, "UInt*", &n)                                     ; GetMonitorDevicePathCount
        Loop n {
            pId := 0
            ComCall(5, dw, "UInt", A_Index - 1, "Ptr*", &pId)           ; GetMonitorDevicePathAt
            id := StrGet(pId), DllCall("ole32\CoTaskMemFree", "Ptr", pId)
            rc := Buffer(16, 0)
            try {
                ComCall(7, dw, "WStr", id, "Ptr", rc)                   ; GetMonitorRECT (fails for detached monitors)
            } catch {
                continue
            }
            L := NumGet(rc, 0, "Int"), T := NumGet(rc, 4, "Int")
            pWp := 0
            try {
                ComCall(4, dw, "WStr", id, "Ptr*", &pWp)                ; GetWallpaper
            } catch {
                continue
            }
            wp := pWp ? StrGet(pWp) : "", DllCall("ole32\CoTaskMemFree", "Ptr", pWp)
            Loop MonitorGetCount() {
                MonitorGet(A_Index, &mL, &mT, &mR, &mB)
                if (mL == L && mT == T)
                    paths[A_Index] := wp
            }
        }
    } catch as e {
        LogAction("[Wallpaper] IDesktopWallpaper unavailable: " . e.Message)
    }
    if (!paths.Count) {
        wp := ""
        try wp := RegRead("HKCU\Control Panel\Desktop", "WallPaper")
        Loop MonitorGetCount()
            paths[A_Index] := wp
    } else {
        first := ""
        for idx, wp in paths
            if (first == "" && wp != "")
                first := wp
        Loop MonitorGetCount()
            if (!paths.Has(A_Index))
                paths[A_Index] := first
    }
    cache := paths, cachedAt := A_TickCount
    return paths
}
; Solid desktop colour (used when a screen has no wallpaper image), as [r, g, b].
DesktopBackgroundColour() {
    static CLSID := "{C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD}", IID := "{B92B56A9-8B55-4E14-9A89-0199BBB6F93B}"
    try {
        dw := ComObject(CLSID, IID)
        c := 0
        ComCall(9, dw, "UInt*", &c)                                     ; GetBackgroundColor (COLORREF: 0x00BBGGRR)
        return [c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF]
    }
    return [20, 20, 23]
}
EnsureGdiplus() {
    static token := 0
    if (token)
        return true
    DllCall("LoadLibrary", "Str", "gdiplus")
    si := Buffer(24, 0), NumPut("UInt", 1, si)
    return DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0) == 0
}
; Downscales the image to 48x32 and returns {avg: [r,g,b], vivid: [r,g,b] | ""}: the average colour and the
; dominant saturated colour (largest weighted hue bin), or "" when the picture has no real colour.
; With saveTo, also writes a 1280px-wide JPEG copy (for the frosted wallpaper layer in glass mode).
ImageColours(path, saveTo := "") {
    if (!EnsureGdiplus())
        return ""
    pImg := 0
    if DllCall("gdiplus\GdipLoadImageFromFile", "WStr", path, "Ptr*", &pImg) || !pImg
        return ""
    if (saveTo != "") {
        iw := 0, ih := 0
        DllCall("gdiplus\GdipGetImageWidth", "Ptr", pImg, "UInt*", &iw), DllCall("gdiplus\GdipGetImageHeight", "Ptr", pImg, "UInt*", &ih)
        if (iw > 0 && ih > 0) {
            cw := Min(1280, iw), ch := Max(1, Round(ih * cw / iw)), pC := 0, pCG := 0
            DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", cw, "Int", ch, "Int", 0, "Int", 0x22009, "Ptr", 0, "Ptr*", &pC)    ; 24bppRGB
            DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pC, "Ptr*", &pCG)
            DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pCG, "Int", 7)
            DllCall("gdiplus\GdipDrawImageRectI", "Ptr", pCG, "Ptr", pImg, "Int", 0, "Int", 0, "Int", cw, "Int", ch)
            DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pCG)
            clsid := Buffer(16, 0), DllCall("ole32\CLSIDFromString", "WStr", "{557CF401-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)   ; JPEG
            DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pC, "WStr", saveTo, "Ptr", clsid, "Ptr", 0)
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pC)
        }
    }
    ; (sample size variables are sampW/sampH: names are case-insensitive, and a per-pixel weight 'w' would clobber 'W')
    sampW := 96, sampH := 64, pBmp := 0, pG := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", sampW, "Int", sampH, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBmp)   ; 32bppARGB
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBmp, "Ptr*", &pG)
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pG, "Int", 7)                                                        ; HighQualityBicubic
    DllCall("gdiplus\GdipDrawImageRectI", "Ptr", pG, "Ptr", pImg, "Int", 0, "Int", 0, "Int", sampW, "Int", sampH)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pG)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pImg)
    rect := Buffer(16, 0), NumPut("Int", 0, "Int", 0, "Int", sampW, "Int", sampH, rect)
    bd := Buffer(32, 0)                                               ; BitmapData (x64): Stride at 8, Scan0 at 16
    if DllCall("gdiplus\GdipBitmapLockBits", "Ptr", pBmp, "Ptr", rect, "UInt", 1, "Int", 0x26200A, "Ptr", bd) {
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
        return ""
    }
    stride := NumGet(bd, 8, "Int"), scan0 := NumGet(bd, 16, "Ptr")
    sr := 0, sg := 0, sb := 0, n := 0, dr := 0, dg := 0, db := 0, dn := 0
    bins := []                                                        ; 24 hue bins (colourful pixels): pixel count + RGB sums
    Loop 24
        bins.Push({cnt: 0, r: 0, g: 0, b: 0})
    neutral := {cnt: 0, r: 0, g: 0, b: 0}                             ; black / grey / white pixels
    Loop sampH {
        y := A_Index - 1
        Loop sampW {
            x := A_Index - 1
            c := NumGet(scan0 + y * stride + x * 4, "UInt")
            r := (c >> 16) & 0xFF, g := (c >> 8) & 0xFF, b := c & 0xFF
            sr += r, sg += g, sb += b, n++
            hsl := RgbToHsl(r, g, b)
            if (hsl[3] < 0.40)                                        ; the picture's dark tone
                dr += r, dg += g, db += b, dn++
            chroma := (Max(r, g, b) - Min(r, g, b)) / 255.0          ; colourfulness: dim but saturated glows still count
            e := (chroma >= 0.08) ? bins[Floor(hsl[1] / 15) + 1] : neutral
            e.cnt++, e.r += r, e.g += g, e.b += b
        }
    }
    DllCall("gdiplus\GdipBitmapUnlockBits", "Ptr", pBmp, "Ptr", bd)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
    ; colour clusters ranked by AREA: hue bins merged with their neighbours, at least 40 degrees apart, plus the
    ; neutral mass; each entry is [r, g, b, share of the picture, isNeutral], largest share first
    clusters := [], used := []
    Loop 5 {
        bestB := 0, bestC := 0
        Loop 24 {
            bIdx := A_Index
            cSum := bins[bIdx].cnt + bins[Mod(bIdx - 2 + 24, 24) + 1].cnt + bins[Mod(bIdx, 24) + 1].cnt
            if (cSum <= bestC || cSum < n * 0.015)
                continue
            far := true
            for u in used
                if (Min(Abs(bIdx - u), 24 - Abs(bIdx - u)) < 3)
                    far := false
            if (far)
                bestB := bIdx, bestC := cSum
        }
        if (!bestB)
            break
        used.Push(bestB)
        cr := 0, cg := 0, cb := 0, cc := 0
        for bIdx in [bestB, Mod(bestB - 2 + 24, 24) + 1, Mod(bestB, 24) + 1] {
            e := bins[bIdx]
            cr += e.r, cg += e.g, cb += e.b, cc += e.cnt
        }
        clusters.Push([Round(cr / cc), Round(cg / cc), Round(cb / cc), cc / n, 0])
    }
    if (neutral.cnt >= n * 0.015)
        clusters.Push([Round(neutral.r / neutral.cnt), Round(neutral.g / neutral.cnt), Round(neutral.b / neutral.cnt), neutral.cnt / n, 1])
    ; sort by share, largest first (insertion sort, at most 6 entries)
    Loop clusters.Length - 1 {
        i := A_Index + 1
        Loop i - 1 {
            j := i - A_Index
            if (clusters[j][4] >= clusters[j + 1][4])
                break
            tmp := clusters[j], clusters[j] := clusters[j + 1], clusters[j + 1] := tmp
        }
    }
    dark := dn ? [Round(dr / dn), Round(dg / dn), Round(db / dn)] : [Round(sr / n), Round(sg / n), Round(sb / n)]
    return {avg: [Round(sr / n), Round(sg / n), Round(sb / n)], dark: dark, clusters: clusters}
}
HueMix(h1, h2, t) {
    d := Mod(h2 - h1 + 540, 360) - 180
    return Mod(h1 + d * t + 360, 360)
}
RgbToHsl(r, g, b) {
    r /= 255.0, g /= 255.0, b /= 255.0
    mx := Max(r, g, b), mn := Min(r, g, b), l := (mx + mn) / 2, d := mx - mn
    if (d < 0.0001)
        return [0, 0, l]
    s := (l > 0.5) ? d / (2 - mx - mn) : d / (mx + mn)
    if (mx == r)
        h := Mod((g - b) / d + (g < b ? 6 : 0), 6)
    else if (mx == g)
        h := (b - r) / d + 2
    else
        h := (r - g) / d + 4
    return [h * 60, s, l]
}
HslToHex(h, s, l) {
    c := (1 - Abs(2 * l - 1)) * s, hp := Mod(h, 360) / 60, x := c * (1 - Abs(Mod(hp, 2) - 1)), m := l - c / 2
    if (hp < 1)
        r := c, g := x, b := 0
    else if (hp < 2)
        r := x, g := c, b := 0
    else if (hp < 3)
        r := 0, g := c, b := x
    else if (hp < 4)
        r := 0, g := x, b := c
    else if (hp < 5)
        r := x, g := 0, b := c
    else
        r := c, g := 0, b := x
    return Format("{:02X}{:02X}{:02X}", Round((r + m) * 255), Round((g + m) * 255), Round((b + m) * 255))
}
; Dark UI palette from the wallpaper, balanced by AREA: the colour covering most of the picture tints the largest
; UI area (window background), the next one the panels, then lines / grid / secondary text, then slider fills
; and switches, and the rarest colour becomes the accent (headings, readouts, thumbs). Neutral black/grey/white
; masses keep their surfaces neutral and never become an accent. `intensity` (25..100) scales the tinting.
; `order` is the ranking of the UI's colour groups by the area they really cover in that window (measured by the
; page: "panel>bg>btn>line>fill>accent"); the i-th largest group gets the i-th most common colour.
global DEFAULT_AREA_ORDER := "panel>bg>btn>line>fill>accent"
ThemeFromWallpaperColours(col, intensity := 70, order := "") {
    global THEMES, DEFAULT_AREA_ORDER
    if (!IsObject(col))
        return CloneTheme(THEMES["Lava Orange"])
    k := Max(0.25, Min(1.0, intensity / 100))
    ; clusters as {h, s, l, neutral}, largest area first
    cs := []
    for c in col.clusters {
        hsl := RgbToHsl(c[1], c[2], c[3])
        cs.Push({h: hsl[1], s: hsl[2], l: hsl[3], neutral: c[5]})
    }
    if (!cs.Length) {
        d := RgbToHsl(col.dark[1], col.dark[2], col.dark[3])
        cs.Push({h: d[1], s: d[2], l: d[3], neutral: (d[2] < 0.12)})
    }
    ; UI colour groups ranked by covered area -> clusters ranked by picture area
    groups := StrSplit((order != "") ? order : DEFAULT_AREA_ORDER, ">")
    for g in StrSplit(DEFAULT_AREA_ORDER, ">") {                ; any group the page did not mention goes last
        found := false
        for x in groups
            if (x == g)
                found := true
        if (!found)
            groups.Push(g)
    }
    assign := Map()
    for i, g in groups
        assign[g] := cs[Min(i, cs.Length)]
    ; the accent and the fills must be real colours: swap a neutral assignment for the rarest colourful clusters
    colourful := []
    Loop cs.Length {
        c := cs[cs.Length - A_Index + 1]
        if (!c.neutral)
            colourful.Push(c)                                   ; rarest first
    }
    if (!colourful.Length)
        colourful.Push({h: HueMix(cs[1].h, 30, 0.5), s: 0.5, l: 0.6, neutral: 0})
    if (assign["accent"].neutral)
        assign["accent"] := colourful[1]
    if (assign["fill"].neutral)
        assign["fill"] := colourful[Min(2, colourful.Length)]
    if (assign["fill"] == assign["accent"] && colourful.Length > 1)
        assign["fill"] := (colourful[1] == assign["accent"]) ? colourful[2] : colourful[1]
    cBg := assign["bg"], cPanel := assign["panel"], cBtn := assign["btn"], cLine := assign["line"], cFill := assign["fill"], cAcc := assign["accent"]
    ; saturation of a surface tinted by a cluster: neutral clusters stay neutral, colourful ones scale with intensity
    surfSat(c, mult := 1.0) => c.neutral ? 0.04 : Min(0.75, (Max(0.14, c.s * 1.5) * k + 0.05 * k) * mult)
    accent := HslToHex(cAcc.h, Max(0.72, cAcc.s), Max(0.56, Min(0.72, cAcc.l)))
    fill := HslToHex(cFill.h, Max(0.65, cFill.s), Max(0.52, Min(0.68, cFill.l)))
    thumb := HslToHex(cAcc.h, Max(0.62, cAcc.s), Max(0.68, Min(0.82, cAcc.l + 0.15)))
    t := MakeTheme(HslToHex(cBg.h, surfSat(cBg), 0.085 + 0.025 * k),                     ; bg
                   HslToHex(cBg.h, Min(0.14, surfSat(cBg)), 0.96),                        ; text
                   HslToHex(cLine.h, cLine.neutral ? 0.05 : 0.20 + 0.10 * k, 0.68),       ; muted
                   accent,                                                                ; accent
                   HslToHex(cLine.h, surfSat(cLine, 0.9), 0.24 + 0.03 * k),               ; line
                   HslToHex(cPanel.h, surfSat(cPanel, 1.1), 0.16),                        ; panel (cards, title bar)
                   HslToHex(cBg.h, surfSat(cBg), 0.12),                                   ; graphBg
                   HslToHex(cLine.h, cLine.neutral ? 0.05 : 0.30 + 0.15 * k, 0.42))       ; grid
    t.btnFace := HslToHex(cBtn.h, surfSat(cBtn, 1.2), 0.20 + 0.02 * k)                   ; buttons, key boxes
    t.btnText := t.text
    t.checkOn := fill                                                                     ; switches, checkboxes
    t.sliderTrack := HslToHex(cBtn.h, surfSat(cBtn, 0.8), 0.24)                          ; slider tracks
    t.sliderFill := fill                                                                  ; slider fills
    t.sliderThumb := thumb                                                                ; thumbs
    t.accent2 := fill                                                                     ; second accent: the fill colour, so gradients run between two picture colours
    return t
}
; The image analysis (the slow part) is cached per file; the palette itself is cheap and follows the intensity setting.
WallpaperThemeForPath(path, order := "") {
    global WALLPAPER_CACHE, wpImgDir, wpIntensity
    if (path == "" || !FileExist(path)) {
        c := DesktopBackgroundColour()
        chroma := (Max(c[1], c[2], c[3]) - Min(c[1], c[2], c[3])) / 255.0
        return ThemeFromWallpaperColours({avg: c, dark: c, clusters: [[c[1], c[2], c[3], 1.0, chroma < 0.08 ? 1 : 0]]}, wpIntensity, order)
    }
    key := path . "|" . FileGetTime(path, "M") . "|" . FileGetSize(path)
    imgName := Format("wp_{:08X}.jpg", DllCall("ntdll\RtlComputeCrc32", "UInt", 0, "Ptr", StrPtr(key), "UInt", StrLen(key) * 2, "UInt"))
    if !WALLPAPER_CACHE.Has(key) {
        t0 := A_TickCount
        try DirCreate(wpImgDir)
        col := ImageColours(path, FileExist(wpImgDir . "\" . imgName) ? "" : wpImgDir . "\" . imgName)
        if (WALLPAPER_CACHE.Count > 12)
            WALLPAPER_CACHE.Clear()
        WALLPAPER_CACHE[key] := col
        desc := ""
        if IsObject(col)
            for v in col.clusters
                desc .= Format(" #{:02X}{:02X}{:02X}({}%{})", v[1], v[2], v[3], Round(v[4] * 100), v[5] ? " neutral" : "")
        LogAction("[Wallpaper] analysed " . path . " in " . (A_TickCount - t0) . " ms, colours by area:" . desc)
    }
    t := ThemeFromWallpaperColours(WALLPAPER_CACHE[key], wpIntensity, order)
    t.img := FileExist(wpImgDir . "\" . imgName) ? imgName : ""
    return t
}
WallpaperThemeForMonitor(idx) {
    paths := WallpaperPathsByMonitor()
    return WallpaperThemeForPath(paths.Has(idx) ? paths[idx] : "")
}
; Palette for the theme picker tile. Decoding a big wallpaper costs up to a second, so while another theme is
; active the tile only uses an already computed palette and otherwise schedules the work for later.
WallpaperThemeForTile(host) {
    global THEMES, themeName, WALLPAPER_CACHE
    if (themeName == "Wallpaper")
        return (host != "") ? WallpaperThemeForHost(host) : WallpaperThemeForMonitor(MonitorGetPrimary())
    idx := (host != "") ? HostMonitorIndex(host) : MonitorGetPrimary()
    paths := WallpaperPathsByMonitor()
    path := paths.Has(idx) ? paths[idx] : ""
    if (path != "" && FileExist(path)) {
        key := path . "|" . FileGetTime(path, "M") . "|" . FileGetSize(path)
        if WALLPAPER_CACHE.Has(key)
            return WallpaperThemeForPath(path)
        SetTimer(PrewarmWallpaperPalettes, -200)
        return THEMES["Wallpaper"]
    }
    return WallpaperThemeForPath(path)
}
; Computes the palettes of every screen's wallpaper in the background and refreshes the theme tiles.
PrewarmWallpaperPalettes() {
    global themeName
    Loop MonitorGetCount()
        WallpaperThemeForMonitor(A_Index)
    if (themeName != "Wallpaper")
        PushState()
}
; Palette for a screen under the current theme.
ThemeForMonitor(idx) {
    global THEMES, themeName
    return (themeName == "Wallpaper") ? WallpaperThemeForMonitor(idx) : THEMES[themeName]
}
HostMonitorIndex(host) {
    hMon := DllCall("user32\MonitorFromWindow", "Ptr", host.hwnd, "UInt", 2, "Ptr")
    mi := Buffer(40, 0), NumPut("UInt", 40, mi)
    if DllCall("user32\GetMonitorInfoW", "Ptr", hMon, "Ptr", mi) {
        L := NumGet(mi, 4, "Int"), T := NumGet(mi, 8, "Int")
        Loop MonitorGetCount() {
            MonitorGet(A_Index, &mL, &mT, &mR, &mB)
            if (mL == L && mT == T)
                return A_Index
        }
    }
    return MonitorGetPrimary()
}
; The wallpaper palette of the screen a host window is on (independent of the selected theme; used for the preview tile).
WallpaperThemeForHost(host) {
    if (!IsObject(host.wpTheme))
        RefreshHostWallpaperTheme(host)
    return host.wpTheme
}
; Palette a host window should use under the current theme.
HostTheme(host) {
    global THEMES, themeName
    return (themeName == "Wallpaper") ? WallpaperThemeForHost(host) : THEMES[themeName]
}
; Recomputes a host's wallpaper palette from the screen it is on; with push, applies + pushes it when it changed.
RefreshHostWallpaperTheme(host, push := false) {
    global themeName
    idx := HostMonitorIndex(host)
    paths := WallpaperPathsByMonitor()
    path := paths.Has(idx) ? paths[idx] : ""
    t := WallpaperThemeForPath(path, host.areaOrder)
    sig(x) => x.bg . x.input . x.line . x.accent . x.sliderFill . x.sliderThumb . x.btnFace . x.grid
    changed := !(IsObject(host.wpTheme) && sig(host.wpTheme) == sig(t) && host.wpMon == idx)
    host.wpTheme := t, host.wpMon := idx, host.wpPath := path
    if (changed && push && themeName == "Wallpaper") {
        LogAction("[Wallpaper] " . host.view . " now follows screen " . idx . " (" . path . ")")
        ApplyGlass(host.hwnd, host.gui, t.bg)
        PushState(host)
    }
    return changed
}
RefreshWallpaperThemes() {
    global flyout, settings, themeName
    if (themeName != "Wallpaper")
        return
    for h in [flyout, settings]
        if (h != "")
            RefreshHostWallpaperTheme(h, true)
}
SyncWallpaperWatch() {
    global themeName
    SetTimer(RefreshWallpaperThemes, (themeName == "Wallpaper") ? 30000 : 0)     ; catches slideshows and per-screen changes
}
OnSettingChange(wParam, lParam, msg, hwnd) {
    global themeName
    if (themeName == "Wallpaper" && wParam == 0x14)                                 ; SPI_SETDESKWALLPAPER
        SetTimer(RefreshWallpaperThemes, -1500)
}
OnMessage(0x001A, OnSettingChange)                                                  ; WM_SETTINGCHANGE
; Every theme except Wallpaper can be edited; edits live in the INI ([CustomTheme] for Custom, [Theme_<Name>] for
; the presets) and are applied on top of the built-in palettes at startup.
ThemeIniSection(name) => (name == "Custom") ? "CustomTheme" : "Theme_" . StrReplace(name, " ", "")
EditableThemes() {
    global THEME_ORDER
    names := []
    for name in THEME_ORDER
        if (name != "Wallpaper" && name != "Sky")
            names.Push(name)
    return names
}
SaveThemeColours(name) {
    global iniFile, THEMES, COLOR_SLOTS
    for slot in COLOR_SLOTS
        IniWrite(THEMES[name].%slot[1]%, iniFile, ThemeIniSection(name), slot[1])
}
LoadThemeColours() {
    global iniFile, THEMES, COLOR_SLOTS
    for name in EditableThemes() {
        for slot in COLOR_SLOTS {
            v := IniRead(iniFile, ThemeIniSection(name), slot[1], "")
            if RegExMatch(v, "^[0-9A-Fa-f]{6}$")
                THEMES[name].%slot[1]% := StrUpper(v)
        }
    }
}
ResetTheme(name) {
    global iniFile, THEMES, THEME_DEFAULTS
    if (!THEME_DEFAULTS.Has(name))
        return
    THEMES[name] := CloneTheme(THEME_DEFAULTS[name])
    try IniDelete(iniFile, ThemeIniSection(name))
}
SaveCustomTheme() {
    SaveThemeColours("Custom")
}
LoadCustomTheme() {
    LoadThemeColours()
}

; =========================================================================
; 🔁 PRIMARY DISPLAY GUARD + FLIPPER
; =========================================================================
; Active display devices with their current desktop positions (EnumDisplayDevices + EnumDisplaySettings).
EnumActiveDisplays() {
    devs := []
    i := 0
    Loop {
        dd := Buffer(840, 0), NumPut("UInt", 840, dd)
        if !DllCall("user32\EnumDisplayDevicesW", "Ptr", 0, "UInt", i, "Ptr", dd, "UInt", 0)
            break
        i++
        flags := NumGet(dd, 324, "UInt")                       ; StateFlags
        if !(flags & 0x1)                                      ; DISPLAY_DEVICE_ATTACHED_TO_DESKTOP
            continue
        name := StrGet(dd.Ptr + 4, 32)
        dm := Buffer(220, 0), NumPut("UShort", 220, dm, 68)    ; DEVMODEW.dmSize
        if !DllCall("user32\EnumDisplaySettingsW", "Str", name, "Int", -1, "Ptr", dm)
            continue
        devs.Push({name: name, primary: (flags & 0x4) ? 1 : 0, x: NumGet(dm, 76, "Int"), y: NumGet(dm, 80, "Int"), dm: dm})
    }
    return devs
}
; Friendly monitor names as Display Settings shows them (DisplayConfig API), keyed by GDI device name (\\.\DISPLAYn).
GetDisplayFriendlyNames() {
    names := Map()
    nPath := 0, nMode := 0
    if DllCall("user32\GetDisplayConfigBufferSizes", "UInt", 2, "UInt*", &nPath, "UInt*", &nMode)      ; QDC_ONLY_ACTIVE_PATHS
        return names
    paths := Buffer(nPath * 72, 0), modes := Buffer(Max(1, nMode) * 64, 0)
    if DllCall("user32\QueryDisplayConfig", "UInt", 2, "UInt*", &nPath, "Ptr", paths, "UInt*", &nMode, "Ptr", modes, "Ptr", 0)
        return names
    Loop nPath {
        p := paths.Ptr + (A_Index - 1) * 72
        ; DISPLAYCONFIG_PATH_INFO: source {adapterId LUID, id} at 0, target {adapterId, id, modeInfoIdx, outputTechnology} at 20
        src := Buffer(84, 0)                                             ; DISPLAYCONFIG_SOURCE_DEVICE_NAME
        NumPut("UInt", 1, "UInt", 84, "UInt", NumGet(p, 0, "UInt"), "Int", NumGet(p, 4, "Int"), "UInt", NumGet(p, 8, "UInt"), src)
        if DllCall("user32\DisplayConfigGetDeviceInfo", "Ptr", src)
            continue
        gdi := StrGet(src.Ptr + 20, 32)
        tgt := Buffer(420, 0)                                            ; DISPLAYCONFIG_TARGET_DEVICE_NAME
        NumPut("UInt", 2, "UInt", 420, "UInt", NumGet(p, 20, "UInt"), "Int", NumGet(p, 24, "Int"), "UInt", NumGet(p, 28, "UInt"), tgt)
        friendly := ""
        if !DllCall("user32\DisplayConfigGetDeviceInfo", "Ptr", tgt)
            friendly := Trim(StrGet(tgt.Ptr + 36, 64))
        tech := NumGet(p, 36, "UInt")
        if (friendly == "")
            friendly := (tech == 0x80000000 || tech == 11) ? "Built-in display" : "Display"     ; INTERNAL / DISPLAYPORT_EMBEDDED
        names[gdi] := friendly
    }
    return names
}
; Friendly names by AutoHotkey monitor index (duplicates get a suffix), cached for a few seconds.
MonitorNamesByIndex() {
    static cache := Map(), cachedAt := 0, cachedCount := 0
    if (cache.Count && A_TickCount - cachedAt < 5000 && cachedCount == MonitorGetCount())
        return cache
    result := Map(), seen := Map()
    friendly := GetDisplayFriendlyNames()
    for d in EnumActiveDisplays() {
        idx := DisplayIndexForDevice(d)
        if (!idx)
            continue
        n := friendly.Has(d.name) ? friendly[d.name] : "Display"
        seen[n] := seen.Has(n) ? seen[n] + 1 : 1
        result[idx] := (seen[n] > 1) ? n . " (" . seen[n] . ")" : n
    }
    Loop MonitorGetCount()
        if (!result.Has(A_Index))
            result[A_Index] := "Display " . A_Index
    cache := result, cachedAt := A_TickCount, cachedCount := MonitorGetCount()
    return cache
}
MonitorName(idx) {
    names := MonitorNamesByIndex()
    return names.Has(idx) ? names[idx] : "Display " . idx
}
DeviceFriendlyName(dev) {
    return MonitorName(DisplayIndexForDevice(dev))
}
; AutoHotkey monitor index of a display device (matched by the top-left corner of its rectangle).
DisplayIndexForDevice(dev) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &L, &T, &R, &B)
        if (L == dev.x && T == dev.y)
            return A_Index
    }
    return 0
}
; Makes `target` (an entry of `devs`) the primary display: every display is shifted so the target sits at 0,0.
; The changes are staged in the registry (CDS_NORESET) and applied together by the final call.
SetPrimaryDisplayDevice(target, devs) {
    dx := target.x, dy := target.y
    order := [target]
    for d in devs
        if (d.name != target.name)
            order.Push(d)
    for d in order {
        NumPut("Int", d.x - dx, d.dm, 76), NumPut("Int", d.y - dy, d.dm, 80)             ; dmPosition
        NumPut("UInt", NumGet(d.dm, 72, "UInt") | 0x20, d.dm, 72)                          ; dmFields |= DM_POSITION
        flags := 0x1 | 0x10000000 | (d.name == target.name ? 0x10 : 0)                     ; CDS_UPDATEREGISTRY | CDS_NORESET | CDS_SET_PRIMARY
        r := DllCall("user32\ChangeDisplaySettingsExW", "Str", d.name, "Ptr", d.dm, "Ptr", 0, "UInt", flags, "Ptr", 0)
        if (r != 0) {
            LogAction("[Primary] staging " . d.name . " failed (result " . r . ")")
            return false
        }
    }
    r := DllCall("user32\ChangeDisplaySettingsExW", "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt", 0, "Ptr", 0)
    LogAction("[Primary] " . target.name . " is now the primary display (result " . r . ")")
    return r == 0
}
; DDC/CI power mode (VCP code 0xD6) of the monitor at an AutoHotkey index:
; "On", "Off" (standby / suspend / off) or "Unknown" (no DDC/CI reply - laptop panels, unpowered monitors).
QueryMonitorPowerState(mIdx) {
    if (mIdx < 1 || mIdx > MonitorGetCount())
        return "Unknown"
    hMon := GetHMonitorFromIndex(mIdx)
    n := 0
    if !(DllCall("Dxva2\GetNumberOfPhysicalMonitorsFromHMONITOR", "Ptr", hMon, "UInt*", &n) && n > 0)
        return "Unknown"
    pm := Buffer(n * (A_PtrSize + 256), 0)
    if !DllCall("Dxva2\GetPhysicalMonitorsFromHMONITOR", "Ptr", hMon, "UInt", n, "Ptr", pm)
        return "Unknown"
    state := "Unknown", cur := 0, mx := 0
    if DllCall("Dxva2\GetVCPFeatureAndVCPFeatureReply", "Ptr", NumGet(pm, 0, "Ptr"), "UChar", 0xD6, "Ptr", 0, "UInt*", &cur, "UInt*", &mx)
        state := (cur == 1) ? "On" : "Off"
    DllCall("Dxva2\DestroyPhysicalMonitors", "UInt", n, "Ptr", pm)
    return state
}
; The next display after the current primary (in device order) that is not reporting "Off".
NextDisplayCandidate(devs) {
    pi := 0
    for i, d in devs
        if d.primary
            pi := i
    Loop devs.Length - 1 {
        d := devs[Mod(pi - 1 + A_Index, devs.Length) + 1]
        if (QueryMonitorPowerState(DisplayIndexForDevice(d)) != "Off")
            return d
    }
    return ""
}
PromotePrimary(target, devs, why) {
    global guardLastEvent, guardFailCount, guardBaselineOk
    label := DeviceFriendlyName(target)          ; resolve before the topology changes
    ok := SetPrimaryDisplayDevice(target, devs)
    guardFailCount := 0, guardBaselineOk := false
    guardLastEvent := FormatTime(, "HH:mm") . " - " . (why == "swap" ? "swapped" : "auto-switched") . " primary to " . label . (ok ? "" : " (failed)")
    Toast(ok ? "Primary display is now " . label : "Windows refused to change the primary display.")
    SetTimer(RefreshAfterDisplayChange, -800)
    return ok
}
RefreshAfterDisplayChange() {
    UpdateDisplayState(), PushState()
}
; Flipper: with two displays a swap; with more, the next display in order becomes primary.
FlipPrimaryDisplay(*) {
    devs := EnumActiveDisplays()
    if (devs.Length < 2) {
        Toast("Only one active display - nothing to swap.")
        return false
    }
    next := NextDisplayCandidate(devs)
    if (next == "") {
        Toast("No other powered display to switch to.")
        return false
    }
    return PromotePrimary(next, devs, "swap")
}
SetPrimaryGuard(on) {
    global primaryGuardEnabled, guardFailCount, guardBaselineOk, guardLastPower, PRIMARY_GUARD_INTERVAL
    primaryGuardEnabled := on ? 1 : 0
    guardFailCount := 0, guardBaselineOk := false, guardLastPower := ""
    SetTimer(PrimaryGuardTick, primaryGuardEnabled ? PRIMARY_GUARD_INTERVAL : 0)
    LogAction("[Primary guard] " . (primaryGuardEnabled ? "enabled (every " . PRIMARY_GUARD_INTERVAL . " ms)" : "disabled"))
}
PrimaryGuardTick() {
    global primaryGuardEnabled, guardFailCount, guardBaselineOk, guardLastPower, consoleDisplayOn, PRIMARY_GUARD_THRESHOLD
    if (!primaryGuardEnabled)
        return
    before := guardLastPower
    if (!consoleDisplayOn) {                       ; Windows itself switched the displays off: nothing to decide
        guardLastPower := "Displays sleeping (Windows)", guardFailCount := 0
    } else {
        devs := EnumActiveDisplays()
        pIdx := MonitorGetPrimary()
        state := QueryMonitorPowerState(pIdx)
        guardLastPower := state
        if (devs.Length < 2) {
            guardLastPower .= " (only one display)", guardFailCount := 0
        } else if (state == "On") {
            guardBaselineOk := true, guardFailCount := 0
        } else if (state == "Unknown" && !guardBaselineOk) {
            guardLastPower := "Unknown (no DDC/CI reply yet - cannot be judged)"
        } else {
            ; the primary looks unpowered: act only if another display is demonstrably not off
            otherOk := false
            Loop MonitorGetCount()
                if (A_Index != pIdx && QueryMonitorPowerState(A_Index) != "Off")
                    otherOk := true
            if (!otherOk) {
                guardFailCount := 0
            } else {
                guardFailCount++
                guardLastPower := state . " (" . guardFailCount . "/" . PRIMARY_GUARD_THRESHOLD . " before switching)"
                LogAction("[Primary guard] primary monitor #" . pIdx . " power=" . state . " strike " . guardFailCount . "/" . PRIMARY_GUARD_THRESHOLD)
                if (guardFailCount >= PRIMARY_GUARD_THRESHOLD) {
                    next := NextDisplayCandidate(devs)
                    if (next != "")
                        PromotePrimary(next, devs, "auto")
                    else
                        guardFailCount := 0
                }
            }
        }
    }
    if (guardLastPower != before)
        PushState()
}
; Windows' console display state (GUID_CONSOLE_DISPLAY_STATE): 0 off, 1 on, 2 dimmed.
RegisterDisplayPowerNotification(hwnd) {
    global powerNotifyHandle
    guid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "WStr", "{6FE69556-704A-47A0-8F24-C28D936FDA47}", "Ptr", guid)
    powerNotifyHandle := DllCall("user32\RegisterPowerSettingNotification", "Ptr", hwnd, "Ptr", guid, "UInt", 0, "Ptr")
    OnMessage(0x0218, OnPowerBroadcast)
}
OnPowerBroadcast(wParam, lParam, msg, hwnd) {
    global consoleDisplayOn
    if (wParam != 0x8013 || !lParam)                ; PBT_POWERSETTINGCHANGE
        return
    if (NumGet(lParam, 16, "UInt") >= 4) {          ; POWERBROADCAST_SETTING.DataLength, then Data
        v := NumGet(lParam, 20, "UInt")
        consoleDisplayOn := (v == 1)
        LogAction("[Primary guard] Windows display state = " . (v == 0 ? "off" : v == 1 ? "on" : "dimmed"))
    }
    return 1
}
PrimaryDisplayState() {
    global primaryGuardEnabled, guardLastPower, guardLastEvent, hotkeyFlipString
    devs := EnumActiveDisplays()
    pName := ""
    for d in devs
        if d.primary
            pName := d.name
    return {guard: primaryGuardEnabled, index: MonitorGetPrimary(), name: MonitorName(MonitorGetPrimary()), count: devs.Length, device: pName,
            power: guardLastPower, lastEvent: guardLastEvent}
}

; =========================================================================
; 🖥️ HARDWARE BRIGHTNESS ROUTER + GAMMA ENGINE (unchanged from v5)
; =========================================================================
NativeSetMonitorBrightness(targetBrightness, profileTargets, excludeIdx := "", exactTargets := false) {
    global linkAllDisplays
    cleanTargets := StrReplace(profileTargets, " ")
    targetArray := StrSplit(cleanTargets, ",")
    excludeArray := (excludeIdx != "") ? StrSplit(StrReplace(excludeIdx, " "), ",") : []
    monitorCount := MonitorGetCount()
    LogAction("[Display Router] Updating targets: [" . cleanTargets . "] at level: " . targetBrightness . "%" . (excludeIdx != "" ? " (excluding: " . excludeIdx . ")" : "") . (exactTargets ? " (exact)" : ""))
    isExcluded(idx) {
        for exId in excludeArray {
            if (Trim(exId) == String(idx))
                return true
        }
        return false
    }
    forceLaptop := (linkAllDisplays == 1) && !exactTargets && !isExcluded(1)
    if (!forceLaptop) {
        for targetID in targetArray {
            if (Trim(targetID) == "1" && !isExcluded(1)) {
                forceLaptop := true
                break
            }
        }
    }
    if (forceLaptop) {
        try {
            wmi := ComObjGet("winmgmts:{impersonationLevel=impersonate}!\\.\root\wmi")
            for monitor in wmi.InstancesOf("WmiMonitorBrightnessMethods")
                monitor.WmiSetBrightness(0, targetBrightness)
            LogAction("--> [Laptop Engine] WMI backlight set")
        } catch Error as err {
            LogAction("--> [Laptop Engine] WMI failed: " . err.Message)
        }
    }
    Loop monitorCount {
        currentIdx := A_Index
        if (currentIdx == 1 || isExcluded(currentIdx))
            continue
        isMatched := false
        for targetID in targetArray {
            cleanID := Trim(targetID)
            if (cleanID != "" && IsNumber(cleanID) && Integer(cleanID) == currentIdx) {
                isMatched := true
                break
            }
        }
        if (!isMatched)
            continue
        MonitorGet(currentIdx, &Left, &Top, &Right, &Bottom)
        midX := Left + (Right - Left) // 2, midY := Top + (Bottom - Top) // 2
        hMonitor := DllCall("User32\MonitorFromPoint", "Int64", (midX & 0xFFFFFFFF) | (midY << 32), "UInt", 2, "Ptr")
        NumMonitors := 0
        if DllCall("Dxva2\GetNumberOfPhysicalMonitorsFromHMONITOR", "Ptr", hMonitor, "UInt*", &NumMonitors) && NumMonitors > 0 {
            PhysicalMonitors := Buffer(NumMonitors * (A_PtrSize + 256))
            if DllCall("Dxva2\GetPhysicalMonitorsFromHMONITOR", "Ptr", hMonitor, "UInt", NumMonitors, "Ptr", PhysicalMonitors.Ptr) {
                Loop NumMonitors {
                    hPhys := NumGet(PhysicalMonitors, (A_Index - 1) * (A_PtrSize + 256), "Ptr")
                    DllCall("Dxva2\SetMonitorBrightness", "Ptr", hPhys, "UInt", targetBrightness)
                }
                DllCall("Dxva2\DestroyPhysicalMonitors", "UInt", NumMonitors, "Ptr", PhysicalMonitors.Ptr)
                LogAction("--> [External Engine] DDC/CI brightness sent to monitor #" . currentIdx)
            }
        } else {
            LogAction("--> [External Engine] DDC/CI failed for monitor #" . currentIdx)
        }
    }
}
MapRange(value, fromMin, fromMax, toMin, toMax) {
    global dimmingCurve, exponentialFactor, invertCurve
    n := (value - fromMin) / (fromMax - fromMin)
    if (dimmingCurve = "exponential")
        n := (invertCurve == 1) ? n ** exponentialFactor : 1 - ((1 - n) ** exponentialFactor)
    return toMin + n * (toMax - toMin)
}
GetHMonitorFromIndex(mIdx) {
    if (mIdx < 1 || mIdx > MonitorGetCount())
        return 0
    MonitorGet(mIdx, &L, &T, &R, &B)
    midX := L + (R - L) // 2, midY := T + (B - T) // 2
    return DllCall("User32\MonitorFromPoint", "Int64", (midX & 0xFFFFFFFF) | (midY << 32), "UInt", 2, "Ptr")
}
; brightness scales all three channels; rMul/gMul/bMul tint them (warmth). Windows may refuse a ramp that strays
; too far from the identity on some drivers; the tint is then softened step by step until a ramp is accepted.
SetMonitorGammaRamp(mIdx, brightness, rMul := 1.0, gMul := 1.0, bMul := 1.0) {
    static warnedSoften := Map()
    hMonitor := GetHMonitorFromIndex(mIdx)
    monInfo := Buffer(104, 0)
    NumPut("UInt", 104, monInfo)
    if !DllCall("User32\GetMonitorInfoW", "Ptr", hMonitor, "Ptr", monInfo)
        return false
    deviceName := StrGet(monInfo.Ptr + 40, 32, "UTF-16")
    hDC := DllCall("Gdi32\CreateDCW", "Str", deviceName, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    if (!hDC)
        return false
    ramp := Buffer(1536, 0), result := 0
    Loop 4 {
        soften := (A_Index - 1) / 4                 ; 0, .25, .5, .75 of the way back to neutral
        mr := rMul + (1 - rMul) * soften, mg := gMul + (1 - gMul) * soften, mb := bMul + (1 - bMul) * soften
        Loop 256 {
            i := A_Index - 1, base := i * 256 * brightness
            NumPut("UShort", Min(65535, Round(base * mr)), ramp, i * 2)
            NumPut("UShort", Min(65535, Round(base * mg)), ramp, 512 + (i * 2))
            NumPut("UShort", Min(65535, Round(base * mb)), ramp, 1024 + (i * 2))
        }
        result := DllCall("Gdi32\SetDeviceGammaRamp", "Ptr", hDC, "Ptr", ramp)
        if (result || (rMul == 1.0 && gMul == 1.0 && bMul == 1.0))
            break
        if (!warnedSoften.Has(deviceName)) {
            warnedSoften[deviceName] := true
            LogAction("[Gamma] " . deviceName . " refused a warm ramp; softening the tint")
        }
    }
    DllCall("Gdi32\DeleteDC", "Ptr", hDC)
    return result ? true : false
}
ResetAllGammaRamps(*) {
    global gammaNow, gammaAnim
    SetTimer(GammaAnimTick, 0)
    gammaAnim := Map(), gammaNow := Map()
    Loop MonitorGetCount()
        SetMonitorGammaRamp(A_Index, 1.0)
    LogAction("[Gamma] All monitor gamma ramps reset to default (1.0)")
}

; ---- warmth (colour temperature) ----
; Tanner Helland's blackbody approximation; the channel multipliers are relative to 6500 K so 0 % warmth is neutral.
KelvinToRGB(K) {
    t := K / 100
    r := (t <= 66) ? 255 : 329.698727446 * ((t - 60) ** -0.1332047592)
    g := (t <= 66) ? 99.4708025861 * Ln(t) - 161.1195681661 : 288.1221695283 * ((t - 60) ** -0.0755148492)
    b := (t >= 66) ? 255 : (t <= 19) ? 0 : 138.5177312231 * Ln(t - 10) - 305.0447927307
    return [Max(0, Min(255, r)), Max(0, Min(255, g)), Max(0, Min(255, b))]
}
WarmthToKelvin(w) {
    global WARMTH_K_NEUTRAL, WARMTH_K_WARMEST
    return Round(WARMTH_K_NEUTRAL - (Max(0, Min(100, w)) / 100) * (WARMTH_K_NEUTRAL - WARMTH_K_WARMEST))
}
WarmthMultipliers(w) {
    static ref := "", cache := Map()
    if (w <= 0)
        return [1.0, 1.0, 1.0]
    if (cache.Has(w))
        return cache[w]
    if (ref == "")
        ref := KelvinToRGB(6500)
    c := KelvinToRGB(WarmthToKelvin(w))
    return cache[w] := [Min(1.0, c[1] / ref[1]), Min(1.0, c[2] / ref[2]), Min(1.0, c[3] / ref[3])]
}
; Windows Night Light keeps its on/off state in a CloudStore blob; byte 18 is 0x15 when it is on.
WindowsNightLightOn() {
    static cachedAt := 0, cached := 0
    if (A_TickCount - cachedAt < 5000 && cachedAt)
        return cached
    cachedAt := A_TickCount, cached := 0
    try {
        hex := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate", "Data")
        cached := (StrLen(hex) >= 38 && SubStr(hex, 37, 2) = "15") ? 1 : 0
    }
    return cached
}

; ---- smooth gamma transitions ----
; gammaNow holds what each screen shows ([level, r, g, b]); a change bigger than GAMMA_SMOOTH_MIN fades over
; GAMMA_ANIM_STEPS ticks of 25 ms (ease-out) when smoothTransitions is on. Small steps (hotkey repeats, slider
; drags) are applied at once so they stay responsive.
global gammaNow := Map(), gammaAnim := Map()
global GAMMA_ANIM_STEPS := 8, GAMMA_SMOOTH_MIN := 0.04
ApplyGammaSmooth(mIdx, level, mul) {
    global gammaNow, gammaAnim, smoothTransitions, GAMMA_SMOOTH_MIN
    target := [level, mul[1], mul[2], mul[3]]
    if (gammaNow.Has(mIdx)) {
        cur := gammaNow[mIdx], diff := 0
        Loop 4
            diff := Max(diff, Abs(cur[A_Index] - target[A_Index]))
        ; (an unchanged value is still written: Windows resets ramps after sleep or a display change)
        if (smoothTransitions && diff > GAMMA_SMOOTH_MIN) {
            gammaAnim[mIdx] := {from: cur.Clone(), to: target, step: 0}
            SetTimer(GammaAnimTick, 25)
            return
        }
    }
    if (gammaAnim.Has(mIdx))
        gammaAnim.Delete(mIdx)
    gammaNow[mIdx] := target
    SetMonitorGammaRamp(mIdx, target[1], target[2], target[3], target[4])
}
GammaAnimTick() {
    global gammaNow, gammaAnim, GAMMA_ANIM_STEPS
    done := []
    for mIdx, an in gammaAnim {
        an.step += 1
        t := an.step / GAMMA_ANIM_STEPS, e := 1 - (1 - t) ** 3          ; ease-out cubic
        v := []
        Loop 4
            v.Push(an.from[A_Index] + (an.to[A_Index] - an.from[A_Index]) * e)
        if (an.step >= GAMMA_ANIM_STEPS)
            v := an.to, done.Push(mIdx)
        gammaNow[mIdx] := v
        if (mIdx <= MonitorGetCount())
            SetMonitorGammaRamp(mIdx, v[1], v[2], v[3], v[4])
    }
    for mIdx in done
        gammaAnim.Delete(mIdx)
    if (gammaAnim.Count == 0)
        SetTimer(GammaAnimTick, 0)
}
; gammaOnly: only the colour/gamma side changed (warmth, the Software or Warmth tick), so the backlight writes
; (DDC/CI takes up to a second per monitor and blocks the app meanwhile) are skipped.
UpdateDisplayState(gammaOnly := false) {
    global currentHardwareBright, currentSoftwareDim, externalMonitorNum, iniFile
    global minHardwareBrightness, maxHardwareBrightness, maxSoftwareDarkness, dimStates, warmStates
    global monitorSplitMode, monitorHW, monitorSW, warmth
    try {
        IniWrite(currentHardwareBright, iniFile, "Settings", "LastHardwareBright")
        IniWrite(currentSoftwareDim, iniFile, "Settings", "LastSoftwareDim")
        IniWrite(warmth, iniFile, "Settings", "Warmth")
    }
    warmMul := WarmthMultipliers(warmth)
    monitorCount := MonitorGetCount()
    splitExclusions := ""
    Loop monitorCount {
        if (monitorSplitMode.Has(A_Index) && monitorSplitMode[A_Index] == 1)
            splitExclusions .= (splitExclusions = "" ? "" : ",") . A_Index
    }
    if (!gammaOnly)
        NativeSetMonitorBrightness(currentHardwareBright, externalMonitorNum, splitExclusions)
    minGammaFloor := Max(0.05, 1.0 - (maxSoftwareDarkness / 255))
    Loop monitorCount {
        mIdx := A_Index
        isSplit := (monitorSplitMode.Has(mIdx) && monitorSplitMode[mIdx] == 1)
        swValue := isSplit ? (monitorSW.Has(mIdx) ? monitorSW[mIdx] : currentSoftwareDim) : currentSoftwareDim
        calculatedGamma := Max(minGammaFloor, MapRange(swValue, minHardwareBrightness, maxHardwareBrightness, 0.0, 1.0))
        isDimEnabled := !dimStates.Has(mIdx) || dimStates[mIdx] == 1
        ; brightness and warmth share the gamma ramp but have separate ticks: a screen can be warmed without
        ; being dimmed (level 1.0 with the tint) and dimmed without being warmed
        ApplyGammaSmooth(mIdx, (calculatedGamma < 1.0 && isDimEnabled) ? calculatedGamma : 1.0, IsWarmTarget(mIdx) ? warmMul : [1.0, 1.0, 1.0])
        ; a screen's Backlight tick gates its own slider too: unticked means "leave this screen's backlight alone"
        if (!gammaOnly && isSplit && IsBacklightTarget(mIdx))
            NativeSetMonitorBrightness(monitorHW.Has(mIdx) ? monitorHW[mIdx] : currentHardwareBright, String(mIdx), "", true)
    }
    LogAction("[Gamma Router] Master software brightness=" . currentSoftwareDim . (warmth ? ", warmth " . warmth . "% (" . WarmthToKelvin(warmth) . " K)" : ""))
}
OnDisplayChange(wParam, lParam, msg, hwnd) {
    global lastKnownMonitorCount
    newCount := MonitorGetCount()
    if (newCount != lastKnownMonitorCount) {
        LogAction("[Display] Monitor count changed from " . lastKnownMonitorCount . " to " . newCount)
        lastKnownMonitorCount := newCount
        UpdateDisplayState(), PushState()
    }
}

; =========================================================================
; ⏰ SCHEDULED BRIGHTNESS (engine from v5; UI lives in the page)
; =========================================================================
DefaultScheduleRows() {
    global SCHED_ROWS
    rows := []
    rows.Push({on: 1, time: "07:00", hw: 70, sw: 80}), rows.Push({on: 1, time: "12:00", hw: 100, sw: 100})
    rows.Push({on: 1, time: "18:00", hw: 60, sw: 70}), rows.Push({on: 1, time: "22:00", hw: 20, sw: 40})
    Loop SCHED_ROWS - rows.Length
        rows.Push({on: 0, time: "", hw: 50, sw: 50})
    return rows
}
ScheduleRowToString(i) {
    global schedRows
    r := schedRows[i]
    return r.on . "|" . r.time . "|" . r.hw . "|" . r.sw
}
SetScheduleRowFromString(i, str) {
    global schedRows, SCHED_ROWS
    if (i < 1 || i > SCHED_ROWS)
        return
    p := StrSplit(str, "|")
    if (p.Length < 4)
        return
    schedRows[i] := {on: IsNumber(p[1]) ? (Integer(p[1]) ? 1 : 0) : 0, time: Trim(p[2]),
                     hw: IsNumber(p[3]) ? Clamp(p[3]) : 50, sw: IsNumber(p[4]) ? Clamp(p[4]) : 50}
}
NowMins() => (Integer(A_Hour) * 60) + Integer(A_Min)
ParseHHMM(s, &mins) {
    if RegExMatch(Trim(s), "^(\d{1,2}):(\d{2})$", &m) {
        h := Integer(m[1]), mi := Integer(m[2])
        if (h < 24 && mi < 60) {
            mins := (h * 60) + mi
            return true
        }
    }
    return false
}
ActiveScheduleEntries() {
    global schedRows
    list := []
    for i, r in schedRows
        if (r.on && ParseHHMM(r.time, &mins))
            list.Push({idx: i, mins: mins, time: r.time, hw: r.hw, sw: r.sw})
    Loop list.Length {
        i := A_Index
        Loop i - 1 {
            j := i - A_Index
            if (list[j].mins > list[j + 1].mins)
                tmp := list[j], list[j] := list[j + 1], list[j + 1] := tmp
        }
    }
    return list
}
ScheduleStateAt(nowMins) {
    global schedFade
    list := ActiveScheduleEntries()
    if (list.Length == 0)
        return ""
    curPos := 0
    for k, e in list
        if (e.mins <= nowMins)
            curPos := k
    if (curPos == 0)
        curPos := list.Length
    cur := list[curPos], prev := list[(curPos == 1) ? list.Length : curPos - 1], nxt := list[(curPos == list.Length) ? 1 : curPos + 1]
    since := nowMins - cur.mins
    if (since < 0)
        since += 1440
    hw := cur.hw, sw := cur.sw
    if (schedFade > 0 && since < schedFade && list.Length > 1) {
        t := since / schedFade
        hw := Round(prev.hw + ((cur.hw - prev.hw) * t)), sw := Round(prev.sw + ((cur.sw - prev.sw) * t))
    }
    return {idx: cur.idx, time: cur.time, hw: hw, sw: sw, nextTime: nxt.time}
}
SetScheduleEnabled(on) {
    global schedEnabled, schedPausedIdx, schedLastApplied
    schedEnabled := on ? 1 : 0
    schedPausedIdx := 0, schedLastApplied := ""
    if (schedEnabled) {
        SetTimer(ScheduleTick, 20000)
        ScheduleTick()
    } else {
        SetTimer(ScheduleTick, 0)
    }
    SaveSettings(), PushState()
}
ScheduleTick() {
    global schedEnabled, schedPausedIdx, schedLastApplied, schedIncludeIndependent
    global currentHardwareBright, currentSoftwareDim, monitorSplitMode, monitorHW, monitorSW
    if (!schedEnabled)
        return
    st := ScheduleStateAt(NowMins())
    if (st == "" || (schedPausedIdx && schedPausedIdx == st.idx)) {
        PushState()
        return
    }
    schedPausedIdx := 0
    key := st.hw . "|" . st.sw
    if (key != schedLastApplied) {
        schedLastApplied := key
        currentHardwareBright := st.hw, currentSoftwareDim := st.sw
        if (schedIncludeIndependent) {
            Loop MonitorGetCount()
                if (monitorSplitMode.Has(A_Index) && monitorSplitMode[A_Index] == 1)
                    monitorHW[A_Index] := st.hw, monitorSW[A_Index] := st.sw
        }
        UpdateDisplayState()
        SetTimer(SaveSettings, -500)
        LogAction("[Schedule] " . st.time . " entry -> hardware " . st.hw . "%, software " . st.sw . "%")
    }
    PushState()
}
NoteManualAdjust() {
    global schedEnabled, schedPausedIdx, schedLastApplied
    if (!schedEnabled)
        return
    st := ScheduleStateAt(NowMins())
    schedPausedIdx := (st != "") ? st.idx : 0
    schedLastApplied := ""
}
ScheduleStatusLines() {
    global schedEnabled, schedPausedIdx, schedRows
    st := ScheduleStateAt(NowMins())
    bad := ""
    for i, r in schedRows
        if (r.on && !ParseHHMM(r.time, &tmp))
            bad .= (bad != "" ? ", " : "") . "row " . i
    if (!schedEnabled)
        l1 := "Off"
    else if (st == "")
        l1 := "No enabled entry has a valid time (use HH:mm)."
    else
        l1 := "Since " . st.time . ": backlight " . st.hw . "%, software " . st.sw . "%. Next change at " . st.nextTime . "."
    l2 := ""
    if (schedEnabled && st != "" && schedPausedIdx == st.idx)
        l2 := "Paused after a manual change until the " . st.nextTime . " entry."
    if (bad != "")
        l2 .= (l2 != "" ? "  " : "") . "Invalid time in " . bad . " (use HH:mm)."
    return [l1, l2]
}
HandleScheduleCommand(a, b, c, d, e) {
    global schedRows, schedFade, schedIncludeIndependent, schedLastApplied, schedPausedIdx, schedEnabled
    global currentHardwareBright, currentSoftwareDim
    switch a {
        case "enabled":
            SetScheduleEnabled(Integer(b))
            return
        case "row":
            i := Integer(b), r := schedRows[i]
            switch c {
                case "on": r.on := Integer(d) ? 1 : 0
                case "time": r.time := Trim(d)
                case "hw": r.hw := IsNumber(d) ? Clamp(d) : r.hw
                case "sw": r.sw := IsNumber(d) ? Clamp(d) : r.sw
            }
        case "useCurrent":
            i := Integer(b)
            schedRows[i].hw := currentHardwareBright, schedRows[i].sw := currentSoftwareDim
        case "fade":
            schedFade := Max(0, Min(120, Integer(b)))
        case "includeIndependent":
            schedIncludeIndependent := Integer(b) ? 1 : 0
        case "applyNow":
            schedPausedIdx := 0, schedLastApplied := ""
            if (!schedEnabled) {
                SetScheduleEnabled(1)
                return
            }
    }
    schedLastApplied := ""
    SaveSettings()
    if (schedEnabled)
        ScheduleTick()
    else
        PushState()
}

; =========================================================================
; 🌙 WARMTH SCHEDULE (f.lux style)
; =========================================================================
DefaultWarmPhases() => [{name: "Daytime", time: "07:00", level: 0}, {name: "Evening", time: "20:00", level: 60}, {name: "Bedtime", time: "23:00", level: 80}]
NowMinsF() => (Integer(A_Hour) * 60) + Integer(A_Min) + (Integer(A_Sec) / 60)
WarmPhaseByName(name) {
    global warmPhases
    for ph in warmPhases
        if (ph.name = name)
            return ph
    return ""
}
; The parts of the day with a valid time, sorted by time.
WarmPhaseList() {
    global warmPhases
    list := []
    for ph in warmPhases
        if ParseHHMM(ph.time, &mins)
            list.Push({name: ph.name, time: ph.time, level: ph.level, mins: mins})
    Loop list.Length {
        i := A_Index
        Loop i - 1 {
            j := i - A_Index
            if (list[j].mins > list[j + 1].mins)
                tmp := list[j], list[j] := list[j + 1], list[j + 1] := tmp
        }
    }
    return list
}
; Warmth at a time of day (minutes since midnight, fractions allowed). A part of the day starts at its time and
; moves from the previous part's warmth to its own over warmFadeMin minutes (never longer than the part itself,
; so every part is fully reached before the next one starts).
WarmStateAt(nowMins, list := "") {
    global warmFadeMin
    if (list == "")
        list := WarmPhaseList()
    if (list.Length == 0)
        return ""
    curPos := 0
    for k, e in list
        if (e.mins <= nowMins)
            curPos := k
    if (curPos == 0)
        curPos := list.Length
    cur := list[curPos], prev := list[(curPos == 1) ? list.Length : curPos - 1], nxt := list[(curPos == list.Length) ? 1 : curPos + 1]
    since := nowMins - cur.mins
    if (since < 0)
        since += 1440
    gap := nxt.mins - cur.mins
    if (gap <= 0)
        gap += 1440
    fade := Min(warmFadeMin, gap)
    lvl := cur.level, fading := false
    if (fade > 0 && since < fade && list.Length > 1)
        lvl := prev.level + (cur.level - prev.level) * (since / fade), fading := true
    doneMins := Mod(cur.mins + fade, 1440)
    return {level: Round(lvl), name: cur.name, time: cur.time, target: cur.level, fading: fading,
            doneAt: Format("{:02}:{:02}", doneMins // 60, Mod(doneMins, 60)), nextName: nxt.name, nextTime: nxt.time}
}
SetWarmScheduleEnabled(on) {
    global warmSchedEnabled, warmPausedPhase, warmLastKey
    warmSchedEnabled := on ? 1 : 0
    warmPausedPhase := "", warmLastKey := ""
    if (warmSchedEnabled) {
        SetTimer(WarmScheduleTick, 15000)
        WarmScheduleTick()
    } else {
        SetTimer(WarmScheduleTick, 0)
    }
    SaveSettings(), PushState()
}
WarmScheduleTick() {
    global warmSchedEnabled, warmPausedPhase, warmLastKey, warmth, warmPreviewFrom
    if (!warmSchedEnabled || warmPreviewFrom != "")
        return
    st := WarmStateAt(NowMinsF())
    if (st == "")
        return
    if (warmPausedPhase != "") {
        if (warmPausedPhase == st.name)
            return
        warmPausedPhase := ""                       ; the next part of the day has begun: follow the schedule again
        LogAction("[Warmth] schedule resumed at " . st.name)
    }
    key := st.name . "|" . st.level
    if (key == warmLastKey)
        return
    phaseChanged := (SubStr(warmLastKey, 1, StrLen(st.name) + 1) != st.name . "|")
    warmLastKey := key
    if (st.level != warmth) {
        warmth := st.level
        UpdateDisplayState(true)
        SetTimer(SaveSettings, -1000)
    }
    if (phaseChanged)
        LogAction("[Warmth] " . st.name . " (from " . st.time . ") -> warmth " . st.level . "% (" . WarmthToKelvin(st.level) . " K)")
    PushState()
}
NoteWarmManual() {
    global warmSchedEnabled, warmPausedPhase, warmLastKey
    if (!warmSchedEnabled)
        return
    st := WarmStateAt(NowMinsF())
    warmPausedPhase := (st != "") ? st.name : ""
    warmLastKey := ""
}
; While a part's warmth slider is moved on the Warmth page, the screens show that warmth (a preview); two seconds
; after the last move they go back to what the schedule (or the flyout slider) says.
WarmPreview(level) {
    global warmth, warmPreviewFrom
    if (warmPreviewFrom == "")
        warmPreviewFrom := warmth
    warmth := level
    SetTimer(WarmPreviewApply, -60)             ; one named timer, so a fast drag coalesces into few gamma writes
    SetTimer(EndWarmPreview, -2000)
}
WarmPreviewApply() => UpdateDisplayState(true)
EndWarmPreview() {
    global warmth, warmPreviewFrom, warmSchedEnabled, warmPausedPhase, warmLastKey
    if (warmPreviewFrom == "")
        return
    back := warmPreviewFrom, warmPreviewFrom := ""
    if (warmSchedEnabled && warmPausedPhase == "") {
        warmLastKey := ""
        WarmScheduleTick()
        return
    }
    warmth := back
    UpdateDisplayState(true), PushState()
}
HandleWarmSchedCommand(a, b, c) {
    global warmFadeMin, warmPausedPhase, warmLastKey, warmSchedEnabled
    switch a {
        case "enabled":
            SetWarmScheduleEnabled(Integer(b))
            return
        case "resume":
            warmPausedPhase := "", warmLastKey := ""
            if (!warmSchedEnabled) {
                SetWarmScheduleEnabled(1)
                return
            }
        case "time":                                   ; b = part of the day, c = HH:mm
            ph := WarmPhaseByName(b)
            if (ph == "")
                return
            if !ParseHHMM(c, &mins) {
                Toast("Use a time like 20:30.")
                PushState()
                return
            }
            ph.time := Format("{:02}:{:02}", mins // 60, Mod(mins, 60))
        case "level":                                  ; b = part of the day, c = 0..100
            ph := WarmPhaseByName(b)
            if (ph == "" || !IsNumber(c))
                return
            ph.level := Clamp(c)
            WarmPreview(ph.level)
            SetTimer(SaveSettings, -500)
            PushState()
            return
        case "fade":
            warmFadeMin := Max(0, Min(180, Integer(b)))
    }
    warmLastKey := ""
    SaveSettings()
    if (warmSchedEnabled)
        WarmScheduleTick()
    PushState()
}
; For the page: the parts of the day, a status line and the day's warmth curve from noon to noon (every 10 min).
WarmScheduleState() {
    global warmSchedEnabled, warmFadeMin, warmPhases, warmPausedPhase
    static curveKey := "", curve := []
    list := WarmPhaseList()
    key := warmFadeMin
    for e in list
        key .= "|" . e.mins . ":" . e.level
    if (key != curveKey) {
        ; built in a local array and swapped in when complete: a state push from another thread can interrupt
        ; this loop, and filling the shared array directly glued two curves together on the timeline
        c := []
        Loop 145 {
            st := WarmStateAt(Mod(720 + (A_Index - 1) * 10, 1440), list)
            c.Push(st == "" ? 0 : st.level)
        }
        curveKey := key, curve := c
    }
    phases := []
    for ph in warmPhases
        phases.Push({name: ph.name, time: ph.time, level: ph.level})
    st := WarmStateAt(NowMinsF(), list)
    if (st == "")
        status := "Give each part of the day a time like 20:30."
    else if (!warmSchedEnabled)
        status := "Off. The Warmth slider in the flyout sets the warmth by hand."
    else if (warmPausedPhase != "")
        status := "Paused after a manual change. Follows the schedule again when " . st.nextName . " starts at " . st.nextTime . "."
    else if (st.fading)
        status := st.name . ": moving to " . (st.target ? WarmthToKelvin(st.target) . " K" : "neutral") . " until " . st.doneAt . ". " . st.nextName . " starts at " . st.nextTime . "."
    else
        status := st.name . ": " . (st.level ? WarmthToKelvin(st.level) . " K" : "neutral colour") . ". " . st.nextName . " starts at " . st.nextTime . "."
    nowM := NowMinsF()
    return {enabled: warmSchedEnabled, fade: warmFadeMin, phases: phases, paused: (warmPausedPhase != "") ? 1 : 0,
            now: (st == "") ? "" : st.name, status: status, curve: curve, nowPos: Mod(nowM - 720 + 1440, 1440) / 1440}
}

; =========================================================================
; 🌦 WEATHER + TIME OF DAY: automatic theme and the Sky theme
; =========================================================================
DefaultAutoThemeMap() => Map("Morning", "Lavender Pink", "Day", "Aqua Blue", "Evening", "Amber Night", "Night", "Milky Way",
                             "Cloudy", "Graphite", "Rain", "Tokyo Night", "Snow", "Nord Frost", "Storm", "Cyber Neon", "Fog", "Sky")
Atan2(y, x) {
    static PI := 3.141592653589793
    if (x > 0)
        return ATan(y / x)
    if (x < 0)
        return (y >= 0) ? ATan(y / x) + PI : ATan(y / x) - PI
    return (y > 0) ? PI / 2 : (y < 0) ? -PI / 2 : 0
}
; Sun position (about 1 degree accurate): elevation above the horizon, hour angle (negative before solar noon)
; and the elevation at solar noon, for a place and a moment (Unix seconds, default now).
SunPosition(lat, lon, unixSecs := "") {
    static RAD := 3.141592653589793 / 180
    if (unixSecs == "")
        unixSecs := DateDiff(A_NowUTC, "19700101000000", "Seconds")
    n := unixSecs / 86400 + 2440587.5 - 2451545.0
    meanLong := Mod(280.460 + 0.9856474 * n, 360)
    anom := Mod(357.528 + 0.9856003 * n, 360) * RAD
    eclLong := (meanLong + 1.915 * Sin(anom) + 0.020 * Sin(2 * anom)) * RAD
    obl := (23.439 - 0.0000004 * n) * RAD
    ra := Atan2(Cos(obl) * Sin(eclLong), Cos(eclLong)) / RAD
    dec := ASin(Sin(obl) * Sin(eclLong))
    gmst := Mod(18.697374558 + 24.06570982441908 * n, 24)
    ha := Mod(gmst * 15 + lon - ra + 540, 360) - 180
    elev := ASin(Sin(lat * RAD) * Sin(dec) + Cos(lat * RAD) * Cos(dec) * Cos(ha * RAD)) / RAD
    return {elev: elev, ha: ha, noonElev: 90 - Abs(lat - dec / RAD)}
}
HasPlace() {
    global locLat, locLon
    return (locLat != "" && IsNumber(locLat) && IsNumber(locLon))
}
; Part of the day now. With a place: from the sun (night below -6 degrees, morning/evening while it is low,
; day once it is up; the "up" height adapts to latitude and season). Without one: from the clock.
TimeOfDayNow() {
    global locLat, locLon
    if HasPlace() {
        sp := SunPosition(Float(locLat), Float(locLon))
        dayAt := Max(2, Min(12, sp.noonElev * 0.5))
        slot := (sp.elev < -6) ? "Night" : (sp.elev < dayAt) ? ((sp.ha < 0) ? "Morning" : "Evening") : "Day"
        return {slot: slot, elev: sp.elev, located: 1, morning: sp.ha < 0, dayAt: dayAt}
    }
    hr := Integer(A_Hour) + Integer(A_Min) / 60
    slot := (hr >= 6 && hr < 9) ? "Morning" : (hr >= 9 && hr < 17) ? "Day" : (hr >= 17 && hr < 20.5) ? "Evening" : "Night"
    ; a stand-in sun for the Sky theme: up from 06:30 to 19:30
    elev := (hr >= 6.5 && hr <= 19.5) ? 50 * Sin(3.14159265 * (hr - 6.5) / 13) : -18 * Sin(3.14159265 * (((hr < 6.5) ? hr + 24 : hr) - 19.5) / 11)
    return {slot: slot, elev: elev, located: 0, hour: hr}
}
; Today's sunrise and sunset ("HH:mm", local time) for the chosen place, found by stepping through the day.
SunTimesToday() {
    global locLat, locLon
    static cacheKey := "", cached := ""
    if !HasPlace()
        return ""
    key := SubStr(A_Now, 1, 8) . "|" . locLat . "|" . locLon
    if (key == cacheKey)
        return cached
    offset := DateDiff(A_Now, A_NowUTC, "Seconds")
    start := DateDiff(SubStr(A_Now, 1, 8) . "000000", "19700101000000", "Seconds") - offset
    riseAt := "", setAt := "", prev := ""
    Loop 289 {
        m := (A_Index - 1) * 5
        e := SunPosition(Float(locLat), Float(locLon), start + m * 60).elev
        if (prev != "") {
            if (prev < -0.833 && e >= -0.833 && riseAt == "")
                riseAt := Format("{:02}:{:02}", (m - 5) // 60, Mod(m - 5, 60))
            if (prev >= -0.833 && e < -0.833 && setAt == "")
                setAt := Format("{:02}:{:02}", (m - 5) // 60, Mod(m - 5, 60))
        }
        prev := e
    }
    cacheKey := key, cached := {rise: riseAt, set: setAt}
    return cached
}
; WMO weather codes (Open-Meteo) -> the five kinds a theme can be picked for, and a short description.
WeatherKind(code) {
    if !IsNumber(code)
        return ""
    c := Integer(code)
    return (c <= 2) ? "Clear" : (c == 3) ? "Cloudy" : (c == 45 || c == 48) ? "Fog" : (c >= 95) ? "Storm"
         : ((c >= 71 && c <= 77) || c == 85 || c == 86) ? "Snow" : "Rain"
}
WeatherText(code) {
    static T := Map(0, "Clear sky", 1, "Mainly clear", 2, "Partly cloudy", 3, "Overcast", 45, "Fog", 48, "Freezing fog",
        51, "Light drizzle", 53, "Drizzle", 55, "Heavy drizzle", 56, "Freezing drizzle", 57, "Freezing drizzle",
        61, "Light rain", 63, "Rain", 65, "Heavy rain", 66, "Freezing rain", 67, "Freezing rain",
        71, "Light snow", 73, "Snow", 75, "Heavy snow", 77, "Snow grains", 80, "Rain showers", 81, "Rain showers",
        82, "Heavy showers", 85, "Snow showers", 86, "Snow showers", 95, "Thunderstorm", 96, "Thunderstorm with hail", 99, "Thunderstorm with hail")
    return (IsNumber(code) && T.Has(Integer(code))) ? T[Integer(code)] : ""
}
; The weather counts while it is less than 3 hours old.
CurrentWeatherKind() {
    global weatherNow
    return (weatherNow.kind != "" && A_TickCount - weatherNow.tick < 3 * 3600000) ? weatherNow.kind : ""
}
; ---- Sky theme: sky colours by sun height, tinted by the weather ----
SkyTheme(elev, kind) {
    ; sun height -> [background, accent, second accent] as [hue, saturation, lightness]
    static KF := [[-14, [228, .45, .065], [220, .90, .74], [265, .85, .74]],      ; night: moonlit blue into violet
                  [-6,  [252, .40, .080], [290, .72, .72], [215, .85, .68]],      ; blue hour
                  [0,   [335, .30, .085], [18, .95, .62],  [338, .85, .66]],      ; sunrise / sunset: orange into pink
                  [8,   [26, .32, .085],  [38, .95, .60],  [12, .90, .62]],       ; golden hour
                  [25,  [210, .42, .085], [199, .92, .60], [172, .70, .52]]]      ; day: sky blue into teal
    static WX := Map("Cloudy", [.55, [215, .12, .09], [210, .28, .72], [222, .22, .62]],
                     "Fog",    [.65, [210, .08, .10], [200, .14, .78], [212, .12, .64]],
                     "Rain",   [.60, [212, .30, .08], [205, .68, .66], [188, .58, .56]],
                     "Snow",   [.60, [210, .26, .10], [200, .75, .84], [222, .60, .78]],
                     "Storm",  [.70, [262, .35, .07], [268, .85, .72], [50, .95, .62]])
    mixHsl(x, y, k) => [HueMix(x[1], y[1], k), x[2] + (y[2] - x[2]) * k, x[3] + (y[3] - x[3]) * k]
    e := Max(KF[1][1], Min(KF[KF.Length][1], elev))
    i := 1
    while (i < KF.Length - 1 && e > KF[i + 1][1])
        i += 1
    a := KF[i], b := KF[i + 1], f := (e - a[1]) / (b[1] - a[1])
    bg := mixHsl(a[2], b[2], f), ac := mixHsl(a[3], b[3], f), ac2 := mixHsl(a[4], b[4], f)
    if WX.Has(kind) {
        w := WX[kind], k := w[1] * ((elev < -6) ? 0.6 : 1.0)
        bg := mixHsl(bg, w[2], k), ac := mixHsl(ac, w[3], k), ac2 := mixHsl(ac2, w[4], k)
    }
    surf(dl, smul := 1.0) => HslToHex(bg[1], Max(0, Min(1, bg[2] * smul)), Max(0, Min(1, bg[3] + dl)))
    t := MakeTheme(surf(0), HslToHex(bg[1], Min(.30, bg[2]), .95), HslToHex(bg[1], Min(.30, bg[2] * .7 + .08), .70),
                   HslToHex(ac[1], ac[2], ac[3]), surf(.13, .8), surf(.06, .9), surf(.035), surf(.28, .7), HslToHex(ac2[1], ac2[2], ac2[3]))
    t.sliderThumb := HslToHex(ac[1], ac[2], Min(.85, ac[3] + .10))
    return t
}
UpdateSkyPalette() {
    global THEMES
    THEMES["Sky"] := SkyTheme(TimeOfDayNow().elev, CurrentWeatherKind())
}
; Theme the automatic mode would show now, and why.
AutoThemeResolve(tod := "") {
    global autoThemeMap, autoWeatherScope
    if (tod == "")
        tod := TimeOfDayNow()
    name := autoThemeMap[tod.slot], why := tod.slot
    k := CurrentWeatherKind()
    if (k != "" && k != "Clear" && autoThemeMap.Has(k) && autoThemeMap[k] != "" && (autoWeatherScope == "always" || tod.slot != "Night"))
        name := autoThemeMap[k], why := tod.slot . ", " . StrLower(k)
    return {name: name, why: why}
}
; ---- blending: every part of the day and kind of weather mixes into its own palette ----
HexRgb(hex) => [Integer("0x" . SubStr(hex, 1, 2)), Integer("0x" . SubStr(hex, 3, 2)), Integer("0x" . SubStr(hex, 5, 2))]
HueGap(a, b) => Abs(Mod(b - a + 540, 360) - 180)
; Mix two colours. Close hues travel round the colour wheel (so the mix stays vivid); for far-apart or greyish
; colours the hue comes from the plain RGB mix, with saturation and lightness taken from the two colours.
MixHex(a, b, k) {
    if (k <= 0.001 || a = b)
        return a
    if (k >= 0.999)
        return b
    c1 := HexRgb(a), c2 := HexRgb(b)
    h1 := RgbToHsl(c1[1], c1[2], c1[3]), h2 := RgbToHsl(c2[1], c2[2], c2[3])
    if (h1[2] > 0.25 && h2[2] > 0.25 && HueGap(h1[1], h2[1]) <= 75)
        hue := HueMix(h1[1], h2[1], k)
    else {
        hm := RgbToHsl(c1[1] + (c2[1] - c1[1]) * k, c1[2] + (c2[2] - c1[2]) * k, c1[3] + (c2[3] - c1[3]) * k)
        hue := (hm[2] > 0.06) ? hm[1] : ((k < 0.5) ? h1[1] : h2[1])
    }
    return HslToHex(hue, h1[2] + (h2[2] - h1[2]) * k, h1[3] + (h2[3] - h1[3]) * k)
}
; Blend two themes. Surfaces, lines and text mix by k. Accents mix too when their hues are close; when they are far
; apart (amber and blue, say) a half-way colour would be mud, so the leading theme keeps its accent and the other
; theme's accent becomes the second accent: gradients and glows then run between the two themes' colours.
BlendTheme(t1, t2, k) {
    global COLOR_SLOTS
    if (k <= 0.001)
        return CloneTheme(t1)
    c := {}
    for slot in COLOR_SLOTS
        c.%slot[1]% := MixHex(t1.%slot[1]%, t2.%slot[1]%, k)
    a1 := HexRgb(t1.accent), a2 := HexRgb(t2.accent)
    if (HueGap(RgbToHsl(a1*)[1], RgbToHsl(a2*)[1]) > 75 && k >= 0.15) {
        lead := (k < 0.5) ? t1 : t2, other := (k < 0.5) ? t2 : t1
        for slot in ["accent", "checkOn", "sliderFill", "sliderThumb"]
            c.%slot% := lead.%slot%
        c.accent2 := other.accent
    }
    return c
}
ThemeByName(name) {
    global THEMES
    if (name == "Wallpaper")
        return WallpaperThemeForMonitor(MonitorGetPrimary())
    return THEMES.Has(name) ? THEMES[name] : THEMES["Lava Orange"]
}
; How much each part of the day counts right now (one or two parts, summing to 1): the themes cross-fade while
; the sun passes dawn and dusk (with a place) or around the clock times (without one).
TimeWeights(tod) {
    ramp(x, lo, hi) => Max(0, Min(1, (x - lo) / (hi - lo)))
    q(x) => Round(x * 20) / 20                               ; 5 % steps: the palette changes in visible steps, not every minute
    if (tod.located) {
        e := tod.elev, lo := Max(-2, tod.dayAt - 3), hi := Max(lo + 2, tod.dayAt + 3)
        edge := tod.morning ? "Morning" : "Evening"
        if (e <= -8)
            return Map("Night", 1)
        if (e < -2)
            return q(ramp(e, -8, -2)) >= 1 ? Map(edge, 1) : Map("Night", 1 - q(ramp(e, -8, -2)), edge, q(ramp(e, -8, -2)))
        if (e <= lo)
            return Map(edge, 1)
        if (e < hi)
            return Map(edge, 1 - q(ramp(e, lo, hi)), "Day", q(ramp(e, lo, hi)))
        return Map("Day", 1)
    }
    ; by the clock: half-hour cross-fades around 06:00, 09:00, 17:00 and 20:30
    hr := tod.hour
    for b in [[6, "Night", "Morning"], [9, "Morning", "Day"], [17, "Day", "Evening"], [20.5, "Evening", "Night"]] {
        if (hr >= b[1] - 0.5 && hr < b[1] + 0.5) {
            k := q(ramp(hr, b[1] - 0.5, b[1] + 0.5))
            return (k <= 0) ? Map(b[2], 1) : (k >= 1) ? Map(b[3], 1) : Map(b[2], 1 - k, b[3], k)
        }
    }
    return Map(tod.slot, 1)
}
; The automatic palette for given part-of-day weights and weather kind.
AutoBlendFor(weights, kind, isNight := false) {
    global autoThemeMap, autoWeatherScope, autoWeatherStrength
    names := [], ws := []
    for slotName, w in weights
        if (w > 0)
            names.Push(slotName), ws.Push(w)
    base := ThemeByName(autoThemeMap[names[1]])
    if (names.Length > 1)
        base := BlendTheme(base, ThemeByName(autoThemeMap[names[2]]), ws[2] / (ws[1] + ws[2]))
    wk := 0
    if (kind != "" && kind != "Clear" && autoThemeMap.Has(kind) && autoThemeMap[kind] != "" && (autoWeatherScope == "always" || !isNight))
        wk := autoWeatherStrength / 100
    return {theme: (wk > 0) ? BlendTheme(base, ThemeByName(autoThemeMap[kind]), wk) : CloneTheme(base), weather: wk}
}
AutoBlendNow(tod := "") {
    global autoThemeMap, autoWeatherStrength
    if (tod == "")
        tod := TimeOfDayNow()
    weights := TimeWeights(tod)
    night := weights.Has("Night") && weights["Night"] >= 0.5
    kind := CurrentWeatherKind()
    r := AutoBlendFor(weights, kind, night)
    parts := []
    for slotName, w in weights
        parts.Push(autoThemeMap[slotName] . (weights.Count > 1 ? " " . Round(w * 100) . "%" : ""))
    label := Join(parts, " + ")
    if (r.weather > 0)
        label .= ", with " . Round(r.weather * 100) . "% " . autoThemeMap[kind] . " for the " . StrLower(kind == "Rain" ? "rain" : kind == "Cloudy" ? "clouds" : kind)
    r.label := label, r.weights := weights, r.kind := kind
    return r
}
UpdateAutoPalette() {
    global THEMES
    THEMES["Automatic"] := AutoBlendNow().theme
}
; Like SelectTheme, but leaves the automatic mode on.
ApplyThemeName(name) {
    global themeName, THEMES
    themeName := THEMES.Has(name) ? name : "Lava Orange"
    if (themeName == "Sky")
        UpdateSkyPalette()
    SyncWallpaperWatch(), SyncEnvWatch()
    SaveSettings(), ApplyThemeToHosts(), PushState()
}
SyncEnvWatch() {
    global autoThemeEnabled, themeName
    SetTimer(EnvTick, (autoThemeEnabled || themeName == "Sky") ? 60000 : 0)
}
; Every minute while the automatic theme or Sky is in use: weather when due, the Sky palette, the automatic choice.
EnvTick() {
    global autoThemeEnabled, themeName, THEMES, envLastSig, weatherFetchTick, autoLastSig, autoLastLabel, COLOR_SLOTS
    if (!autoThemeEnabled && themeName != "Sky") {
        SetTimer(EnvTick, 0)
        return
    }
    if (HasPlace() && (!weatherFetchTick || A_TickCount - weatherFetchTick > 20 * 60000))
        FetchWeather()
    tod := TimeOfDayNow()
    sky := SkyTheme(tod.elev, CurrentWeatherKind())
    sig := sky.bg . sky.accent . sky.accent2 . sky.input
    skyChanged := (sig != envLastSig), envLastSig := sig
    THEMES["Sky"] := sky
    if (autoThemeEnabled) {
        r := AutoBlendNow(tod)
        THEMES["Automatic"] := r.theme
        sig := ""
        for slot in COLOR_SLOTS
            sig .= r.theme.%slot[1]%
        switched := (themeName != "Automatic")
        if (switched) {
            themeName := "Automatic"
            SyncWallpaperWatch(), SaveSettings()
        }
        if (switched || sig != autoLastSig) {
            autoLastSig := sig
            ApplyThemeToHosts(), PushState()
        }
        if (r.label != autoLastLabel)
            autoLastLabel := r.label, LogAction("[Auto theme] " . r.label)
        return
    }
    if (skyChanged && themeName == "Sky")
        ApplyThemeToHosts(), PushState()
}
; ---- network: small asynchronous GET (WinHTTP), so the app never waits on the internet ----
HttpGetAsync(url, cb) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("GET", url, true)
        req.SetRequestHeader("User-Agent", "SmartDimmer/1.1 (+https://github.com/Xyberg-001/SmartDimmer)")
        req.Send()
    } catch as e {
        cb(0, e.Message)
        return
    }
    started := A_TickCount
    poll() {
        try {
            done := req.WaitForResponse(0)
        } catch as e {
            SetTimer(poll, 0)
            cb(0, "no connection (" . Trim(StrReplace(e.Message, "`n", " ")) . ")")
            return
        }
        if (done) {
            SetTimer(poll, 0)
            try cb(req.Status, req.ResponseText)
            catch as e
                cb(0, e.Message)
        } else if (A_TickCount - started > 15000) {
            SetTimer(poll, 0)
            try req.Abort()
            cb(0, "timed out")
        }
    }
    SetTimer(poll, 150)
}
UriEncode(str) {
    buf := Buffer(StrPut(str, "UTF-8")), StrPut(str, buf, "UTF-8"), out := ""
    Loop buf.Size - 1 {
        c := NumGet(buf, A_Index - 1, "UChar")
        out .= ((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x2E || c == 0x5F || c == 0x7E) ? Chr(c) : Format("%{:02X}", c)
    }
    return out
}
JsonNum(obj, key) => RegExMatch(obj, '"' . key . '"\s*:\s*(-?[0-9.eE+-]+)', &m) ? m[1] : ""
JsonText(obj, key) => RegExMatch(obj, '"' . key . '"\s*:\s*"((?:[^"\\]|\\.)*)"', &m) ? JsonUnescape(m[1]) : ""
JsonUnescape(s) {
    out := "", i := 1
    while (pos := RegExMatch(s, "\\(u[0-9a-fA-F]{4}|.)", &m, i)) {
        out .= SubStr(s, i, pos - i)
        c := m[1]
        out .= (StrLen(c) == 5) ? Chr(Integer("0x" . SubStr(c, 2))) : (c == "n") ? "`n" : (c == "t") ? "`t" : (c == "r" || c == "b" || c == "f") ? "" : c
        i := pos + StrLen(m[0])
    }
    return out . SubStr(s, i)
}
FetchWeather() {
    global locLat, locLon, weatherFetchTick
    if !HasPlace()
        return
    weatherFetchTick := A_TickCount
    HttpGetAsync("https://api.open-meteo.com/v1/forecast?latitude=" . locLat . "&longitude=" . locLon
        . "&current=weather_code,temperature_2m,is_day&timezone=auto", OnWeatherReply)
}
OnWeatherReply(status, body) {
    global weatherNow
    if (status != 200 || !RegExMatch(body, '"current"\s*:\s*(\{[^{}]*\})', &m)) {
        weatherNow.error := status ? "the weather service answered " . status : body
        LogAction("[Weather] update failed: " . weatherNow.error)
        PushState()
        return
    }
    code := JsonNum(m[1], "weather_code")
    weatherNow.code := code, weatherNow.kind := WeatherKind(code), weatherNow.text := WeatherText(code)
    weatherNow.temp := JsonNum(m[1], "temperature_2m"), weatherNow.at := FormatTime(, "HH:mm"), weatherNow.tick := A_TickCount, weatherNow.error := ""
    LogAction("[Weather] " . weatherNow.text . " (code " . code . ", " . weatherNow.kind . "), " . weatherNow.temp . " C")
    EnvTick()
    PushState()
}
LocationSearch(q) {
    global locSearching, locResults
    q := Trim(q)
    if (q == "")
        return
    locSearching := 1, locResults := []
    PushState()
    HttpGetAsync("https://geocoding-api.open-meteo.com/v1/search?count=6&language=en&format=json&name=" . UriEncode(q), OnLocationReply.Bind(q))
}
OnLocationReply(q, status, body) {
    global locSearching, locResults
    locSearching := 0, locResults := []
    if (status != 200) {
        Toast("Could not search for places: " . (status ? "the service answered " . status : body) . ".")
        PushState()
        return
    }
    pos := 1
    while (pos := RegExMatch(body, '\{[^{}]*"latitude"[^{}]*\}', &m, pos)) {
        o := m[0], pos += StrLen(o)
        name := JsonText(o, "name"), lat := JsonNum(o, "latitude"), lon := JsonNum(o, "longitude")
        if (name == "" || lat == "" || lon == "")
            continue
        parts := [name], a1 := JsonText(o, "admin1"), ctry := JsonText(o, "country")
        if (a1 != "" && a1 != name)
            parts.Push(a1)
        if (ctry != "")
            parts.Push(ctry)
        locResults.Push({label: Join(parts, ", "), lat: lat, lon: lon})
    }
    if (locResults.Length == 0)
        Toast("No place found for " . q . ".")
    PushState()
}
HandleEnvCommand(a, b, c) {
    global autoThemeEnabled, autoWeatherScope, autoThemeMap, AUTO_SLOTS, THEMES, locName, locLat, locLon, locResults, weatherNow, weatherFetchTick
    global autoWeatherStrength, manualTheme, themeName, autoLastSig
    switch a {
        case "auto":
            on := Integer(b) ? 1 : 0
            if (on && !autoThemeEnabled && themeName != "Automatic")
                manualTheme := themeName                       ; remembered for when it is turned off again
            autoThemeEnabled := on, autoLastSig := ""
            LogAction("[Auto theme] " . (on ? "on" : "off"))
            if (on) {
                SyncEnvWatch(), SaveSettings()
                EnvTick()
            } else {
                SelectTheme(manualTheme)                        ; back to the theme picked before
                return
            }
        case "slot":                                     ; b = slot, c = theme ("" = no change, weather slots only)
            if (!autoThemeMap.Has(b) || (c != "" && !THEMES.Has(c)) || (c == "" && (b == "Morning" || b == "Day" || b == "Evening" || b == "Night")))
                return
            autoThemeMap[b] := c
            SaveSettings()
            if (autoThemeEnabled)
                EnvTick()
        case "scope":
            autoWeatherScope := (b == "always") ? "always" : "day"
            SaveSettings()
            if (autoThemeEnabled)
                EnvTick()
        case "strength":
            autoWeatherStrength := Max(10, Min(100, Integer(b)))
            SetTimer(SaveSettings, -500)
            if (autoThemeEnabled)
                EnvTick()
        case "search":
            LocationSearch(b)
            return
        case "pick":
            i := Integer(b)
            if (i < 1 || i > locResults.Length)
                return
            r := locResults[i]
            locName := r.label, locLat := r.lat, locLon := r.lon, locResults := []
            weatherNow := {kind: "", code: "", text: "", temp: "", at: "", tick: 0, error: ""}, weatherFetchTick := 0
            LogAction("[Weather] place set to " . locName . " (" . locLat . ", " . locLon . ")")
            SaveSettings()
            UpdateSkyPalette()
            FetchWeather()
            EnvTick()
        case "clearPlace":
            locName := "", locLat := "", locLon := "", locResults := []
            weatherNow := {kind: "", code: "", text: "", temp: "", at: "", tick: 0, error: ""}, weatherFetchTick := 0
            SaveSettings()
            EnvTick()
        case "refresh":
            FetchWeather()
    }
    PushState()
}
; For the page: settings, the place, the weather and a plain-language status line.
EnvState() {
    global autoThemeEnabled, autoWeatherScope, autoThemeMap, AUTO_SLOTS, locName, locLat, locLon, locResults, locSearching, weatherNow, autoWeatherStrength
    tod := TimeOfDayNow()
    sun := SunTimesToday()
    k := CurrentWeatherKind()
    if !HasPlace()
        status := "Now: " . tod.slot . " (by the clock: morning 06:00, day 09:00, evening 17:00, night 20:30). Choose a place for real sunrise and sunset, and the weather."
    else {
        status := "Now: " . tod.slot
        if (k != "")
            status .= ", " . StrLower(weatherNow.text) . (weatherNow.temp != "" ? ", " . Round(Float(weatherNow.temp)) . " °C" : "")
        status .= "."
        if IsObject(sun)
            status .= (sun.rise != "" ? " Sunrise " . sun.rise . "," : "") . (sun.set != "" ? " sunset " . sun.set . "." : "")
    }
    blend := AutoBlendNow(tod), pct := Map()
    for slotName, w in blend.weights
        pct[slotName] := Round(w * 100)
    if (blend.weather > 0)
        pct[blend.kind] := Round(blend.weather * 100)
    wline := ""
    if HasPlace()
        wline := (weatherNow.error != "") ? "Weather could not be updated: " . weatherNow.error . "." : (weatherNow.at != "" ? "Weather updated at " . weatherNow.at . "." : "Getting the weather...")
    return {auto: autoThemeEnabled, scope: autoWeatherScope, slots: AUTO_SLOTS, map: autoThemeMap, tod: tod.slot, weather: k,
            place: locName, located: HasPlace() ? 1 : 0, results: locResults, searching: locSearching,
            status: status, wline: wline, showing: blend.label, weights: pct, strength: autoWeatherStrength,
            weatherUsed: blend.weather > 0 ? 1 : 0}
}

; =========================================================================
; 💾 DEFAULTS + PERSISTENCE (same INI layout as v5)
; =========================================================================
FactoryState() {
    global COLOR_SLOTS, THEMES, THEME_DEFAULTS
    s := Map()
    s["HardwareStep"] := 2, s["CurveType"] := "linear", s["ExponentialFactor"] := 2.5
    s["MaxSoftwareDarkness"] := 180, s["LinkHardwareSoftware"] := 1, s["LinkAllDisplays"] := 0
    s["TargetMonitorIDs"] := "2", s["InvertCurve"] := 0, s["Theme"] := "Lava Orange", s["Glass"] := 0, s["GlassOpacity"] := 65
    s["HotkeyUp"] := "^Up", s["HotkeyDown"] := "^Down", s["HotkeySWUp"] := "#Up", s["HotkeySWDown"] := "#Down"
    s["HotkeyFlip"] := "", s["PrimaryGuard"] := 0, s["WpIntensity"] := 70, s["WpFrost"] := 0, s["Lively"] := 1
    s["Warmth"] := 0, s["Smooth"] := 1, s["Osd"] := 1, s["FreeMemory"] := 1
    s["WS_Enabled"] := 0, s["WS_Fade"] := 60
    s["Env_Auto"] := 0, s["Env_Scope"] := "always", s["Env_Strength"] := 45, s["Env_Place"] := "", s["Env_Lat"] := "", s["Env_Lon"] := ""
    for slotName, th in DefaultAutoThemeMap()
        s["Env_" slotName] := th
    for ph in DefaultWarmPhases()
        s["WS_" ph.name "_From"] := ph.time, s["WS_" ph.name "_Level"] := ph.level
    s["HardwareBright"] := 50, s["SoftwareDim"] := 50
    Loop 8 {
        n := A_Index
        s["Split_M" n] := 0, s["HW_M" n] := 50, s["SW_M" n] := 50, s["Dim_M" n] := 1, s["Warm_M" n] := 1
        for kind in ["HWUp", "HWDown", "SWUp", "SWDown"]
            s["HK_" n "_" kind] := ""
    }
    for slot in COLOR_SLOTS
        s["Custom_" slot[1]] := THEME_DEFAULTS["Lava Orange"].%slot[1]%
    for name in EditableThemes()                                    ; preset edits are part of the defaults too
        if (name != "Custom")
            for slot in COLOR_SLOTS
                s["Theme_" StrReplace(name, " ", "") "_" slot[1]] := THEME_DEFAULTS[name].%slot[1]%
    s["Sched_Enabled"] := 0, s["Sched_Fade"] := 0, s["Sched_IncludeIndependent"] := 1
    for i, r in DefaultScheduleRows()
        s["Sched_Row" i] := r.on "|" r.time "|" r.hw "|" r.sw
    return s
}
CollectState() {
    global hardwareStep, dimmingCurve, exponentialFactor, maxSoftwareDarkness, linkHardwareSoftware, linkAllDisplays, externalMonitorNum
    global invertCurve, hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, currentHardwareBright, currentSoftwareDim
    global monitorSplitMode, monitorHW, monitorSW, dimStates, themeName, COLOR_SLOTS, THEMES, glassEnabled, glassOpacity
    global schedEnabled, schedFade, schedIncludeIndependent, SCHED_ROWS, hotkeyFlipString, primaryGuardEnabled, wpIntensity, wpFrost, livelyEffects, warmth, smoothTransitions, osdEnabled, warmStates, warmSchedEnabled, warmFadeMin, warmPhases, autoThemeEnabled, autoWeatherScope, autoThemeMap, locName, locLat, locLon, autoWeatherStrength, manualTheme, memorySaver
    s := Map()
    s["HardwareStep"] := hardwareStep, s["CurveType"] := dimmingCurve, s["ExponentialFactor"] := exponentialFactor
    s["MaxSoftwareDarkness"] := maxSoftwareDarkness, s["LinkHardwareSoftware"] := linkHardwareSoftware
    s["LinkAllDisplays"] := linkAllDisplays, s["TargetMonitorIDs"] := externalMonitorNum, s["InvertCurve"] := invertCurve, s["Theme"] := themeName
    s["Glass"] := glassEnabled, s["GlassOpacity"] := glassOpacity
    s["HotkeyFlip"] := hotkeyFlipString, s["PrimaryGuard"] := primaryGuardEnabled, s["WpIntensity"] := wpIntensity, s["WpFrost"] := wpFrost, s["Lively"] := livelyEffects
    s["Warmth"] := warmth, s["Smooth"] := smoothTransitions, s["Osd"] := osdEnabled, s["FreeMemory"] := memorySaver
    s["WS_Enabled"] := warmSchedEnabled, s["WS_Fade"] := warmFadeMin
    s["Env_Auto"] := autoThemeEnabled, s["Env_Scope"] := autoWeatherScope, s["Env_Strength"] := autoWeatherStrength, s["Env_Place"] := locName, s["Env_Lat"] := locLat, s["Env_Lon"] := locLon
    for slotName, th in autoThemeMap
        s["Env_" slotName] := th
    for ph in warmPhases
        s["WS_" ph.name "_From"] := ph.time, s["WS_" ph.name "_Level"] := ph.level
    s["HotkeyUp"] := hotkeyUpString, s["HotkeyDown"] := hotkeyDoString, s["HotkeySWUp"] := hotkeySWUpString, s["HotkeySWDown"] := hotkeySWDoString
    s["HardwareBright"] := currentHardwareBright, s["SoftwareDim"] := currentSoftwareDim
    Loop 8 {
        n := A_Index
        s["Split_M" n] := monitorSplitMode.Has(n) ? monitorSplitMode[n] : 0
        s["HW_M" n] := monitorHW.Has(n) ? monitorHW[n] : currentHardwareBright
        s["SW_M" n] := monitorSW.Has(n) ? monitorSW[n] : currentSoftwareDim
        s["Dim_M" n] := dimStates.Has(n) ? dimStates[n] : 1
        s["Warm_M" n] := IsWarmTarget(n)
        for kind in ["HWUp", "HWDown", "SWUp", "SWDown"]
            s["HK_" n "_" kind] := GetMonitorHotkey(n, kind)
    }
    for slot in COLOR_SLOTS
        s["Custom_" slot[1]] := THEMES["Custom"].%slot[1]%
    for name in EditableThemes()
        if (name != "Custom")
            for slot in COLOR_SLOTS
                s["Theme_" StrReplace(name, " ", "") "_" slot[1]] := THEMES[name].%slot[1]%
    s["Sched_Enabled"] := schedEnabled, s["Sched_Fade"] := schedFade, s["Sched_IncludeIndependent"] := schedIncludeIndependent
    Loop SCHED_ROWS
        s["Sched_Row" A_Index] := ScheduleRowToString(A_Index)
    return s
}
WriteStateToIni(section, s) {
    global iniFile
    for k, v in s
        IniWrite(v, iniFile, section, k)
    IniWrite(1, iniFile, section, "Saved")
}
ReadStateFromIni(section) {
    global iniFile
    static MISSING := Chr(1) . "missing"
    s := FactoryState()
    for k, v in s.Clone() {
        val := IniRead(iniFile, section, k, MISSING)
        if (val != MISSING)
            s[k] := val
    }
    return s
}
SetGlobalsFromState(s) {
    global hardwareStep, dimmingCurve, exponentialFactor, maxSoftwareDarkness, linkHardwareSoftware, linkAllDisplays, externalMonitorNum
    global invertCurve, hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, currentHardwareBright, currentSoftwareDim
    global monitorSplitMode, monitorHW, monitorSW, dimStates, COLOR_SLOTS, THEMES, monitorHotkeys, themeName, glassEnabled, glassOpacity, AUTO_SLOTS
    global schedEnabled, schedFade, schedIncludeIndependent, SCHED_ROWS, hotkeyFlipString, primaryGuardEnabled, wpIntensity, wpFrost, livelyEffects, warmth, smoothTransitions, osdEnabled, warmStates, warmSchedEnabled, warmFadeMin, warmPhases, autoThemeEnabled, autoWeatherScope, autoThemeMap, locName, locLat, locLon, autoWeatherStrength, manualTheme, memorySaver
    if (s.Has("HotkeyFlip"))
        hotkeyFlipString := s["HotkeyFlip"]
    if (s.Has("WpIntensity") && IsNumber(s["WpIntensity"]))
        wpIntensity := Max(25, Min(100, Integer(s["WpIntensity"])))
    if (s.Has("WpFrost") && IsNumber(s["WpFrost"]))
        wpFrost := Integer(s["WpFrost"]) ? 1 : 0
    if (s.Has("Lively") && IsNumber(s["Lively"]))
        livelyEffects := Integer(s["Lively"]) ? 1 : 0
    if (s.Has("Warmth") && IsNumber(s["Warmth"]))
        warmth := Clamp(s["Warmth"])
    if (s.Has("Smooth") && IsNumber(s["Smooth"]))
        smoothTransitions := Integer(s["Smooth"]) ? 1 : 0
    if (s.Has("Osd") && IsNumber(s["Osd"]))
        osdEnabled := Integer(s["Osd"]) ? 1 : 0
    if (s.Has("FreeMemory") && IsNumber(s["FreeMemory"]))
        memorySaver := Integer(s["FreeMemory"]) ? 1 : 0
    if (s.Has("Env_Auto") && IsNumber(s["Env_Auto"]))
        autoThemeEnabled := Integer(s["Env_Auto"]) ? 1 : 0
    if s.Has("Env_Scope")
        autoWeatherScope := (s["Env_Scope"] == "always") ? "always" : "day"
    if (s.Has("Env_Strength") && IsNumber(s["Env_Strength"]))
        autoWeatherStrength := Max(10, Min(100, Integer(s["Env_Strength"])))
    for slotName in AUTO_SLOTS
        if (s.Has("Env_" slotName) && (s["Env_" slotName] == "" ? !(slotName == "Morning" || slotName == "Day" || slotName == "Evening" || slotName == "Night") : THEMES.Has(s["Env_" slotName])))
            autoThemeMap[slotName] := s["Env_" slotName]
    if (s.Has("Env_Lat") && s.Has("Env_Lon") && s.Has("Env_Place"))
        locName := s["Env_Place"], locLat := s["Env_Lat"], locLon := s["Env_Lon"]
    if (s.Has("WS_Enabled") && IsNumber(s["WS_Enabled"]))
        warmSchedEnabled := Integer(s["WS_Enabled"]) ? 1 : 0
    if (s.Has("WS_Fade") && IsNumber(s["WS_Fade"]))
        warmFadeMin := Max(0, Min(180, Integer(s["WS_Fade"])))
    for ph in warmPhases {
        if (s.Has("WS_" ph.name "_From") && ParseHHMM(s["WS_" ph.name "_From"], &tmpMins))
            ph.time := Format("{:02}:{:02}", tmpMins // 60, Mod(tmpMins, 60))
        if (s.Has("WS_" ph.name "_Level") && IsNumber(s["WS_" ph.name "_Level"]))
            ph.level := Clamp(s["WS_" ph.name "_Level"])
    }
    if (s.Has("PrimaryGuard") && IsNumber(s["PrimaryGuard"]))
        SetPrimaryGuard(Integer(s["PrimaryGuard"]))
    if (s.Has("Glass") && IsNumber(s["Glass"]))
        glassEnabled := Integer(s["Glass"]) ? 1 : 0
    if (s.Has("GlassOpacity") && IsNumber(s["GlassOpacity"]))
        glassOpacity := Max(20, Min(95, Integer(s["GlassOpacity"])))
    hardwareStep := Integer(s["HardwareStep"]), dimmingCurve := s["CurveType"]
    exponentialFactor := Float(s["ExponentialFactor"]), maxSoftwareDarkness := Integer(s["MaxSoftwareDarkness"])
    linkHardwareSoftware := Integer(s["LinkHardwareSoftware"]), linkAllDisplays := Integer(s["LinkAllDisplays"])
    externalMonitorNum := s["TargetMonitorIDs"], invertCurve := Integer(s["InvertCurve"])
    for slot in COLOR_SLOTS
        if (s.Has("Custom_" slot[1]) && RegExMatch(s["Custom_" slot[1]], "^[0-9A-Fa-f]{6}$"))
            THEMES["Custom"].%slot[1]% := StrUpper(s["Custom_" slot[1]])
    for name in EditableThemes() {
        if (name == "Custom")
            continue
        for slot in COLOR_SLOTS {
            k := "Theme_" StrReplace(name, " ", "") "_" slot[1]
            if (s.Has(k) && RegExMatch(s[k], "^[0-9A-Fa-f]{6}$"))
                THEMES[name].%slot[1]% := StrUpper(s[k])
        }
        SaveThemeColours(name)
    }
    SaveCustomTheme()
    themeName := THEMES.Has(s["Theme"]) ? s["Theme"] : "Lava Orange"
    monitorHotkeys := Map()
    Loop 8 {
        n := A_Index
        for kind in ["HWUp", "HWDown", "SWUp", "SWDown"]
            if (s.Has("HK_" n "_" kind) && s["HK_" n "_" kind] != "")
                monitorHotkeys[n ":" kind] := s["HK_" n "_" kind]
    }
    hotkeyUpString := s["HotkeyUp"], hotkeyDoString := s["HotkeyDown"], hotkeySWUpString := s["HotkeySWUp"], hotkeySWDoString := s["HotkeySWDown"]
    currentHardwareBright := Integer(s["HardwareBright"]), currentSoftwareDim := Integer(s["SoftwareDim"])
    monitorSplitMode := Map(), monitorHW := Map(), monitorSW := Map(), dimStates := Map(), warmStates := Map()
    Loop 8 {
        n := A_Index
        monitorSplitMode[n] := Integer(s["Split_M" n]), monitorHW[n] := Integer(s["HW_M" n]), monitorSW[n] := Integer(s["SW_M" n]), dimStates[n] := Integer(s["Dim_M" n])
        warmStates[n] := (s.Has("Warm_M" n) && IsNumber(s["Warm_M" n])) ? (Integer(s["Warm_M" n]) ? 1 : 0) : 1
    }
    if (s.Has("Sched_Enabled")) {
        schedEnabled := Integer(s["Sched_Enabled"]), schedFade := Max(0, Min(120, Integer(s["Sched_Fade"]))), schedIncludeIndependent := Integer(s["Sched_IncludeIndependent"])
        Loop SCHED_ROWS
            if (s.Has("Sched_Row" A_Index))
                SetScheduleRowFromString(A_Index, s["Sched_Row" A_Index])
    }
}
ApplyStateAndRefresh(s) {
    global schedEnabled
    SetGlobalsFromState(s)
    UpdateActiveHotkeys()
    SetScheduleEnabled(schedEnabled)
    SetWarmScheduleEnabled(warmSchedEnabled)
    UpdateSkyPalette()
    if (themeName == "Automatic" && !autoThemeEnabled)
        themeName := manualTheme
    if (autoThemeEnabled)
        UpdateAutoPalette(), themeName := "Automatic"
    SyncEnvWatch()
    ApplyThemeToHosts()
    UpdateDisplayState(), SaveSettings(), PushState()
}
SaveSettings() {
    global iniFile, dimmingCurve, exponentialFactor, maxSoftwareDarkness, linkHardwareSoftware, linkAllDisplays, externalMonitorNum
    global hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, hardwareStep, invertCurve
    global monitorSplitMode, monitorHW, monitorSW, dimStates, useDefaultsAtStartup, themeName, glassEnabled, glassOpacity
    global schedEnabled, schedFade, schedIncludeIndependent, SCHED_ROWS, hotkeyFlipString, primaryGuardEnabled, wpIntensity, wpFrost, livelyEffects, warmth, smoothTransitions, osdEnabled, warmStates, warmSchedEnabled, warmFadeMin, warmPhases, autoThemeEnabled, autoWeatherScope, autoThemeMap, locName, locLat, locLon, autoWeatherStrength, manualTheme, memorySaver
    try {
        IniWrite(wpIntensity, iniFile, "Settings", "WpIntensity"), IniWrite(wpFrost, iniFile, "Settings", "WpFrost"), IniWrite(livelyEffects, iniFile, "Settings", "Lively")
        IniWrite(warmth, iniFile, "Settings", "Warmth"), IniWrite(smoothTransitions, iniFile, "Settings", "Smooth"), IniWrite(osdEnabled, iniFile, "Settings", "Osd"), IniWrite(memorySaver, iniFile, "Settings", "FreeMemory")
        IniWrite(warmSchedEnabled, iniFile, "WarmSchedule", "Enabled"), IniWrite(warmFadeMin, iniFile, "WarmSchedule", "FadeMinutes")
        IniWrite(autoThemeEnabled, iniFile, "Environment", "AutoTheme"), IniWrite(autoWeatherScope, iniFile, "Environment", "WeatherScope")
        IniWrite(autoWeatherStrength, iniFile, "Environment", "WeatherStrength"), IniWrite(manualTheme, iniFile, "Environment", "ManualTheme")
        IniWrite(locName, iniFile, "Environment", "Place"), IniWrite(locLat, iniFile, "Environment", "Latitude"), IniWrite(locLon, iniFile, "Environment", "Longitude")
        for slotName, th in autoThemeMap
            IniWrite(th, iniFile, "Environment", "Theme_" . slotName)
        for ph in warmPhases
            IniWrite(ph.time, iniFile, "WarmSchedule", ph.name . "From"), IniWrite(ph.level, iniFile, "WarmSchedule", ph.name . "Level")
        IniWrite(glassEnabled, iniFile, "Settings", "Glass"), IniWrite(glassOpacity, iniFile, "Settings", "GlassOpacity")
        IniWrite(hotkeyFlipString, iniFile, "Settings", "HotkeyFlip"), IniWrite(primaryGuardEnabled, iniFile, "Settings", "PrimaryGuard")
        IniWrite(hotkeyUpString, iniFile, "Settings", "HotkeyUp"), IniWrite(hotkeyDoString, iniFile, "Settings", "HotkeyDown")
        IniWrite(hotkeySWUpString, iniFile, "Settings", "HotkeySWUp"), IniWrite(hotkeySWDoString, iniFile, "Settings", "HotkeySWDown")
        IniWrite(hardwareStep, iniFile, "Settings", "HardwareStep"), IniWrite(invertCurve, iniFile, "Settings", "InvertCurve")
        IniWrite(useDefaultsAtStartup, iniFile, "Settings", "UseDefaultsAtStartup"), IniWrite(themeName, iniFile, "Settings", "Theme")
        for mIdx, v in dimStates
            IniWrite(v, iniFile, "Settings", "Dim_M" . mIdx)
        for mIdx, v in warmStates
            IniWrite(v, iniFile, "Settings", "Warm_M" . mIdx)
        IniWrite(dimmingCurve, iniFile, "Settings", "CurveType"), IniWrite(exponentialFactor, iniFile, "Settings", "ExponentialFactor")
        IniWrite(maxSoftwareDarkness, iniFile, "Settings", "MaxSoftwareDarkness"), IniWrite(linkHardwareSoftware, iniFile, "Settings", "LinkHardwareSoftware")
        IniWrite(linkAllDisplays, iniFile, "Settings", "LinkAllDisplays"), IniWrite(externalMonitorNum, iniFile, "Settings", "TargetMonitorIDs")
        for mIdx, val in monitorSplitMode
            IniWrite(val, iniFile, "MonitorSplit", "Split_M" . mIdx)
        for mIdx, val in monitorHW
            IniWrite(val, iniFile, "MonitorSplit", "HW_M" . mIdx)
        for mIdx, val in monitorSW
            IniWrite(val, iniFile, "MonitorSplit", "SW_M" . mIdx)
        Loop 8 {
            n := A_Index
            for kind in ["HWUp", "HWDown", "SWUp", "SWDown"]
                IniWrite(GetMonitorHotkey(n, kind), iniFile, "MonitorHotkeys", n . "_" . kind)
        }
        IniWrite(schedEnabled, iniFile, "Schedule", "Enabled"), IniWrite(schedFade, iniFile, "Schedule", "FadeMinutes")
        IniWrite(schedIncludeIndependent, iniFile, "Schedule", "IncludeIndependent")
        Loop SCHED_ROWS
            IniWrite(ScheduleRowToString(A_Index), iniFile, "Schedule", "Row" . A_Index)
    }
}
LoadSettings() {
    global iniFile, dimmingCurve, exponentialFactor, maxSoftwareDarkness, linkHardwareSoftware, linkAllDisplays, externalMonitorNum
    global hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, hardwareStep, invertCurve, themeName
    global monitorSplitMode, monitorHW, monitorSW, dimStates, useDefaultsAtStartup, monitorHotkeys, THEMES, glassEnabled, glassOpacity, AUTO_SLOTS
    global schedEnabled, schedFade, schedIncludeIndependent, SCHED_ROWS, hotkeyFlipString, primaryGuardEnabled, wpIntensity, wpFrost, livelyEffects, warmth, smoothTransitions, osdEnabled, warmStates, warmSchedEnabled, warmFadeMin, warmPhases, autoThemeEnabled, autoWeatherScope, autoThemeMap, locName, locLat, locLon, autoWeatherStrength, manualTheme, memorySaver
    try {
        wpIntensity := IsNumber(tmp := IniRead(iniFile, "Settings", "WpIntensity", "")) ? Max(25, Min(100, Integer(tmp))) : 70
        wpFrost := IsNumber(tmp := IniRead(iniFile, "Settings", "WpFrost", "")) ? (Integer(tmp) ? 1 : 0) : 0
        livelyEffects := IsNumber(tmp := IniRead(iniFile, "Settings", "Lively", "")) ? (Integer(tmp) ? 1 : 0) : 1
        warmth := IsNumber(tmp := IniRead(iniFile, "Settings", "Warmth", "")) ? Clamp(tmp) : 0
        smoothTransitions := IsNumber(tmp := IniRead(iniFile, "Settings", "Smooth", "")) ? (Integer(tmp) ? 1 : 0) : 1
        osdEnabled := IsNumber(tmp := IniRead(iniFile, "Settings", "Osd", "")) ? (Integer(tmp) ? 1 : 0) : 1
        memorySaver := IsNumber(tmp := IniRead(iniFile, "Settings", "FreeMemory", "")) ? (Integer(tmp) ? 1 : 0) : 1
        warmSchedEnabled := IsNumber(tmp := IniRead(iniFile, "WarmSchedule", "Enabled", "")) ? (Integer(tmp) ? 1 : 0) : 0
        autoThemeEnabled := IsNumber(tmp := IniRead(iniFile, "Environment", "AutoTheme", "")) ? (Integer(tmp) ? 1 : 0) : 0
        autoWeatherScope := (IniRead(iniFile, "Environment", "WeatherScope", "always") == "day") ? "day" : "always"
        autoWeatherStrength := IsNumber(tmp := IniRead(iniFile, "Environment", "WeatherStrength", "")) ? Max(10, Min(100, Integer(tmp))) : 45
        tmp := IniRead(iniFile, "Environment", "ManualTheme", "")
        manualTheme := (THEMES.Has(tmp) && tmp != "Automatic") ? tmp : ((themeName != "Automatic") ? themeName : "Lava Orange")
        locName := IniRead(iniFile, "Environment", "Place", ""), locLat := IniRead(iniFile, "Environment", "Latitude", ""), locLon := IniRead(iniFile, "Environment", "Longitude", "")
        for slotName in AUTO_SLOTS {
            th := IniRead(iniFile, "Environment", "Theme_" . slotName, Chr(1))
            if (th != Chr(1) && (th == "" ? !(slotName == "Morning" || slotName == "Day" || slotName == "Evening" || slotName == "Night") : THEMES.Has(th)))
                autoThemeMap[slotName] := th
        }
        warmFadeMin := IsNumber(tmp := IniRead(iniFile, "WarmSchedule", "FadeMinutes", "")) ? Max(0, Min(180, Integer(tmp))) : 60
        for ph in warmPhases {
            if ParseHHMM(IniRead(iniFile, "WarmSchedule", ph.name . "From", ""), &tmpMins)
                ph.time := Format("{:02}:{:02}", tmpMins // 60, Mod(tmpMins, 60))
            if IsNumber(tmp := IniRead(iniFile, "WarmSchedule", ph.name . "Level", ""))
                ph.level := Clamp(tmp)
        }
        hotkeyFlipString := IniRead(iniFile, "Settings", "HotkeyFlip", "")
        primaryGuardEnabled := IsNumber(tmp := IniRead(iniFile, "Settings", "PrimaryGuard", "")) ? (Integer(tmp) ? 1 : 0) : 0
        glassEnabled := IsNumber(tmp := IniRead(iniFile, "Settings", "Glass", "")) ? (Integer(tmp) ? 1 : 0) : 0
        glassOpacity := IsNumber(tmp := IniRead(iniFile, "Settings", "GlassOpacity", "")) ? Max(20, Min(95, Integer(tmp))) : 65
        invertCurve := IsNumber(tmp := IniRead(iniFile, "Settings", "InvertCurve", "")) ? Integer(tmp) : invertCurve
        useDefaultsAtStartup := IsNumber(tmp := IniRead(iniFile, "Settings", "UseDefaultsAtStartup", "")) ? Integer(tmp) : 0
        LoadCustomTheme()
        t := IniRead(iniFile, "Settings", "Theme", "Lava Orange")
        themeName := THEMES.Has(t) ? t : "Lava Orange"
        schedEnabled := IsNumber(tmp := IniRead(iniFile, "Schedule", "Enabled", "")) ? Integer(tmp) : 0
        schedFade := IsNumber(tmp := IniRead(iniFile, "Schedule", "FadeMinutes", "")) ? Max(0, Min(120, Integer(tmp))) : 0
        schedIncludeIndependent := IsNumber(tmp := IniRead(iniFile, "Schedule", "IncludeIndependent", "")) ? Integer(tmp) : 1
        Loop SCHED_ROWS {
            rowStr := IniRead(iniFile, "Schedule", "Row" . A_Index, "")
            if (rowStr != "")
                SetScheduleRowFromString(A_Index, rowStr)
        }
        hotkeyUpString := IniRead(iniFile, "Settings", "HotkeyUp", hotkeyUpString), hotkeyDoString := IniRead(iniFile, "Settings", "HotkeyDown", hotkeyDoString)
        hotkeySWUpString := IniRead(iniFile, "Settings", "HotkeySWUp", hotkeySWUpString), hotkeySWDoString := IniRead(iniFile, "Settings", "HotkeySWDown", hotkeySWDoString)
        hardwareStep := Integer(IniRead(iniFile, "Settings", "HardwareStep", hardwareStep))
        dimmingCurve := IniRead(iniFile, "Settings", "CurveType", dimmingCurve)
        exponentialFactor := IsNumber(tmp := IniRead(iniFile, "Settings", "ExponentialFactor", "")) ? Float(tmp) : exponentialFactor
        maxSoftwareDarkness := IsNumber(tmp := IniRead(iniFile, "Settings", "MaxSoftwareDarkness", "")) ? Integer(tmp) : maxSoftwareDarkness
        linkHardwareSoftware := IsNumber(tmp := IniRead(iniFile, "Settings", "LinkHardwareSoftware", "")) ? Integer(tmp) : linkHardwareSoftware
        linkAllDisplays := IsNumber(tmp := IniRead(iniFile, "Settings", "LinkAllDisplays", "")) ? Integer(tmp) : linkAllDisplays
        externalMonitorNum := IniRead(iniFile, "Settings", "TargetMonitorIDs", externalMonitorNum)
        Loop Max(MonitorGetCount(), 8) {
            n := A_Index
            spVal := IniRead(iniFile, "MonitorSplit", "Split_M" . n, "0")
            if IsNumber(spVal)
                monitorSplitMode[n] := Integer(spVal)
            hwVal := IniRead(iniFile, "MonitorSplit", "HW_M" . n, "")
            if IsNumber(hwVal)
                monitorHW[n] := Integer(hwVal)
            swVal := IniRead(iniFile, "MonitorSplit", "SW_M" . n, "")
            if IsNumber(swVal)
                monitorSW[n] := Integer(swVal)
            dimVal := IniRead(iniFile, "Settings", "Dim_M" . n, "")
            if IsNumber(dimVal)
                dimStates[n] := Integer(dimVal)
            warmVal := IniRead(iniFile, "Settings", "Warm_M" . n, "")
            if IsNumber(warmVal)
                warmStates[n] := Integer(warmVal) ? 1 : 0
            for kind in ["HWUp", "HWDown", "SWUp", "SWDown"] {
                hk := IniRead(iniFile, "MonitorHotkeys", n . "_" . kind, "")
                if (hk != "")
                    monitorHotkeys[n . ":" . kind] := hk
            }
        }
    }
}

; =========================================================================
; 🚀 STARTUP / EXIT
; =========================================================================
; The brightness engine (hotkeys, schedule, primary-display guard) starts first and never depends on the
; window: if WebView2 is not ready yet (typical right after logon on slower PCs, or while the runtime
; updates), window creation is retried with growing delays instead of aborting the app.
global uiReady := false, uiLastError := "", uiRetryIdx := 0, uiGaveUp := false
global UI_RETRY_DELAYS := [3, 5, 10, 15, 30, 60]          ; seconds between attempts after the first one

IsLogonLaunch() {
    for a in A_Args
        if (a = "/startup")
            return true
    return A_TickCount < 180000                             ; started within 3 minutes of boot
}
WaitForDesktop() {
    t0 := A_TickCount
    while (!WinExist("ahk_class Shell_TrayWnd") && A_TickCount - t0 < 60000)
        Sleep(500)
    Sleep(4000)                                             ; let the shell and the WebView2 runtime settle
    LogAction("[UI] logon start: desktop ready after " . (A_TickCount - t0) . " ms")
}
TryCreateHosts() {
    global flyout, settings, uiReady, uiLastError, wvEnv, framelessHwnds, themeName
    if (uiReady)
        return true
    f := "", s := ""
    try {
        f := CreateHostWindow("flyout", 340, 380)
        s := CreateHostWindow("settings", 760, 540)
    } catch as e {
        uiLastError := e.Message
        LogAction("[UI] window creation failed: " . ErrText(e))
        for h in [f, s]
            if (h != "") {
                try h.ctl.Close()
                try framelessHwnds.Delete(h.hwnd)
                try h.gui.Destroy()
            }
        wvEnv := ""
        return false
    }
    flyout := f, settings := s, uiReady := true
    SyncWallpaperWatch()
    if (themeName == "Wallpaper")
        ApplyThemeToHosts()
    LogAction("[UI] windows ready")
    return true
}
RetryCreateHosts() {
    global uiRetryIdx, UI_RETRY_DELAYS, uiGaveUp, uiLastError
    if (TryCreateHosts())
        return
    uiRetryIdx++
    if (uiRetryIdx <= UI_RETRY_DELAYS.Length) {
        LogAction("[UI] retrying in " . UI_RETRY_DELAYS[uiRetryIdx] . " s (attempt " . (uiRetryIdx + 1) . ")")
        SetTimer(RetryCreateHosts, -UI_RETRY_DELAYS[uiRetryIdx] * 1000)
        return
    }
    uiGaveUp := true
    LogAction("[UI] giving up on the window for now; hotkeys and the schedule keep working")
    try TrayTip("Smart Dimmer is running (hotkeys and schedule work), but its window could not open:`n" . uiLastError . "`nClick the tray icon to try again.", "Smart Dimmer", "Iconx")
}
; Opening the window by hand (tray click, menu, hotkey) tries again at once if it is not ready yet.
EnsureUiReady() {
    global uiReady, uiLastError
    if (uiReady || TryCreateHosts())
        return true
    MsgBox("Smart Dimmer could not open its window:`n`n" . uiLastError . "`n`nHotkeys and the schedule keep working. The window needs the Microsoft Edge WebView2 Runtime; if the problem persists, install or repair it from https://developer.microsoft.com/microsoft-edge/webview2/", "Smart Dimmer", "Iconx")
    return false
}

if (!EnsureUiFiles())
    LogAction("[UI] the UI files could not be prepared in " . dataDir)
SetupTrayMenu()
RegisterDisplayPowerNotification(A_ScriptHwnd)
if (primaryGuardEnabled)
    SetPrimaryGuard(1)
SetTimer(() => UpdateDisplayState(), -200)
if (schedEnabled)
    SetTimer(() => SetScheduleEnabled(1), -1500)
if (warmSchedEnabled)
    SetTimer(() => SetWarmScheduleEnabled(1), -1600)
UpdateSkyPalette()                                        ; the Sky and automatic palettes before the windows open; weather follows
if (themeName == "Automatic" && !autoThemeEnabled)
    themeName := manualTheme
if (autoThemeEnabled)
    UpdateAutoPalette(), themeName := "Automatic"
SyncEnvWatch()
if (autoThemeEnabled || themeName == "Sky")
    SetTimer(EnvTick, -2500)
UpdateStartupShortcut()
OnExit(OnScriptExit)
Persistent()
if (IsLogonLaunch())
    WaitForDesktop()
RetryCreateHosts()
LogAction("[UI] startup complete (window " . (uiReady ? "ready" : "pending") . ")")
OnScriptExit(*) {
    global flyout, settings, powerNotifyHandle
    try SetTimer(CheckFocusLoss, 0)
    try SetTimer(PrimaryGuardTick, 0)
    try SetTimer(RefreshWallpaperThemes, 0)
    try OnMessage(0x0218, OnPowerBroadcast, 0), OnMessage(0x001A, OnSettingChange, 0), OnMessage(0x0003, OnHostMove, 0)
    if (powerNotifyHandle)
        try DllCall("user32\UnregisterPowerSettingNotification", "Ptr", powerNotifyHandle)
    try OnMessage(0x0024, OnFramelessMinMax, 0)
    try OnMessage(0x0083, OnFramelessNcCalcSize, 0), OnMessage(0x0084, OnFramelessNcHitTest, 0)
    try OnMessage(0x0085, OnFramelessNcPaint, 0), OnMessage(0x0086, OnFramelessNcActivate, 0), OnMessage(0x007E, OnDisplayChange, 0)
    try OnMessage(0x0231, OnHostEnterSizeMove, 0), OnMessage(0x0232, OnHostEnterSizeMove, 0)
    for h in [flyout, settings] {
        if (h != "")
            try h.ctl.Close()
    }
    try ResetAllGammaRamps()
}
