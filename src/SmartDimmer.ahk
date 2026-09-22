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
;@Ahk2Exe-SetVersion 1.0.0.0
;@Ahk2Exe-SetProductName Smart Dimmer
;@Ahk2Exe-SetCopyright Copyright (c) 2026 Munib Uddin - MIT License
#Include lib\WebView2.ahk
ProcessSetPriority "High"
A_IconTip := "Smart Dimmer v1"

global APP_VERSION := "1"
global iniFile := A_ScriptDir . "\SmartDimmerSettings.ini"
global startupLink := A_Startup . "\SmartDimmer.lnk"
global logFile := A_ScriptDir . "\SmartDimmerDebug.log"
global uiHtmlPath := A_ScriptDir . "\SmartDimmerUI.html"
global wvLoaderPath := A_ScriptDir . "\WebView2Loader.dll"
global wvDataDir := A_Temp . "\SmartDimmerWebView"
global wpImgDir := wvDataDir . "\wallpaper"          ; downscaled wallpaper copies served to the page as https://wallpaper.smartdimmer/

; ---- brightness state ----
global hardwareStep := 2, minHardwareBrightness := 0, maxHardwareBrightness := 100
global maxSoftwareDarkness := 180, dimmingCurve := "linear", exponentialFactor := 2.5, invertCurve := 0
global fallbackBrightness := 50, externalMonitorNum := "2", linkAllDisplays := 0, linkHardwareSoftware := 1
global hotkeyUpString := "^Up", hotkeyDoString := "^Down", hotkeySWUpString := "#Up", hotkeySWDoString := "#Down"
global monitorHotkeys := Map()          ; "mIdx:kind" -> hotkey
global monitorSplitMode := Map(), monitorHW := Map(), monitorSW := Map(), dimStates := Map()
global useDefaultsAtStartup := 0
global lastKnownMonitorCount := MonitorGetCount()
global capturing := ""                  ; "master:HWUp" / "mon:2:SWUp" while a hotkey capture is running

; ---- schedule ----
global SCHED_ROWS := 8
global schedEnabled := 0, schedFade := 0, schedIncludeIndependent := 1
global schedRows := DefaultScheduleRows()
global schedPausedIdx := 0, schedLastApplied := ""

; ---- themes ----
global THEME_ORDER := ["Lava Orange", "Aqua Blue", "Emerald Green", "Lavender Pink", "Milky Way", "Wallpaper", "Custom"]
global COLOR_SLOTS := [
    ["bg", "Window background"], ["input", "Panels, cards, title bar"], ["line", "Separators and borders"],
    ["text", "Text"], ["muted", "Secondary text"], ["accent", "Accent (titles, readouts, curve)"],
    ["btnFace", "Button face"], ["btnText", "Button text"], ["checkOn", "Switches and checkboxes (on)"],
    ["sliderTrack", "Slider track"], ["sliderFill", "Slider filled part"], ["sliderThumb", "Slider thumb"],
    ["graphBg", "Curve preview background"], ["grid", "Curve preview grid"]]
MakeTheme(bg, text, muted, accent, line, input, graphBg, grid) {
    return {bg: bg, text: text, muted: muted, accent: accent, line: line, input: input, graphBg: graphBg, grid: grid,
            btnFace: input, btnText: text, checkOn: accent, sliderTrack: line, sliderFill: accent, sliderThumb: accent}
}
CloneTheme(t) {
    global COLOR_SLOTS
    c := {}
    for slot in COLOR_SLOTS
        c.%slot[1]% := t.%slot[1]%
    return c
}
; Palettes (bg, text, muted, accent, line, panel, graphBg, grid): deep neutral bases with one vivid accent each.
global THEMES := Map(
    "Lava Orange",   MakeTheme("141417", "F5F5F7", "9A9AA6", "FF8A3D", "2A2A32", "1F1F25", "1A1A1F", "55555F"),
    "Aqua Blue",     MakeTheme("0A131B", "EAF4FA", "88A9BB", "38BDF8", "1A2D3B", "11202D", "0E1A24", "31536A"),
    "Emerald Green", MakeTheme("0A1510", "E9F6EE", "86B398", "34D399", "173124", "10211A", "0D1B15", "2E5A45"),
    "Lavender Pink", MakeTheme("16111D", "F6EEF9", "AE97C2", "EC7FD6", "2D2238", "20182D", "1A1425", "56447A"),
    "Milky Way",     MakeTheme("090B14", "EEF0FA", "9AA3CC", "A5B4FC", "1E2238", "13172C", "0F1226", "3A4170"),
    "Wallpaper",     MakeTheme("141417", "F5F5F7", "9A9AA6", "FF8A3D", "2A2A32", "1F1F25", "1A1A1F", "55555F"),   ; placeholder: computed per screen (see WALLPAPER THEME)
    "Custom",        MakeTheme("141417", "F5F5F7", "9A9AA6", "FF8A3D", "2A2A32", "1F1F25", "1A1A1F", "55555F"))
global themeName := "Lava Orange"
; the built-in palettes, kept for "reset to original" (every theme except Wallpaper can be edited by the user)
global THEME_DEFAULTS := Map()
for _name in THEME_ORDER
    THEME_DEFAULTS[_name] := CloneTheme(THEMES[_name])
; ---- glass (transparent, blur-behind windows) ----
global glassEnabled := 0, glassOpacity := 65      ; opacity of the page tint over the blurred desktop, 20..95 %
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
global framelessHwnds := Map()          ; hwnd -> {minW, minH}
global WV_INSET := 0                    ; the web view covers the whole client area; the page starts edge resizes itself ("resize" command)

if FileExist(logFile)
    try FileDelete(logFile)
LogAction(message) {
    global logFile
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") . " - " . message . "`n", logFile)
    OutputDebug("SmartDimmer: " . message . "`n")
}
LogAction("Initializing Smart Dimmer v" . APP_VERSION)

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
    global wvLoaderPath, uiHtmlPath
    ; Compiled: extract the embedded files next to the exe. Uncompiled: copies onto themselves fail
    ; harmlessly. NOTE: each FileInstall must start its own line - Ahk2Exe only embeds files for
    ; calls written that way (a "try FileInstall(...)" one-liner is silently NOT embedded).
    try {
        FileInstall("lib\WebView2Loader.dll", A_ScriptDir . "\WebView2Loader.dll", 1)
    }
    try {
        FileInstall("SmartDimmerUI.html", A_ScriptDir . "\SmartDimmerUI.html", 1)
    }
    ok := FileExist(wvLoaderPath) && FileExist(uiHtmlPath)
    LogAction("[UI] files ready=" . (ok ? 1 : 0) . " (" . A_ScriptDir . ")")
    return ok
}

; Creates a frameless host window with a WebView2 showing the UI page for `view` ("flyout"|"settings").
CreateHostWindow(view, minW, minH) {
    global wvEnv, framelessHwnds, wvDataDir, wvLoaderPath, THEMES, themeName, GLASS_RADIUS, wpImgDir
    LogAction("[UI] creating " . view . " window")
    ; (local is named 'win', not 'gui': a local called gui would shadow the Gui class)
    win := Gui("-Caption -MinimizeBox +Resize" . (view == "flyout" ? " +ToolWindow" : " -MaximizeBox"), "Smart Dimmer" . (view == "settings" ? "  -  Settings" : ""))
    win.BackColor := THEMES[themeName].bg
    framelessHwnds[win.Hwnd] := {minW: minW, minH: minH}
    ApplyFramelessNow(win.Hwnd)
    ApplyGlass(win.Hwnd, win)
    if (wvEnv == "") {
        DirCreate(wvDataDir)
        wvEnv := WebView2.CreateEnvironmentAsync(0, wvDataDir, , wvLoaderPath).await(20000)
        LogAction("[UI] WebView2 runtime " . wvEnv.BrowserVersionString)
    }
    ctl := wvEnv.CreateCoreWebView2ControllerAsync(win.Hwnd).await(20000)
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
    core.AddScriptToExecuteOnDocumentCreatedAsync("window.SD_VIEW='" . view . "'; window.SD_NATIVE_DRAG=" . nativeDrag . "; window.SD_RADIUS=" . GLASS_RADIUS . ";").await(5000)
    ; the page can load downscaled wallpaper copies (glass + Wallpaper theme) from this folder
    try {
        DirCreate(wpImgDir)
        core.SetVirtualHostNameToFolderMapping("wallpaper.smartdimmer", wpImgDir, 1)      ; COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW
    } catch as e {
        LogAction("[UI] wallpaper folder mapping failed: " . e.Message)
    }
    host := {view: view, gui: win, hwnd: win.Hwnd, ctl: ctl, core: core, ready: false, wpTheme: "", wpMon: 0, wpPath: "", areaOrder: ""}
    host.geomTimer := PushWallpaperGeometry.Bind(host)
    host.glassTimer := ReapplyGlassForHost.Bind(host)
    host.token := core.WebMessageReceived(OnPageMessage.Bind(host))
    win.OnEvent("Size", OnHostSize.Bind(host))
    win.OnEvent("Close", (*) => HideHost(host))
    core.NavigateToString(FileRead(uiHtmlPath, "UTF-8"))
    LogAction("[UI] " . view . " page loading")
    return host
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
        IniWrite(w, iniFile, "Position", "W" . suffix), IniWrite(h, iniFile, "Position", "H" . suffix)
    } else {
        IniWrite(w, iniFile, "Position", "SettingsW"), IniWrite(h, iniFile, "Position", "SettingsH")
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
        if (h == "" || !h.ready)
            continue
        try h.core.PostWebMessageAsJson(Jsn(BuildState(h)))     ; per host: the Wallpaper palette depends on the host's screen
    }
}

Toast(text, host := "") {
    global flyout, settings
    for h in (host != "" ? [host] : [flyout, settings]) {
        if (h == "" || !h.ready)
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
    idx := host.wpMon ? host.wpMon : HostMonitorIndex(host)
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
    global monitorSplitMode, monitorHW, monitorSW, dimStates, dimmingCurve, invertCurve, exponentialFactor, maxSoftwareDarkness, hardwareStep
    global hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, monitorHotkeys, capturing, hotkeyFlipString
    global THEME_ORDER, THEMES, themeName, COLOR_SLOTS, useDefaultsAtStartup, startupLink, glassEnabled, glassOpacity, wpIntensity, wpFrost
    global schedEnabled, schedFade, schedIncludeIndependent, schedRows
    mons := []
    names := MonitorNamesByIndex()
    Loop MonitorGetCount() {
        n := A_Index
        mons.Push({idx: n, name: names.Has(n) ? names[n] : "Display " . n, split: (monitorSplitMode.Has(n) && monitorSplitMode[n] == 1) ? 1 : 0,
                   hw: monitorHW.Has(n) ? monitorHW[n] : currentHardwareBright,
                   sw: monitorSW.Has(n) ? monitorSW[n] : currentSoftwareDim,
                   dim: dimStates.Has(n) ? dimStates[n] : 1})
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
        glass: glassEnabled, glassOpacity: glassOpacity, wp: WallpaperLayerState(host), wpIntensity: wpIntensity, wpFrost: wpFrost,
        startup: FileExist(startupLink) ? 1 : 0, useDefaults: useDefaultsAtStartup,
        sched: {enabled: schedEnabled, fade: schedFade, includeIndependent: schedIncludeIndependent, rows: rows, status1: lines[1], status2: lines[2]}}
}

; ---- commands from the page ----
HandleCommand(host, msg) {
    global currentHardwareBright, currentSoftwareDim, linkHardwareSoftware, linkAllDisplays, externalMonitorNum
    global monitorSplitMode, monitorHW, monitorSW, dimStates, dimmingCurve, invertCurve, exponentialFactor, maxSoftwareDarkness, hardwareStep
    global useDefaultsAtStartup, themeName, THEMES, schedRows, glassEnabled, glassOpacity, wpIntensity, wpFrost
    p := StrSplit(msg, "|")
    cmd := p[1]
    a := (p.Length >= 2) ? p[2] : "", b := (p.Length >= 3) ? p[3] : "", c := (p.Length >= 4) ? p[4] : "", d := (p.Length >= 5) ? p[5] : "", e := (p.Length >= 6) ? p[6] : ""
    switch cmd {
        case "ready":
            host.ready := true
            PushState(host)
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
        case "identify":
            IdentifyConnectedMonitors()
        case "setHW":
            SetMasterHW(Clamp(a))
        case "setSW":
            SetMasterSW(Clamp(a))
        case "setMonHW":
            monitorHW[Integer(a)] := Clamp(b), ScheduleApply()
        case "setMonSW":
            monitorSW[Integer(a)] := Clamp(b), ScheduleApply()
        case "toggleSplit":
            n := Integer(a)
            monitorSplitMode[n] := (monitorSplitMode.Has(n) && monitorSplitMode[n] == 1) ? 0 : 1
            if (monitorSplitMode[n] == 1) {
                if (!monitorHW.Has(n))
                    monitorHW[n] := currentHardwareBright
                if (!monitorSW.Has(n))
                    monitorSW[n] := currentSoftwareDim
            }
            UpdateDisplayState(), SaveSettings(), PushState()
        case "setDim":
            dimStates[Integer(a)] := Integer(b) ? 1 : 0
            UpdateDisplayState(), SaveSettings(), PushState()
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
            SelectTheme(a)
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
                if (themeName == "Wallpaper") {
                    THEMES["Custom"] := CloneTheme(WallpaperThemeForHost(host))
                    target := "Custom"
                }
                THEMES[target].%a% := StrUpper(b)
                SaveThemeColours(target)
                SelectTheme(target)
            }
        case "resetTheme":
            if (themeName != "Wallpaper") {
                ResetTheme(themeName)
                SelectTheme(themeName)
                Toast(themeName . " is back to its original colours.")
            }
        case "copyPreset":
            src := (themeName == "Custom") ? "Lava Orange" : themeName
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

SetStartup(on) {
    global startupLink
    if (on) {
        try FileCreateShortcut(A_ScriptFullPath, startupLink, A_ScriptDir)
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
    targetMonitor := 1, midX := X + (W / 2), midY := Y + (H / 2)
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
        if (midX >= Left && midX <= Right && midY >= Top && midY <= Bottom) {
            targetMonitor := A_Index
            break
        }
    }
    MonitorGetWorkArea(targetMonitor, &wLeft, &wTop, &wRight, &wBottom)
    return {X: Integer(Max(wLeft + 4, Min(X, wRight - W - 4))), Y: Integer(Max(wTop + 4, Min(Y, wBottom - H - 4)))}
}
ShowDashboard() {
    global flyout, iniFile
    sz := GetFlyoutSize()
    lastX := IniRead(iniFile, "Position", "X", "Default"), lastY := IniRead(iniFile, "Position", "Y", "Default")
    if (lastX == "Default" || lastY == "Default") {
        MonitorGetWorkArea(1, &wLeft, &wTop, &wRight, &wBottom)
        posX := wLeft + ((wRight - wLeft) - sz.W) // 2, posY := wTop + ((wBottom - wTop) - sz.H) // 2
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
    if (IsHostVisible(flyout) && WinActive("ahk_id " . flyout.hwnd))
        CloseDashboard()
    else
        ShowDashboard()
}
SaveCurrentPosition() {
    global flyout, iniFile
    if (!IsHostVisible(flyout))
        return
    WinGetPos(&x, &y, &w, &h, "ahk_id " . flyout.hwnd)
    coords := ConstrainToScreenBoundaries(x, y, w, h)
    if (coords.X != x || coords.Y != y)
        WinMove(coords.X, coords.Y, , , "ahk_id " . flyout.hwnd)
    IniWrite(coords.X, iniFile, "Position", "X"), IniWrite(coords.Y, iniFile, "Position", "Y")
}
CheckFocusLoss() {
    global flyout, settings
    if (!IsHostVisible(flyout))
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
}
ExecuteVolumeDownAction(*) {
    global currentHardwareBright, hardwareStep, minHardwareBrightness
    if (currentHardwareBright > minHardwareBrightness)
        SetMasterHWStep(Max(minHardwareBrightness, currentHardwareBright - hardwareStep))
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
}
ExecuteSoftwareDownAction(*) {
    global currentSoftwareDim, hardwareStep, minHardwareBrightness
    if (currentSoftwareDim > minHardwareBrightness)
        currentSoftwareDim := Max(minHardwareBrightness, currentSoftwareDim - hardwareStep), RequestDisplayUpdate()
}

; =========================================================================
; 🎨 THEMES
; =========================================================================
SelectTheme(name) {
    global THEMES, themeName
    if (!THEMES.Has(name))
        name := "Lava Orange"
    themeName := name
    SyncWallpaperWatch()
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
        if (name != "Wallpaper")
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
    MonitorGet(mIdx, &L, &T, &R, &B)
    midX := L + (R - L) // 2, midY := T + (B - T) // 2
    return DllCall("User32\MonitorFromPoint", "Int64", (midX & 0xFFFFFFFF) | (midY << 32), "UInt", 2, "Ptr")
}
SetMonitorGammaRamp(mIdx, brightness) {
    hMonitor := GetHMonitorFromIndex(mIdx)
    monInfo := Buffer(104, 0)
    NumPut("UInt", 104, monInfo)
    if !DllCall("User32\GetMonitorInfoW", "Ptr", hMonitor, "Ptr", monInfo)
        return false
    deviceName := StrGet(monInfo.Ptr + 40, 32, "UTF-16")
    hDC := DllCall("Gdi32\CreateDCW", "Str", deviceName, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    if (!hDC)
        return false
    ramp := Buffer(1536, 0)
    Loop 256 {
        i := A_Index - 1
        val := Min(65535, Round(i * 256 * brightness))
        NumPut("UShort", val, ramp, i * 2), NumPut("UShort", val, ramp, 512 + (i * 2)), NumPut("UShort", val, ramp, 1024 + (i * 2))
    }
    result := DllCall("Gdi32\SetDeviceGammaRamp", "Ptr", hDC, "Ptr", ramp)
    DllCall("Gdi32\DeleteDC", "Ptr", hDC)
    return result ? true : false
}
ResetAllGammaRamps(*) {
    Loop MonitorGetCount()
        SetMonitorGammaRamp(A_Index, 1.0)
    LogAction("[Gamma] All monitor gamma ramps reset to default (1.0)")
}
UpdateDisplayState() {
    global currentHardwareBright, currentSoftwareDim, externalMonitorNum, iniFile
    global minHardwareBrightness, maxHardwareBrightness, maxSoftwareDarkness, dimStates
    global monitorSplitMode, monitorHW, monitorSW
    try {
        IniWrite(currentHardwareBright, iniFile, "Settings", "LastHardwareBright")
        IniWrite(currentSoftwareDim, iniFile, "Settings", "LastSoftwareDim")
    }
    monitorCount := MonitorGetCount()
    splitExclusions := ""
    Loop monitorCount {
        if (monitorSplitMode.Has(A_Index) && monitorSplitMode[A_Index] == 1)
            splitExclusions .= (splitExclusions = "" ? "" : ",") . A_Index
    }
    NativeSetMonitorBrightness(currentHardwareBright, externalMonitorNum, splitExclusions)
    minGammaFloor := Max(0.05, 1.0 - (maxSoftwareDarkness / 255))
    Loop monitorCount {
        mIdx := A_Index
        isSplit := (monitorSplitMode.Has(mIdx) && monitorSplitMode[mIdx] == 1)
        swValue := isSplit ? (monitorSW.Has(mIdx) ? monitorSW[mIdx] : currentSoftwareDim) : currentSoftwareDim
        calculatedGamma := Max(minGammaFloor, MapRange(swValue, minHardwareBrightness, maxHardwareBrightness, 0.0, 1.0))
        isDimEnabled := !dimStates.Has(mIdx) || dimStates[mIdx] == 1
        SetMonitorGammaRamp(mIdx, (calculatedGamma < 1.0 && isDimEnabled) ? calculatedGamma : 1.0)
        if (isSplit)
            NativeSetMonitorBrightness(monitorHW.Has(mIdx) ? monitorHW[mIdx] : currentHardwareBright, String(mIdx), "", true)
    }
    LogAction("[Gamma Router] Master software brightness=" . currentSoftwareDim)
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
        l1 := "Now " . FormatTime(, "HH:mm") . ": following the " . st.time . " entry -> hardware " . st.hw . "%, software " . st.sw . "%.  Next: " . st.nextTime . "."
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
; 💾 DEFAULTS + PERSISTENCE (same INI layout as v5)
; =========================================================================
FactoryState() {
    global COLOR_SLOTS, THEMES, THEME_DEFAULTS
    s := Map()
    s["HardwareStep"] := 2, s["CurveType"] := "linear", s["ExponentialFactor"] := 2.5
    s["MaxSoftwareDarkness"] := 180, s["LinkHardwareSoftware"] := 1, s["LinkAllDisplays"] := 0
    s["TargetMonitorIDs"] := "2", s["InvertCurve"] := 0, s["Theme"] := "Lava Orange", s["Glass"] := 0, s["GlassOpacity"] := 65
    s["HotkeyUp"] := "^Up", s["HotkeyDown"] := "^Down", s["HotkeySWUp"] := "#Up", s["HotkeySWDown"] := "#Down"
    s["HotkeyFlip"] := "", s["PrimaryGuard"] := 0, s["WpIntensity"] := 70, s["WpFrost"] := 0
    s["HardwareBright"] := 50, s["SoftwareDim"] := 50
    Loop 8 {
        n := A_Index
        s["Split_M" n] := 0, s["HW_M" n] := 50, s["SW_M" n] := 50, s["Dim_M" n] := 1
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
    global schedEnabled, schedFade, schedIncludeIndependent, SCHED_ROWS, hotkeyFlipString, primaryGuardEnabled, wpIntensity, wpFrost
    s := Map()
    s["HardwareStep"] := hardwareStep, s["CurveType"] := dimmingCurve, s["ExponentialFactor"] := exponentialFactor
    s["MaxSoftwareDarkness"] := maxSoftwareDarkness, s["LinkHardwareSoftware"] := linkHardwareSoftware
    s["LinkAllDisplays"] := linkAllDisplays, s["TargetMonitorIDs"] := externalMonitorNum, s["InvertCurve"] := invertCurve, s["Theme"] := themeName
    s["Glass"] := glassEnabled, s["GlassOpacity"] := glassOpacity
    s["HotkeyFlip"] := hotkeyFlipString, s["PrimaryGuard"] := primaryGuardEnabled, s["WpIntensity"] := wpIntensity, s["WpFrost"] := wpFrost
    s["HotkeyUp"] := hotkeyUpString, s["HotkeyDown"] := hotkeyDoString, s["HotkeySWUp"] := hotkeySWUpString, s["HotkeySWDown"] := hotkeySWDoString
    s["HardwareBright"] := currentHardwareBright, s["SoftwareDim"] := currentSoftwareDim
    Loop 8 {
        n := A_Index
        s["Split_M" n] := monitorSplitMode.Has(n) ? monitorSplitMode[n] : 0
        s["HW_M" n] := monitorHW.Has(n) ? monitorHW[n] : currentHardwareBright
        s["SW_M" n] := monitorSW.Has(n) ? monitorSW[n] : currentSoftwareDim
        s["Dim_M" n] := dimStates.Has(n) ? dimStates[n] : 1
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
    global monitorSplitMode, monitorHW, monitorSW, dimStates, COLOR_SLOTS, THEMES, monitorHotkeys, themeName, glassEnabled, glassOpacity
    global schedEnabled, schedFade, schedIncludeIndependent, SCHED_ROWS, hotkeyFlipString, primaryGuardEnabled, wpIntensity, wpFrost
    if (s.Has("HotkeyFlip"))
        hotkeyFlipString := s["HotkeyFlip"]
    if (s.Has("WpIntensity") && IsNumber(s["WpIntensity"]))
        wpIntensity := Max(25, Min(100, Integer(s["WpIntensity"])))
    if (s.Has("WpFrost") && IsNumber(s["WpFrost"]))
        wpFrost := Integer(s["WpFrost"]) ? 1 : 0
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
    monitorSplitMode := Map(), monitorHW := Map(), monitorSW := Map(), dimStates := Map()
    Loop 8 {
        n := A_Index
        monitorSplitMode[n] := Integer(s["Split_M" n]), monitorHW[n] := Integer(s["HW_M" n]), monitorSW[n] := Integer(s["SW_M" n]), dimStates[n] := Integer(s["Dim_M" n])
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
    ApplyThemeToHosts()
    UpdateDisplayState(), SaveSettings(), PushState()
}
SaveSettings() {
    global iniFile, dimmingCurve, exponentialFactor, maxSoftwareDarkness, linkHardwareSoftware, linkAllDisplays, externalMonitorNum
    global hotkeyUpString, hotkeyDoString, hotkeySWUpString, hotkeySWDoString, hardwareStep, invertCurve
    global monitorSplitMode, monitorHW, monitorSW, dimStates, useDefaultsAtStartup, themeName, glassEnabled, glassOpacity
    global schedEnabled, schedFade, schedIncludeIndependent, SCHED_ROWS, hotkeyFlipString, primaryGuardEnabled, wpIntensity, wpFrost
    try {
        IniWrite(wpIntensity, iniFile, "Settings", "WpIntensity"), IniWrite(wpFrost, iniFile, "Settings", "WpFrost")
        IniWrite(glassEnabled, iniFile, "Settings", "Glass"), IniWrite(glassOpacity, iniFile, "Settings", "GlassOpacity")
        IniWrite(hotkeyFlipString, iniFile, "Settings", "HotkeyFlip"), IniWrite(primaryGuardEnabled, iniFile, "Settings", "PrimaryGuard")
        IniWrite(hotkeyUpString, iniFile, "Settings", "HotkeyUp"), IniWrite(hotkeyDoString, iniFile, "Settings", "HotkeyDown")
        IniWrite(hotkeySWUpString, iniFile, "Settings", "HotkeySWUp"), IniWrite(hotkeySWDoString, iniFile, "Settings", "HotkeySWDown")
        IniWrite(hardwareStep, iniFile, "Settings", "HardwareStep"), IniWrite(invertCurve, iniFile, "Settings", "InvertCurve")
        IniWrite(useDefaultsAtStartup, iniFile, "Settings", "UseDefaultsAtStartup"), IniWrite(themeName, iniFile, "Settings", "Theme")
        for mIdx, v in dimStates
            IniWrite(v, iniFile, "Settings", "Dim_M" . mIdx)
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
    global monitorSplitMode, monitorHW, monitorSW, dimStates, useDefaultsAtStartup, monitorHotkeys, THEMES, glassEnabled, glassOpacity
    global schedEnabled, schedFade, schedIncludeIndependent, SCHED_ROWS, hotkeyFlipString, primaryGuardEnabled, wpIntensity, wpFrost
    try {
        wpIntensity := IsNumber(tmp := IniRead(iniFile, "Settings", "WpIntensity", "")) ? Max(25, Min(100, Integer(tmp))) : 70
        wpFrost := IsNumber(tmp := IniRead(iniFile, "Settings", "WpFrost", "")) ? (Integer(tmp) ? 1 : 0) : 0
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
if (!EnsureUiFiles()) {
    MsgBox("The UI files could not be prepared:`n" . uiHtmlPath . "`n" . wvLoaderPath, "Smart Dimmer", "Iconx")
    ExitApp
}
try {
    flyout := CreateHostWindow("flyout", 340, 380)
    settings := CreateHostWindow("settings", 760, 540)
} catch as e {
    LogAction("[UI] startup failed: " . e.Message . " (" . e.What . ") " . e.Extra)
    MsgBox("Could not start the WebView2 user interface.`n`n" . e.Message . "`n`nThe Microsoft Edge WebView2 runtime must be installed (it comes with Windows 10/11 updates).", "Smart Dimmer", "Iconx")
    ExitApp
}
SetupTrayMenu()
RegisterDisplayPowerNotification(flyout.hwnd)
SyncWallpaperWatch()
if (themeName == "Wallpaper")
    ApplyThemeToHosts()
if (primaryGuardEnabled)
    SetPrimaryGuard(1)
SetTimer(() => UpdateDisplayState(), -200)
if (schedEnabled)
    SetTimer(() => SetScheduleEnabled(1), -1500)
OnExit(OnScriptExit)
Persistent()
LogAction("[UI] startup complete")
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
    ResetAllGammaRamps()
}
