#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

#Include Lib\WebViewToo.ahk

SendMode "Event"
SetKeyDelay 30, 30

; Auto-run as admin so key events can reach the game reliably.
if !A_IsAdmin {
    Run '*RunAs "' A_ScriptFullPath '"'
    ExitApp
}

SettingsFile := A_ScriptDir "\ro_macro_settings.ini"

; --- Version: read VERSION file in this folder (ship with releases). Fallback if missing. ---
ROMacroVersion := "1.0.0"
try {
    vf := A_ScriptDir "\VERSION"
    if FileExist(vf) {
        tv := Trim(FileRead(vf), "`r`n`t ")
        if RegExMatch(tv, "^\d+\.\d+\.\d+$")
            ROMacroVersion := tv
    }
}
ROMacroRepoOwner := "Reynbow"
ROMacroRepoName := "ro-macro"
; Standalone: compile with scripts\build-release.ps1 (Ahk2Exe). Ship zip contents next to RO-Macro.exe.
; WebView2Loader is embedded by Lib\WebViewToo.ahk (no separate DLL). Users need the Edge WebView2 Runtime.

global RomUpdateAvailable := false
global RomUpdateLatestTag := ""
global RomUpdateRemoteVersion := ""
global RomUpdateCheckInFlight := false

MacrosEnabled := IniBool("State", "MacrosEnabled", false)
QMacroEnabled := IniBool("State", "QEnabled", true)
WMacroEnabled := IniBool("State", "WEnabled", true)
EMacroEnabled := IniBool("State", "EEnabled", true)
RMacroEnabled := IniBool("State", "REnabled", true)
ZMacroEnabled := IniBool("State", "ZEnabled", true)
XMacroEnabled := IniBool("State", "XEnabled", true)
CMacroEnabled := IniBool("State", "CEnabled", true)
VMacroEnabled := IniBool("State", "VEnabled", true)
KeyBindings := Map(
    "Q", LoadHotkeyBinding("Q", "q"),
    "W", LoadHotkeyBinding("W", "w"),
    "E", LoadHotkeyBinding("E", "e"),
    "R", LoadHotkeyBinding("R", "r"),
    "Z", LoadHotkeyBinding("Z", "z"),
    "X", LoadHotkeyBinding("X", "x"),
    "C", LoadHotkeyBinding("C", "c"),
    "V", LoadHotkeyBinding("V", "v")
)
RegisteredHotkeys := Map()

QHeld := false
WHeld := false
EHeld := false
RHeld := false
ZHeld := false
XHeld := false
CHeld := false
VHeld := false

; Milliseconds between repeated sends for any slot in Spam key mode (Q–V). Not used for Wait, then Enter.
SpamDelay := IniIntTiming("SpamDelay", 80)

; Used when a slot is set to "wait, then Enter" (any slot). Reads EnterConfirmDelay, falls back to legacy RConfirmDelay.
EnterConfirmDelay := LoadEnterConfirmDelay()

; Random variation in milliseconds.
; Example: 5 means each delay can vary by -5ms to +5ms.
SpamJitter := IniIntTiming("SpamJitter", 5)

; After first key send, wait this long before spam timers start (helps in-game chat).
SpamHoldDelayMs := IniIntTiming("SpamHoldDelayMs", 100)

TargetProcess := IniRead(SettingsFile, "Timing", "TargetProcess", "dw-ro.exe")
HudX := IniRead(SettingsFile, "HUD", "X", 20)
HudY := IniRead(SettingsFile, "HUD", "Y", 20)
WVGui := ""

; Last measured RTT to a remote IPv4 peer of the game process (from TCP + ICMP ping).
GamePingLastMs := ""
GamePingLastHost := ""

; When clipboard text starts with /navi (e.g. from a web browser), paste into game chat.
NaviClipboardEnabled := IniBool("Navi", "Enabled", true)
NaviRequireZen := IniBool("Navi", "RequireZen", true)
ZenBrowserExe := IniRead(SettingsFile, "Navi", "ZenExe", "zen.exe")
NaviIgnoreClip := false

global ElementOverlayEnabled := Map()
for _elName in ["Earth", "Wind", "Water", "Fire", "Ghost", "Shadow", "Holy"]
    ElementOverlayEnabled[_elName] := IniBool("ElementOverlay", _elName, false)
global ElementOverlayGuis := Map()

; First-time setup: no INI file, or [Setup] OnboardingComplete=0
global OnboardingNeeded := false
if FileExist(SettingsFile)
    OnboardingNeeded := (IniRead(SettingsFile, "Setup", "OnboardingComplete", "1") != "1")
else
    OnboardingNeeded := true

AltPassthroughSpecs := LoadAltPassthroughSpecs()
RegisteredAltHotkeys := []
MainToggleHotkey := LoadMainToggleHotkey()
RegisteredMainToggleHk := ""
global CaptureHotkeyUiActive := false

SlotBehaviors := Map()
for s in ["Q", "W", "E", "R", "Z", "X", "C", "V"]
    SlotBehaviors[s] := LoadSlotBehavior(s)

BuildTray()
BuildWebGui()
RegisterMacroHotkeys()
RegisterAltPassthroughHotkeys()
RegisterMainToggleHotkey()
OnMessage 0x0003, ElementOverlayOnWinMove
SetTimer SaveHudPosition, 1000
SetTimer RefreshGameServerPing, 5000
SetTimer RomPeriodicUpdateCheck, 3600000
OnClipboardChange OnClipboardMaybeNavi
OnExit ExitSub

return


ApplyShellIcons(g := 0) {
    global MacrosEnabled
    dir := A_ScriptDir "\assets\"
    ico := MacrosEnabled ? (dir "ro-macro-on.ico") : (dir "ro-macro-off.ico")
    dll := A_WinDir "\System32\imageres.dll"
    if FileExist(ico) {
        try TraySetIcon(ico)
        if IsObject(g)
            try g.SetIcon(ico)
    } else {
        try TraySetIcon(dll, 1)
        if IsObject(g)
            try g.SetIcon(dll, 1)
    }
}


BuildTray() {
    A_IconTip := "RO Macro"
    m := A_TrayMenu
    m.Delete()
    m.Add("Show HUD", (*) => ShowHud())
    m.Add("Macros Enabled", (*) => ToggleMainBridge())
    m.Add("Navi paste (web browser → game)", NaviTrayToggle)
    m.Add()
    m.Add("Show Earth element tile (test)", (*) => ElementOverlayTrayShowEarth())
    m.Add()
    m.Add("Check for updates", (*) => RomCheckForUpdateNow(true))
    m.Add("Open GitHub releases", (*) => OpenUrlBridge(RomReleasesLatestUrl()))
    m.Add("Exit", (*) => ExitApp())
    m.Default := "Show HUD"
    UpdateTray()
    ApplyShellIcons()
}


UpdateTray() {
    global MacrosEnabled, NaviClipboardEnabled

    try {
        if MacrosEnabled
            A_TrayMenu.Check("Macros Enabled")
        else
            A_TrayMenu.Uncheck("Macros Enabled")
    }
    try {
        if NaviClipboardEnabled
            A_TrayMenu.Check("Navi paste (web browser → game)")
        else
            A_TrayMenu.Uncheck("Navi paste (web browser → game)")
    }
}


NaviTrayToggle(*) {
    global NaviClipboardEnabled

    NaviClipboardEnabled := !NaviClipboardEnabled
    SaveNaviState()
    UpdateTray()
}


ElementOverlayTrayShowEarth(*) {
    global ElementOverlayEnabled

    ElementOverlayEnabled["Earth"] := true
    SaveElementOverlayIni()
    RefreshElementOverlayGuis()
    c := ElementOverlayGuis.Count
    if c
        TrayTip(
            "RO Macro",
            "Earth tile should be on screen (" c " tile(s)). "
            "Task Manager → Details: look at this AutoHotkey.exe — overlays are extra top-level windows, not new processes named Earth.",
            8
        )
    else
        TrayTip("RO Macro", "Earth is enabled in settings but no overlay window was created. Check for script errors or try moving the HUD on-screen.", 8)
}


OnClipboardMaybeNavi(*) {
    SetTimer TryPasteNaviToGame, -30
}


TryPasteNaviToGame(*) {
    global NaviClipboardEnabled, NaviRequireZen, ZenBrowserExe, TargetProcess, NaviIgnoreClip

    static debounceText := "", debounceTick := 0

    if NaviIgnoreClip
        return
    if !NaviClipboardEnabled
        return

    try text := Trim(A_Clipboard, " `t`r`n")
    catch
        return

    if StrLen(text) < 5 || StrLower(SubStr(text, 1, 5)) != "/navi"
        return

    if (text = debounceText && A_TickCount - debounceTick < 500)
        return
    debounceText := text
    debounceTick := A_TickCount

    if NaviRequireZen && !WinActive("ahk_exe " ZenBrowserExe)
        return

    if !WinExist("ahk_exe " TargetProcess)
        return

    WinActivate "ahk_exe " TargetProcess
    if !WinWaitActive("ahk_exe " TargetProcess, , 1.5)
        return

    NaviIgnoreClip := true
    try {
        Sleep 80
        SendEvent "{Enter}"
        Sleep 50
        A_Clipboard := text
        ClipWait 1
        SendEvent "^v"
        Sleep 50
        SendEvent "{Enter}"
        Sleep 50
        SendEvent "{Enter}"
    } finally {
        NaviIgnoreClip := false
    }
}


ShowHud(*) {
    global WVGui, HudX, HudY

    try WVGui.Show(Format("x{1} y{2} w380 h354 NA", HudX, HudY))
    ElementOverlayRaiseAll()
}


HideHud() {
    global WVGui

    try WVGui.Hide()
    return "ok"
}


ExitBridge() {
    ExitApp()
}


RestartBridge() {
    SaveState()
    SaveNaviState()
    SaveHudPosition()
    if A_IsCompiled
        Run Format('"{}" /restart', A_ScriptFullPath)
    else
        Run Format('"{}" /restart "{}"', A_AhkPath, A_ScriptFullPath)
    ExitApp()
}


ToggleMainBridge() {
    global MacrosEnabled

    SetMacrosEnabled(!MacrosEnabled)
    return GetStateJSON()
}


SetMainBridge(enabled) {
    SetMacrosEnabled(enabled ? true : false)
    return GetStateJSON()
}


SetMacrosEnabled(enabled) {
    global MacrosEnabled, WVGui

    MacrosEnabled := enabled ? true : false
    if !MacrosEnabled
        StopAllSpam()

    SaveState()
    UpdateTray()
    ApplyShellIcons(IsObject(WVGui) ? WVGui : 0)
    PushState()
}


ToggleKeyBridge(key) {
    global QMacroEnabled, WMacroEnabled, EMacroEnabled, RMacroEnabled
    global ZMacroEnabled, XMacroEnabled, CMacroEnabled, VMacroEnabled

    key := StrUpper(String(key))
    switch key {
        case "Q":
            QMacroEnabled := !QMacroEnabled
        case "W":
            WMacroEnabled := !WMacroEnabled
        case "E":
            EMacroEnabled := !EMacroEnabled
        case "R":
            RMacroEnabled := !RMacroEnabled
        case "Z":
            ZMacroEnabled := !ZMacroEnabled
        case "X":
            XMacroEnabled := !XMacroEnabled
        case "C":
            CMacroEnabled := !CMacroEnabled
        case "V":
            VMacroEnabled := !VMacroEnabled
    }

    if !IsKeyEnabled(key)
        StopKeySpam(key)

    SaveState()
    PushState()
    return GetStateJSON()
}


SaveKeyBindingBridge(slot, key) {
    global KeyBindings

    slot := StrUpper(String(slot))
    if !KeyBindings.Has(slot)
        return "error"

    newKey := NormalizeHotkeyName(key)
    if newKey = ""
        return "invalid"

    for otherSlot, otherKey in KeyBindings {
        if otherSlot != slot && StrLower(otherKey) = StrLower(newKey)
            return "duplicate"
    }

    StopKeySpam(slot)
    UnregisterMacroHotkey(slot)
    KeyBindings[slot] := newKey
    SaveState()
    RegisterMacroHotkey(slot)
    PushState()
    return GetStateJSON()
}


GameExePathLooksVendorOrSystem(path) {
    if path = ""
        return false
    p := StrReplace(StrLower(Trim(path)), "/", "\")
    static needles := [
        "\windows\system32\",
        "\windows\syswow64\",
        "\windows\servicing\",
        "\windows\winsxs\",
        "\windows\systemapps\",
        "\windows\uus\",
        "\windows\softwaredistribution\",
        "\windows\immersivecontrolpanel\",
        "\windows\microsoft.net\",
        "\windows\speech\",
        "\windows\media\",
        "\program files\windowsapps\",
        "\program files\microsoft\",
        "\program files (x86)\microsoft\",
        "\program files\microsoft office\",
        "\program files (x86)\microsoft office\",
        "\program files\common files\microsoft shared\",
        "\program files (x86)\common files\microsoft shared\",
        "\program files\common files\microsoft\",
        "\program files (x86)\common files\microsoft\",
        "\program files\google\update\",
        "\program files (x86)\google\update\",
        "\program files\google\chrome\application\",
        "\program files (x86)\google\chrome\application\",
        "\program files\microsoft\edge\application\",
        "\program files (x86)\microsoft\edge\application\",
        "\program files\apple software update\",
        "\program files (x86)\apple software update\",
        "\program files\bonjour\",
        "\program files (x86)\bonjour\",
        "\program files\common files\apple\",
        "\program files (x86)\common files\apple\",
        "\program files\dotnet\",
        "\program files (x86)\dotnet\",
        "\program files\nvidia corporation\",
        "\program files (x86)\nvidia corporation\",
        "\program files\intel\",
        "\program files (x86)\intel\",
        "\program files\amd\",
        "\program files (x86)\amd\",
        "\program files\windows defender\",
        "\program files (x86)\windows defender\",
        "\program files\microsoft onedrive\",
        "\program files (x86)\microsoft onedrive\",
        "\windows defender advanced threat protection\",
        "\microsoft\edgewebview\application\",
    ]
    for nd in needles
        if InStr(p, nd)
            return true
    return false
}


GameExeBlockedForROPick(name) {
    static blocked := 0
    if blocked = 0 {
        blocked := Map()
        for n in StrSplit(
            "acrobat.exe,acrocef.exe,acrodist.exe,acrotray.exe,adesklicensing.exe,adesklicensingagent.exe,"
            "adobeipcbroker.exe,adobecollabsync.exe,adobeupdateservice.exe,aggregatorhost.exe,applicationframehost.exe,"
            "armsvc.exe,audiodg.exe,brave.exe,ccxprocess.exe,chrome.exe,chromium.exe,code.exe,compattelrunner.exe,"
            "conhost.exe,coresync.exe,creative cloud.exe,cursor.exe,csrss.exe,ctfmon.exe,dashost.exe,devenv.exe,"
            "discord.exe,dllhost.exe,dopus.exe,dotnet.exe,dwm.exe,excel.exe,explorer.exe,firefox.exe,fontdrvhost.exe,"
            "gamebar.exe,gamingservices.exe,gamingservicesnet.exe,git.exe,googledrivesync.exe,helppane.exe,iexplore.exe,"
            "ieuser.exe,idea64.exe,intelcphecisvc.exe,ituneshelper.exe,lockapp.exe,logonui.exe,lsass.exe,lync.exe,"
            "mmc.exe,mousocoreworker.exe,mpcmdrun.exe,msbuild.exe,msedgewebview2.exe,msedge.exe,msmpeng.exe,mspaint.exe,"
            "ms-teams.exe,msaccess.exe,msteams.exe,notepad.exe,notepad++.exe,nissrv.exe,nvcontainer.exe,nvdisplay.container.exe,"
            "nvidia web helper.exe,onedrive.exe,onenote.exe,openconsole.exe,outlook.exe,paintdotnet.exe,phoneexperiencehost.exe,"
            "photoshop.exe,plugin-container.exe,powerpnt.exe,runtimebroker.exe,rider64.exe,searchapp.exe,searchfilterhost.exe,"
            "searchhost.exe,searchindexer.exe,searchprotocolhost.exe,securityhealthservice.exe,securityhealthsystray.exe,"
            "servicehub.host.exe,servicehub.identityhost.exe,servicehub.threadedwaitdialog.exe,services.exe,shellhost.exe,"
            "shellexperiencehost.exe,sihost.exe,slack.exe,smss.exe,spoolsv.exe,spotify.exe,startmenuexperiencehost.exe,"
            "steam.exe,steamwebhelper.exe,svchost.exe,system.exe,systemsettings.exe,taskhost.exe,taskhostw.exe,teams.exe,"
            "textinputhost.exe,tor.exe,trustedinstaller.exe,userinit.exe,vbcsw.exe,vbcscompiler.exe,vlc.exe,vmcompute.exe,"
            "vmms.exe,vmmem.exe,vmmemwsl.exe,waterfox.exe,webex.exe,werfault.exe,wermgr.exe,wininit.exe,winlogon.exe,"
            "winword.exe,wmiadap.exe,wmiaprpl.exe,wmiprvse.exe,wsl.exe,wslhost.exe,wslrelay.exe,xboxgamebar.exe,"
            "zoom.exe,opera.exe,opera_crashreporter.exe,vivaldi.exe,zen.exe,slimjet.exe,epicgameslauncher.exe,"
            "galaxyclient.exe,epicwebhelper.exe,dropbox.exe,onedrive.sync.service.exe,crashpad_handler.exe,"
            "crashreporter.exe,updater.exe,software_reporter_tool.exe,setup.exe,installutil.exe,msiexec.exe,"
            "regsvr32.exe,rundll32.exe,smartscreen.exe,applemobiledeviceservice.exe,icloud.exe,icloudservices.exe,"
            "mdnsresponder.exe,regedit.exe,taskmgr.exe,wscript.exe,cscript.exe,powershell.exe,pwsh.exe,cmd.exe,wt.exe", ",") {
            t := Trim(StrLower(n))
            if t != ""
                blocked[t] := true
        }
    }
    return blocked.Has(StrLower(Trim(name)))
}


SortStrArrayCaseInsensitive(arr) {
    n := arr.Length
    if n <= 1
        return
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if (StrCompare(arr[j], arr[j + 1]) > 0) {
                t := arr[j]
                arr[j] := arr[j + 1]
                arr[j + 1] := t
            }
        }
    }
}


GetRunningExesJSON(kind := "game") {
    kind := StrLower(Trim(String(kind)))
    exePaths := Map()
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("SELECT Name, ExecutablePath FROM Win32_Process") {
            n := proc.Name
            if n = ""
                continue
            n := String(n)
            if !RegExMatch(n, "i)\.exe$")
                continue
            ep := ""
            try ep := String(proc.ExecutablePath)
            catch
                ep := ""
            if !exePaths.Has(n)
                exePaths[n] := ep
            else if exePaths[n] = "" && ep != ""
                exePaths[n] := ep
        }
    } catch {
        return "[]"
    }
    arr := []
    for n in exePaths
        arr.Push(n)
    nLen := arr.Length
    if nLen > 1 {
        Loop nLen - 1 {
            i := A_Index
            Loop nLen - i {
                j := A_Index
                if (StrCompare(arr[j], arr[j + 1]) > 0) {
                    t := arr[j]
                    arr[j] := arr[j + 1]
                    arr[j + 1] := t
                }
            }
        }
    }
    if kind != "game" {
        guess := []
        rest := []
        for n in arr {
            g := false
            if RegExMatch(n, "i)(zen|chrome|firefox|msedge|brave|opera|vivaldi|waterfox|webview)")
                g := true
            if g
                guess.Push(n)
            else
                rest.Push(n)
        }
        ordered := []
        for n in guess
            ordered.Push(n)
        for n in rest
            ordered.Push(n)
        s := "["
        first := true
        for n in ordered {
            isGuess := false
            if RegExMatch(n, "i)(zen|chrome|firefox|msedge|brave|opera|vivaldi|waterfox|webview)")
                isGuess := true
            if !first
                s .= ","
            first := false
            s .= '{"exe":' EscJSON(n) . ',"guess":' JsonBool(isGuess) . '}'
        }
        return s "]"
    }
    filtered := []
    for n in arr {
        if GameExeBlockedForROPick(n)
            continue
        if GameExePathLooksVendorOrSystem(exePaths[n])
            continue
        filtered.Push(n)
    }
    tierRoExe := []
    tierRoLike := []
    tierRest := []
    for n in filtered {
        nl := StrLower(n)
        if nl = "ro.exe"
            tierRoExe.Push(n)
        else if InStr(nl, "ro")
            tierRoLike.Push(n)
        else
            tierRest.Push(n)
    }
    SortStrArrayCaseInsensitive(tierRoExe)
    SortStrArrayCaseInsensitive(tierRoLike)
    SortStrArrayCaseInsensitive(tierRest)
    ordered := []
    for n in tierRoExe
        ordered.Push(n)
    for n in tierRoLike
        ordered.Push(n)
    for n in tierRest
        ordered.Push(n)
    s := "["
    first := true
    for n in ordered {
        nl := StrLower(n)
        isGuess := (nl = "ro.exe") || InStr(nl, "ro")
        if !first
            s .= ","
        first := false
        s .= '{"exe":' EscJSON(n) . ',"guess":' JsonBool(isGuess) . '}'
    }
    return s "]"
}


PickExeFileBridge(prompt := "") {
    p := Trim(String(prompt))
    if p = ""
        p := "Select an .exe file"
    picked := FileSelect(, , p, "Executable (*.exe)")
    if picked = ""
        return ""
    SplitPath picked, &fn
    return fn
}


FinishOnboardingBridge(jsonStr) {
    global TargetProcess, ZenBrowserExe, SettingsFile, OnboardingNeeded, MainToggleHotkey

    try data := JsonParseSimple(String(jsonStr))
    catch
        return "error"
    tp := Trim(String(data.Has("targetProcess") ? data["targetProcess"] : ""))
    ze := Trim(String(data.Has("zenBrowserExe") ? data["zenBrowserExe"] : ""))
    if tp = "" || ze = ""
        return "error"
    if !RegExMatch(tp, "i)\.exe$")
        tp .= ".exe"
    if !RegExMatch(ze, "i)\.exe$")
        ze .= ".exe"
    TargetProcess := tp
    ZenBrowserExe := ze
    if data.Has("mainToggleHotkey")
        MainToggleHotkey := NormalizeMainToggleSpec(data["mainToggleHotkey"])
    IniWrite TargetProcess, SettingsFile, "Timing", "TargetProcess"
    IniWrite ZenBrowserExe, SettingsFile, "Navi", "ZenExe"
    IniWrite 1, SettingsFile, "Setup", "OnboardingComplete"
    SaveMainToggleToIni()
    OnboardingNeeded := false
    RegisterMainToggleHotkey()
    RegisterAltPassthroughHotkeys()
    RegisterMacroHotkeys()
    UpdateTray()
    PushState()
    return GetStateJSON()
}


ResetOnboardingBridge(*) {
    global SettingsFile, OnboardingNeeded

    IniWrite 0, SettingsFile, "Setup", "OnboardingComplete"
    OnboardingNeeded := true
    PushState()
    return GetStateJSON()
}


IsKeyEnabled(key) {
    global QMacroEnabled, WMacroEnabled, EMacroEnabled, RMacroEnabled
    global ZMacroEnabled, XMacroEnabled, CMacroEnabled, VMacroEnabled

    switch StrUpper(String(key)) {
        case "Q":
            return QMacroEnabled
        case "W":
            return WMacroEnabled
        case "E":
            return EMacroEnabled
        case "R":
            return RMacroEnabled
        case "Z":
            return ZMacroEnabled
        case "X":
            return XMacroEnabled
        case "C":
            return CMacroEnabled
        case "V":
            return VMacroEnabled
    }
    return false
}


StopAllSpam() {
    global QHeld, WHeld, EHeld, RHeld, ZHeld, XHeld, CHeld, VHeld

    QHeld := false
    WHeld := false
    EHeld := false
    RHeld := false
    ZHeld := false
    XHeld := false
    CHeld := false
    VHeld := false
    SetTimer SpamQ, 0
    SetTimer SpamW, 0
    SetTimer SpamE, 0
    SetTimer SpamR, 0
    SetTimer SpamZ, 0
    SetTimer SpamX, 0
    SetTimer SpamC, 0
    SetTimer SpamV, 0
}


StopKeySpam(key) {
    global QHeld, WHeld, EHeld, RHeld, ZHeld, XHeld, CHeld, VHeld

    switch StrUpper(String(key)) {
        case "Q":
            QHeld := false
            SetTimer SpamQ, 0
        case "W":
            WHeld := false
            SetTimer SpamW, 0
        case "E":
            EHeld := false
            SetTimer SpamE, 0
        case "R":
            RHeld := false
            SetTimer SpamR, 0
        case "Z":
            ZHeld := false
            SetTimer SpamZ, 0
        case "X":
            XHeld := false
            SetTimer SpamX, 0
        case "C":
            CHeld := false
            SetTimer SpamC, 0
        case "V":
            VHeld := false
            SetTimer SpamV, 0
    }
}


GetStateJSON() {
    global MacrosEnabled, QMacroEnabled, WMacroEnabled, EMacroEnabled, RMacroEnabled
    global ZMacroEnabled, XMacroEnabled, CMacroEnabled, VMacroEnabled
    global SpamDelay, SpamJitter, EnterConfirmDelay, SpamHoldDelayMs, TargetProcess, KeyBindings
    global ZenBrowserExe, NaviClipboardEnabled, NaviRequireZen, AltPassthroughSpecs, SlotBehaviors
    global OnboardingNeeded, MainToggleHotkey, ElementOverlayEnabled
    global GamePingLastMs, GamePingLastHost
    global ROMacroVersion, RomUpdateAvailable, RomUpdateLatestTag

    s := '{"needsOnboarding":' JsonBool(OnboardingNeeded)
        . ',"appVersion":' EscJSON(ROMacroVersion)
        . ',"updateAvailable":' JsonBool(RomUpdateAvailable)
        . ',"updateLatestTag":' EscJSON(RomUpdateLatestTag)
        . ',"releasesUrl":' EscJSON(RomReleasesLatestUrl())
        . ',"macrosEnabled":' JsonBool(MacrosEnabled)
        . ',"mainToggleHotkey":' EscJSON(MainToggleHotkey)
        . ',"qEnabled":' JsonBool(QMacroEnabled)
        . ',"wEnabled":' JsonBool(WMacroEnabled)
        . ',"eEnabled":' JsonBool(EMacroEnabled)
        . ',"rEnabled":' JsonBool(RMacroEnabled)
        . ',"zEnabled":' JsonBool(ZMacroEnabled)
        . ',"xEnabled":' JsonBool(XMacroEnabled)
        . ',"cEnabled":' JsonBool(CMacroEnabled)
        . ',"vEnabled":' JsonBool(VMacroEnabled)
        . ',"qKey":' EscJSON(KeyBindings["Q"])
        . ',"wKey":' EscJSON(KeyBindings["W"])
        . ',"eKey":' EscJSON(KeyBindings["E"])
        . ',"rKey":' EscJSON(KeyBindings["R"])
        . ',"zKey":' EscJSON(KeyBindings["Z"])
        . ',"xKey":' EscJSON(KeyBindings["X"])
        . ',"cKey":' EscJSON(KeyBindings["C"])
        . ',"vKey":' EscJSON(KeyBindings["V"])
        . ',"qKeyDisplay":' EscJSON(DisplayHotkeyName(KeyBindings["Q"]))
        . ',"wKeyDisplay":' EscJSON(DisplayHotkeyName(KeyBindings["W"]))
        . ',"eKeyDisplay":' EscJSON(DisplayHotkeyName(KeyBindings["E"]))
        . ',"rKeyDisplay":' EscJSON(DisplayHotkeyName(KeyBindings["R"]))
        . ',"zKeyDisplay":' EscJSON(DisplayHotkeyName(KeyBindings["Z"]))
        . ',"xKeyDisplay":' EscJSON(DisplayHotkeyName(KeyBindings["X"]))
        . ',"cKeyDisplay":' EscJSON(DisplayHotkeyName(KeyBindings["C"]))
        . ',"vKeyDisplay":' EscJSON(DisplayHotkeyName(KeyBindings["V"]))
        . ',"spamDelay":' SpamDelay
        . ',"spamJitter":' SpamJitter
        . ',"enterConfirmDelay":' EnterConfirmDelay
        . ',"rConfirmDelay":' EnterConfirmDelay
        . ',"spamHoldDelayMs":' SpamHoldDelayMs
        . ',"targetProcess":' EscJSON(TargetProcess)
        . ',"gamePingMs":' (GamePingLastMs = "" ? "null" : Integer(GamePingLastMs))
        . ',"gamePingHost":' EscJSON(GamePingLastHost = "" ? "" : GamePingLastHost)
        . ',"zenBrowserExe":' EscJSON(ZenBrowserExe)
        . ',"naviClipboardEnabled":' JsonBool(NaviClipboardEnabled)
        . ',"naviRequireZen":' JsonBool(NaviRequireZen)
        . ',"slotModeQ":' EscJSON(SlotBehaviors["Q"])
        . ',"slotModeW":' EscJSON(SlotBehaviors["W"])
        . ',"slotModeE":' EscJSON(SlotBehaviors["E"])
        . ',"slotModeR":' EscJSON(SlotBehaviors["R"])
        . ',"slotModeZ":' EscJSON(SlotBehaviors["Z"])
        . ',"slotModeX":' EscJSON(SlotBehaviors["X"])
        . ',"slotModeC":' EscJSON(SlotBehaviors["C"])
        . ',"slotModeV":' EscJSON(SlotBehaviors["V"])
        . ',"overlayEarth":' JsonBool(ElementOverlayEnabled["Earth"])
        . ',"overlayWind":' JsonBool(ElementOverlayEnabled["Wind"])
        . ',"overlayWater":' JsonBool(ElementOverlayEnabled["Water"])
        . ',"overlayFire":' JsonBool(ElementOverlayEnabled["Fire"])
        . ',"overlayGhost":' JsonBool(ElementOverlayEnabled["Ghost"])
        . ',"overlayShadow":' JsonBool(ElementOverlayEnabled["Shadow"])
        . ',"overlayHoly":' JsonBool(ElementOverlayEnabled["Holy"])
        . ',"altPassthrough":['

    first := true
    for spec in AltPassthroughSpecs {
        if !first
            s .= ","
        first := false
        s .= EscJSON(spec)
    }
    return s "]}"
}


RomReleasesLatestUrl() {
    global ROMacroRepoOwner, ROMacroRepoName
    return "https://github.com/" ROMacroRepoOwner "/" ROMacroRepoName "/releases/latest"
}


RomGitHubApiLatestReleaseUrl() {
    global ROMacroRepoOwner, ROMacroRepoName
    return "https://api.github.com/repos/" ROMacroRepoOwner "/" ROMacroRepoName "/releases/latest"
}


RomNormalizeSemver(s) {
    s := Trim(String(s))
    if RegExMatch(s, "i)^v(.+)$", &m)
        s := m[1]
    if (p := InStr(s, "-"))
        s := SubStr(s, 1, p - 1)
    if (p := InStr(s, "+"))
        s := SubStr(s, 1, p - 1)
    s := Trim(s)
    if !RegExMatch(s, "^(\d+)\.(\d+)\.(\d+)$", &m)
        return { ok: false }
    return { ok: true, major: Integer(m[1]), minor: Integer(m[2]), patch: Integer(m[3]), str: s }
}


RomSemverLess(aStr, bStr) {
    a := RomNormalizeSemver(aStr)
    b := RomNormalizeSemver(bStr)
    if !a.ok || !b.ok
        return false
    if a.major != b.major
        return a.major < b.major
    if a.minor != b.minor
        return a.minor < b.minor
    return a.patch < b.patch
}


RomFetchLatestReleaseTag() {
    global ROMacroVersion
    url := RomGitHubApiLatestReleaseUrl()
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", url, false)
        whr.SetRequestHeader("Accept", "application/vnd.github+json")
        whr.SetRequestHeader("X-GitHub-Api-Version", "2022-11-28")
        whr.SetRequestHeader("User-Agent", "RO-Macro/" ROMacroVersion)
        whr.Send()
        if whr.Status != 200
            return ""
        body := whr.ResponseText
    } catch {
        return ""
    }
    if !RegExMatch(body, '"tag_name"\s*:\s*"([^"]+)"', &m)
        return ""
    return m[1]
}


RomCheckForUpdateNow(notify := false) {
    global ROMacroVersion, RomUpdateAvailable, RomUpdateLatestTag, RomUpdateRemoteVersion
    global RomUpdateCheckInFlight

    if RomUpdateCheckInFlight
        return
    RomUpdateCheckInFlight := true
    try {
        tag := RomFetchLatestReleaseTag()
        RomUpdateLatestTag := tag
        if tag = "" {
            RomUpdateAvailable := false
            RomUpdateRemoteVersion := ""
        } else {
            norm := RomNormalizeSemver(tag)
            cur := RomNormalizeSemver(ROMacroVersion)
            RomUpdateRemoteVersion := norm.ok ? norm.str : ""
            if norm.ok && cur.ok
                RomUpdateAvailable := RomSemverLess(ROMacroVersion, norm.str)
            else
                RomUpdateAvailable := false
        }
    } finally {
        RomUpdateCheckInFlight := false
    }
    RomSyncNativeTitle()
    RomPushUpdateToWeb()
    if notify {
        if RomUpdateAvailable
            TrayTip("RO Macro", "Update available: " RomUpdateLatestTag " — see the HUD title bar or tray → Open GitHub releases.", 6)
        else
            TrayTip("RO Macro", "You are on the latest release (v" ROMacroVersion ").", 4)
    }
}


RomPeriodicUpdateCheck(*) {
    RomCheckForUpdateNow(false)
}


RomPushUpdateToWeb() {
    global WVGui
    if !IsObject(WVGui)
        return
    try WVGui.ExecuteScriptAsync("window.updateState && window.updateState(" GetStateJSON() ");")
    catch {
    }
}


RomSyncNativeTitle() {
    global WVGui, ROMacroVersion, RomUpdateAvailable
    if !IsObject(WVGui)
        return
    try {
        if RomUpdateAvailable
            WVGui.Title := "RO Macro — update available (v" ROMacroVersion ")"
        else
            WVGui.Title := "RO Macro v" ROMacroVersion
    } catch {
    }
}


OpenUrlBridge(url) {
    url := Trim(String(url))
    if !RegExMatch(url, "i)^https?://")
        return "error"
    try Run(url)
    catch {
        return "error"
    }
    return "ok"
}


SetCaptureHotkeyUiBridge(s) {
    global CaptureHotkeyUiActive
    t := Trim(StrLower(String(s)))
    CaptureHotkeyUiActive := (t = "true" || t = "1" || t = "yes")
    return "ok"
}


HotkeySpecWithPassthrough(spec) {
    spec := Trim(String(spec))
    if spec = ""
        return spec
    if SubStr(spec, 1, 1) = "~"
        return spec
    return "~" . spec
}


JsonBool(value) {
    return value ? "true" : "false"
}


EscJSON(value) {
    value := StrReplace(String(value), "\", "\\")
    value := StrReplace(value, '"', '\"')
    value := StrReplace(value, "`n", "\n")
    value := StrReplace(value, "`r", "")
    value := StrReplace(value, "`t", "\t")
    return '"' value '"'
}


WmiProcessIdsForExe(exeName) {
    exeName := StrReplace(Trim(String(exeName)), "'", "''")
    if exeName = ""
        return []
    if !RegExMatch(exeName, "i)\.exe$")
        exeName .= ".exe"
    pids := []
    try {
        wmi := ComObjGet("winmgmts:")
        for o in wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name='" exeName "'")
            pids.Push(o.ProcessId)
    } catch {
    }
    return pids
}


GamePingCollectRemoteIpv4s(pids) {
    if pids.Length = 0
        return []
    script := A_Temp "\ro_macro_tcp_ips.ps1"
    lines := [
        "param([int[]]$ProcessIds)",
        "$ErrorActionPreference = 'SilentlyContinue'",
        "$h = New-Object System.Collections.Generic.HashSet[string]",
        "foreach ($p in $ProcessIds) {",
        "  Get-NetTCPConnection -OwningProcess $p -State Established -ErrorAction SilentlyContinue | ForEach-Object {",
        "    $a = $_.RemoteAddress",
        "    if ($a -match '^::ffff:(\d+\.\d+\.\d+\.\d+)$') { $a = $Matches[1] }",
        "    if ($a -match '^(\d{1,3}\.){3}\d{1,3}$' -and $a -notmatch '^127\.') { [void]$h.Add($a) }",
        "  }",
        "}",
        "$h | ForEach-Object { $_ }",
    ]
    psContent := ""
    for L in lines
        psContent .= L "`n"
    try FileDelete script
    try FileAppend psContent, script, "UTF-8"
    argLine := ""
    for pid in pids
        argLine .= " " Integer(pid)
    outFile := A_Temp "\ro_macro_tcp_ips_out.txt"
    try FileDelete outFile
    ; RunWait + Hide: no visible console (Exec() was stealing focus).
    ps := 'powershell.exe -NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "' script '"' argLine
    try RunWait(A_ComSpec ' /c ' ps ' >"' outFile '" 2>&1', , "Hide")
    catch {
        return []
    }
    try out := FileRead(outFile)
    catch {
        return []
    }
    ips := []
    for line in StrSplit(Trim(out, "`r`n"), "`n", "`r") {
        t := Trim(line)
        if t != "" && RegExMatch(t, "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$")
            ips.Push(t)
    }
    return ips
}


PingMeasureMs(host) {
    host := Trim(String(host))
    if host = ""
        return ""
    outFile := A_Temp "\ro_ping_" A_TickCount "_" Random(1000, 9999) ".txt"
    try FileDelete outFile
    try RunWait(A_ComSpec ' /c ping -n 1 -w 2000 ' host ' >"' outFile '" 2>&1', , "Hide")
    catch
        return ""
    try out := FileRead(outFile)
    catch
        return ""
    if RegExMatch(out, "i)<1ms")
        return 0
    if RegExMatch(out, "i)(?:time|zeit)\s*=\s*(\d+)\s*ms", &m)
        return Integer(m[1])
    return ""
}


RefreshGameServerPing(*) {
    global TargetProcess, GamePingLastMs, GamePingLastHost

    exe := Trim(String(TargetProcess))
    if exe = "" {
        GamePingLastMs := ""
        GamePingLastHost := ""
        PushGamePingToWeb()
        return
    }
    if !RegExMatch(exe, "i)\.exe$")
        exe .= ".exe"

    pids := WmiProcessIdsForExe(exe)
    if pids.Length = 0 {
        GamePingLastMs := ""
        GamePingLastHost := ""
        PushGamePingToWeb()
        return
    }

    ips := GamePingCollectRemoteIpv4s(pids)
    if ips.Length = 0 {
        GamePingLastMs := ""
        GamePingLastHost := ""
        PushGamePingToWeb()
        return
    }

    bestMs := ""
    bestIp := ""
    for ip in ips {
        ms := PingMeasureMs(ip)
        if ms = ""
            continue
        if bestMs = "" || ms < bestMs {
            bestMs := ms
            bestIp := ip
        }
    }

    if bestMs = "" {
        GamePingLastMs := ""
        GamePingLastHost := ips[1]
        PushGamePingToWeb()
        return
    }

    GamePingLastMs := bestMs
    GamePingLastHost := bestIp
    PushGamePingToWeb()
}


PushGamePingToWeb() {
    global WVGui, GamePingLastMs, GamePingLastHost

    if !IsObject(WVGui)
        return
    hostJ := EscJSON(GamePingLastHost = "" ? "" : GamePingLastHost)
    if GamePingLastMs = ""
        js := "window.updateGamePing&&window.updateGamePing(null," hostJ ");"
    else
        js := "window.updateGamePing&&window.updateGamePing(" Integer(GamePingLastMs) "," hostJ ");"
    try WVGui.ExecuteScriptAsync(js)
}


ElementOverlayMeta() {
    return [
        { name: "Earth", num: 1, label: "EART", bg: "6D4C41", fg: "F5E6D3" },
        { name: "Wind", num: 2, label: "WIND", bg: "0EA5E9", fg: "082F49" },
        { name: "Water", num: 3, label: "WATR", bg: "1D4ED8", fg: "E8F1FF" },
        { name: "Fire", num: 4, label: "FIRE", bg: "DC2626", fg: "FEF2F2" },
        { name: "Ghost", num: 5, label: "GHST", bg: "7C3AED", fg: "EDE9FE" },
        { name: "Shadow", num: 6, label: "SHDW", bg: "312E81", fg: "E0E7FF" },
        { name: "Holy", num: 7, label: "HOLY", bg: "CA8A04", fg: "1C1917" }
    ]
}


; Blend RRGGBB toward fg (standard controls have no per-pixel alpha; this approximates a semi-transparent watermark).
ElementOverlayBlendHex(bgRRGGBB, fgRRGGBB, towardFg) {
    out := ""
    Loop 3 {
        b := Integer("0x" SubStr(bgRRGGBB, A_Index * 2 - 1, 2))
        f := Integer("0x" SubStr(fgRRGGBB, A_Index * 2 - 1, 2))
        v := Round(b * (1 - towardFg) + f * towardFg)
        if v > 255
            v := 255
        out .= Format("{:02X}", v)
    }
    return out
}


ElementOverlayAnyEnabled() {
    global ElementOverlayEnabled
    for name in ["Earth", "Wind", "Water", "Fire", "Ghost", "Shadow", "Holy"] {
        if ElementOverlayEnabled[name]
            return true
    }
    return false
}


DestroyElementOverlayGuis() {
    global ElementOverlayGuis
    ElementOverlayStopTopmostTimer()
    for _n, _g in ElementOverlayGuis {
        try _g.Destroy()
    }
    ElementOverlayGuis := Map()
    ElementOverlayPushCoordsToWeb()
}


ElementOverlayCreateGui(def) {
    ; Top-level window on this AutoHotkey process (not a separate .exe). +Border helps DWM paint reliably.
    g := Gui("+AlwaysOnTop -Caption +Border", "RO element — " def.name)
    g.MarginX := 0
    g.MarginY := 0
    g.BackColor := def.bg
    numColor := ElementOverlayBlendHex(def.bg, def.fg, 0.32)
    g.SetFont("s36 bold c" numColor, "Segoe UI")
    g.AddText("x0 y0 w50 h50 Center 0x201 Background" def.bg, String(def.num))
    g.SetFont("s10 bold c" def.fg, "Segoe UI")
    ; Foreground on top; transparent gaps show the large digit. 0x201 = centered; +0x100 = SS_NOTIFY for drag.
    elTxt := g.AddText("x0 y0 w50 h50 Center 0x201 +BackgroundTrans +0x100", def.label)
    elTxt.OnEvent("Click", ElementOverlayStartDrag)
    return g
}


ElementOverlayStartDrag(ctrl, *) {
    PostMessage(0x00A1, 2,,, "ahk_id " ctrl.Gui.Hwnd)
}


ElementOverlayRectTouchesWorkArea(x, y, w := 50, h := 50) {
    cnt := MonitorGetCount()
    Loop cnt {
        MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
        if (x < r && x + w > l && y < b && y + h > t)
            return true
    }
    return false
}


ElementOverlayClampToWork(&x, &y, w := 50, h := 50) {
    cx := x + w // 2
    cy := y + h // 2
    m := 0
    cnt := MonitorGetCount()
    Loop cnt {
        mi := A_Index
        MonitorGetWorkArea(mi, &l, &t, &r, &b)
        if (cx >= l && cx < r && cy >= t && cy < b) {
            m := mi
            break
        }
    }
    if !m
        m := MonitorGetPrimary()
    MonitorGetWorkArea(m, &l, &t, &r, &b)
    if (x < l)
        x := l
    if (y < t)
        y := t
    if (x + w > r)
        x := r - w
    if (y + h > b)
        y := b - h
}


ElementOverlayForceTop(hwnd) {
    static SWP_NOMOVE := 0x0002, SWP_NOSIZE := 0x0001, SWP_NOACTIVATE := 0x0010, SWP_SHOWWINDOW := 0x0040
    flags := SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW
    DllCall("SetWindowPos", "ptr", hwnd, "ptr", -1, "int", 0, "int", 0, "int", 0, "int", 0, "uint", flags)
}


ElementOverlayRaiseAll(*) {
    global ElementOverlayGuis
    for _n, g in ElementOverlayGuis {
        if !IsObject(g)
            continue
        if !DllCall("IsWindowVisible", "ptr", g.Hwnd)
            continue
        try {
            WinSetAlwaysOnTop(1, "ahk_id " g.Hwnd)
            ElementOverlayForceTop(g.Hwnd)
        }
    }
}


ElementOverlayGameIsActive(*) {
    global TargetProcess
    tp := Trim(String(TargetProcess))
    if tp = ""
        return false
    return WinActive("ahk_exe " tp)
}


ElementOverlayReadIniXYRaw(name, &outX, &outY) {
    global SettingsFile
    sx := Trim(IniRead(SettingsFile, "ElementOverlay", name "X", ""))
    sy := Trim(IniRead(SettingsFile, "ElementOverlay", name "Y", ""))
    if sx = "" || sy = ""
        return false
    if !RegExMatch(sx, "^-?\d+$") || !RegExMatch(sy, "^-?\d+$")
        return false
    outX := Integer(sx)
    outY := Integer(sy)
    return true
}


; Show element tiles only while the game client has keyboard focus; hide otherwise.
ElementOverlayApplyGameFocusVisibility() {
    global ElementOverlayGuis
    if ElementOverlayGuis.Count = 0
        return
    if !ElementOverlayGameIsActive() {
        for _n, g in ElementOverlayGuis {
            if IsObject(g)
                try g.Hide()
        }
        return
    }
    for elName, g in ElementOverlayGuis {
        if !IsObject(g)
            continue
        px := unset
        py := unset
        wx := unset
        wy := unset
        try WinGetPos(&wx, &wy,,, "ahk_id " g.Hwnd)
        if IsSet(wx) && IsSet(wy) {
            px := wx
            py := wy
        } else if ElementOverlayReadSavedPos(elName, &sx, &sy) {
            px := sx
            py := sy
        } else if ElementOverlayReadIniXYRaw(elName, &rx, &ry) {
            px := rx
            py := ry
        }
        if IsSet(px) {
            try {
                if !DllCall("IsWindowVisible", "ptr", g.Hwnd)
                    g.Show(Format("x{} y{} w50 h50 NA", px, py))
            }
        }
    }
    ElementOverlayRaiseAll()
}


ElementOverlayStopTopmostTimer() {
    SetTimer ElementOverlayTopmostTimer, 0
}


ElementOverlayTopmostTimer(*) {
    global ElementOverlayGuis
    if !ElementOverlayAnyEnabled() {
        SetTimer ElementOverlayTopmostTimer, 0
        return
    }
    if ElementOverlayGuis.Count = 0 {
        SetTimer ElementOverlayTopmostTimer, 0
        return
    }
    ElementOverlayApplyGameFocusVisibility()
}


ElementOverlayStartTopmostTimer() {
    ; Full-screen upscalers (e.g. Magpie) repeatedly reshuffle the TOPMOST band; re-apply so tiles stay visible.
    SetTimer ElementOverlayTopmostTimer, 0
    SetTimer ElementOverlayTopmostTimer, 80
}


ElementOverlayReadSavedPos(name, &outX, &outY) {
    global SettingsFile
    sx := Trim(IniRead(SettingsFile, "ElementOverlay", name "X", ""))
    sy := Trim(IniRead(SettingsFile, "ElementOverlay", name "Y", ""))
    if sx = "" || sy = ""
        return false
    if !RegExMatch(sx, "^-?\d+$") || !RegExMatch(sy, "^-?\d+$")
        return false
    outX := Integer(sx)
    outY := Integer(sy)
    if !ElementOverlayRectTouchesWorkArea(outX, outY)
        return false
    return true
}


ElementOverlayDefaultPos(stackIdx) {
    global WVGui, HudX, HudY
    gw := 380
    gh := 354
    gx := HudX
    gy := HudY
    if IsObject(WVGui) {
        try {
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " WVGui.Hwnd)
            gx := wx
            gy := wy
            gw := ww
            gh := wh
        }
    }
    x := gx + 10
    y := gy + gh + 8 + stackIdx * 56
    ElementOverlayClampToWork(&x, &y)
    return { x: x, y: y }
}


ElementOverlaySaveCoords(name, g) {
    global SettingsFile
    if !IsObject(g)
        return
    try WinGetPos(&ox, &oy,,, "ahk_id " g.Hwnd)
    catch
        return
    IniWrite ox, SettingsFile, "ElementOverlay", name "X"
    IniWrite oy, SettingsFile, "ElementOverlay", name "Y"
}


ElementOverlayFlushPositions(*) {
    global ElementOverlayGuis
    for _n, _g in ElementOverlayGuis
        ElementOverlaySaveCoords(_n, _g)
    ElementOverlayPushCoordsToWeb()
}


ElementOverlayBuildCoordsJsonForWeb() {
    global ElementOverlayGuis, SettingsFile
    first := true
    s := "{"
    for def in ElementOverlayMeta() {
        nm := def.name
        ox := unset
        oy := unset
        if ElementOverlayGuis.Has(nm) {
            g := ElementOverlayGuis[nm]
            if IsObject(g) {
                try {
                    WinGetPos(&wx, &wy,,, "ahk_id " g.Hwnd)
                    ox := wx
                    oy := wy
                }
            }
        }
        if !IsSet(ox) {
            sx := Trim(IniRead(SettingsFile, "ElementOverlay", nm "X", ""))
            sy := Trim(IniRead(SettingsFile, "ElementOverlay", nm "Y", ""))
            if RegExMatch(sx, "^-?\d+$") && RegExMatch(sy, "^-?\d+$") {
                ox := Integer(sx)
                oy := Integer(sy)
            }
        }
        if !first
            s .= ","
        first := false
        if IsSet(ox)
            s .= '"' nm '":{"x":' ox ',"y":' oy '}'
        else
            s .= '"' nm '":null'
    }
    return s "}"
}


ElementOverlayPushCoordsToWeb() {
    global WVGui
    if !IsObject(WVGui)
        return
    j := ElementOverlayBuildCoordsJsonForWeb()
    try WVGui.ExecuteScriptAsync("window.applyOverlayCoordsFromHost&&window.applyOverlayCoordsFromHost(" j ");")
}


ElementOverlayPushCoordsToWebSoon(*) {
    ElementOverlayPushCoordsToWeb()
}


ElementOverlayOnWinMove(wParam, lParam, msg, hwnd) {
    global ElementOverlayGuis
    for _name, g in ElementOverlayGuis {
        if IsObject(g) && g.Hwnd = hwnd {
            SetTimer ElementOverlayPushCoordsToWebSoon, -45
            SetTimer ElementOverlayFlushPositions, -250
            break
        }
    }
}


GetElementOverlayCoordsJSON(*) {
    return ElementOverlayBuildCoordsJsonForWeb()
}


SetElementOverlayCoordsBridge(jsonStr) {
    global ElementOverlayGuis, SettingsFile

    try data := JsonParseSimple(String(jsonStr))
    catch
        return "error"
    if !data.Has("element") || !data.Has("x") || !data.Has("y")
        return "error"
    el := Trim(String(data["element"]))
    ok := false
    for n in ["Earth", "Wind", "Water", "Fire", "Ghost", "Shadow", "Holy"] {
        if n = el {
            ok := true
            break
        }
    }
    if !ok
        return "error"
    x := Integer(data["x"])
    y := Integer(data["y"])
    ElementOverlayClampToWork(&x, &y, 50, 50)
    IniWrite x, SettingsFile, "ElementOverlay", el "X"
    IniWrite y, SettingsFile, "ElementOverlay", el "Y"
    if ElementOverlayGuis.Has(el) {
        g := ElementOverlayGuis[el]
        if IsObject(g)
            try g.Move(x, y, 50, 50)
    }
    ElementOverlayPushCoordsToWeb()
    return GetStateJSON()
}


SaveElementOverlayIni() {
    global SettingsFile, ElementOverlayEnabled
    for name in ["Earth", "Wind", "Water", "Fire", "Ghost", "Shadow", "Holy"]
        IniWrite ElementOverlayEnabled[name] ? 1 : 0, SettingsFile, "ElementOverlay", name
}


RefreshElementOverlayGuis() {
    global ElementOverlayGuis, ElementOverlayEnabled
    DestroyElementOverlayGuis()
    if !ElementOverlayAnyEnabled()
        return
    stackIdx := 0
    for def in ElementOverlayMeta() {
        if !ElementOverlayEnabled[def.name]
            continue
        g := ElementOverlayCreateGui(def)
        px := 0
        py := 0
        try {
            if ElementOverlayReadSavedPos(def.name, &px, &py) {
                ElementOverlayClampToWork(&px, &py)
                g.Show(Format("x{} y{} w50 h50", px, py))
            } else {
                pos := ElementOverlayDefaultPos(stackIdx)
                stackIdx++
                g.Show(Format("x{} y{} w50 h50", pos.x, pos.y))
            }
        } catch Error as e {
            TrayTip("RO Macro", "Could not show element tile: " e.Message, 6)
            try g.Destroy()
            continue
        }
        try DllCall("ShowWindow", "ptr", g.Hwnd, "int", 8)
        try WinSetAlwaysOnTop(1, "ahk_id " g.Hwnd)
        try ElementOverlayForceTop(g.Hwnd)
        ElementOverlayGuis[def.name] := g
    }
    ElementOverlayStartTopmostTimer()
    ElementOverlayPushCoordsToWeb()
    ElementOverlayApplyGameFocusVisibility()
}


ApplyElementOverlaySettingsFromJson(data) {
    global ElementOverlayEnabled
    pairs := [
        ["overlayEarth", "Earth"],
        ["overlayWind", "Wind"],
        ["overlayWater", "Water"],
        ["overlayFire", "Fire"],
        ["overlayGhost", "Ghost"],
        ["overlayShadow", "Shadow"],
        ["overlayHoly", "Holy"]
    ]
    for pair in pairs {
        if data.Has(pair[1])
            ElementOverlayEnabled[pair[2]] := data[pair[1]] ? true : false
    }
}


SyncElementOverlayTogglesBridge(jsonStr) {
    global ElementOverlayEnabled, SettingsFile

    try data := JsonParseSimple(String(jsonStr))
    catch {
        return "error"
    }
    ApplyElementOverlaySettingsFromJson(data)
    SaveElementOverlayIni()
    RefreshElementOverlayGuis()
    SetTimer(ElementOverlayRaiseAll, -200)
    n := ElementOverlayGuis.Count
    if n > 0
        TrayTip("RO Macro", "Showing " n " element tile(s) (windows on this AutoHotkey process, not a new app).", 4)
    return GetStateJSON()
}


NormalizeHotkeyName(key) {
    key := Trim(String(key))
    if key = ""
        return ""

    lower := StrLower(key)
    if RegExMatch(lower, "^[a-z0-9]$")
        return lower
    if RegExMatch(lower, "^f([1-9]|1[0-2])$")
        return StrUpper(lower)

    aliases := Map(
        " ", "Space",
        "space", "Space",
        "spacebar", "Space",
        "escape", "Esc",
        "esc", "Esc",
        "backspace", "Backspace",
        "tab", "Tab",
        "enter", "Enter",
        "return", "Enter",
        "delete", "Delete",
        "del", "Delete",
        "insert", "Insert",
        "ins", "Insert",
        "home", "Home",
        "end", "End",
        "pageup", "PgUp",
        "pagedown", "PgDn",
        "arrowup", "Up",
        "arrowdown", "Down",
        "arrowleft", "Left",
        "arrowright", "Right",
        "up", "Up",
        "down", "Down",
        "left", "Left",
        "right", "Right"
    )

    if aliases.Has(lower)
        return aliases[lower]

    ; Modifier-only bindings are intentionally rejected.
    return ""
}


LoadHotkeyBinding(slot, defaultKey) {
    global SettingsFile

    key := NormalizeHotkeyName(IniRead(SettingsFile, "Bindings", slot, defaultKey))
    return key = "" ? defaultKey : key
}


DisplayHotkeyName(key) {
    key := String(key)
    return StrLen(key) = 1 ? StrUpper(key) : key
}


IniBool(section, key, defaultValue := false) {
    global SettingsFile

    value := Trim(IniRead(SettingsFile, section, key, defaultValue ? "1" : "0"))
    return value = "1" || value = "true" || value = "on"
}


IniIntTiming(key, defaultValue := 0) {
    global SettingsFile

    v := Trim(IniRead(SettingsFile, "Timing", key, String(defaultValue)))
    return RegExMatch(v, "^\d+$") ? Integer(v) : defaultValue
}


LoadEnterConfirmDelay() {
    global SettingsFile

    v := Trim(IniRead(SettingsFile, "Timing", "EnterConfirmDelay", ""))
    if RegExMatch(v, "^\d+$")
        return Integer(v)
    v2 := Trim(IniRead(SettingsFile, "Timing", "RConfirmDelay", "180"))
    return RegExMatch(v2, "^\d+$") ? Integer(v2) : 180
}


LoadSlotBehavior(slot) {
    global SettingsFile

    def := slot = "R" ? "enter_after" : "spam"
    v := Trim(StrLower(IniRead(SettingsFile, "SlotBehavior", slot, def)))
    if (v = "enter_after" || v = "enter")
        return "enter_after"
    return "spam"
}


SaveSlotBehaviors() {
    global SettingsFile, SlotBehaviors

    for smSlot, mode in SlotBehaviors
        IniWrite mode, SettingsFile, "SlotBehavior", smSlot
}


LoadAltPassthroughSpecs() {
    global SettingsFile

    s := Trim(IniRead(SettingsFile, "AltPassthrough", "Specs", "!e|!q|!z"))
    if s = ""
        s := "!e|!q|!z"
    arr := []
    for part in StrSplit(s, "|") {
        p := Trim(part)
        if p != ""
            arr.Push(p)
    }
    if arr.Length = 0
        arr := ["!e", "!q", "!z"]
    return arr
}


SaveAltPassthroughSpecs() {
    global SettingsFile, AltPassthroughSpecs

    s := ""
    first := true
    for spec in AltPassthroughSpecs {
        spec := Trim(String(spec))
        if spec = ""
            continue
        if !first
            s .= "|"
        first := false
        s .= spec
    }
    if s = ""
        s := "!e|!q|!z"
    IniWrite s, SettingsFile, "AltPassthrough", "Specs"
}


LoadMainToggleHotkey() {
    global SettingsFile

    return NormalizeMainToggleSpec(IniRead(SettingsFile, "HUD", "MainToggleHotkey", "^Down"))
}


NormalizeMainToggleSpec(s) {
    s := Trim(String(s))
    if s = ""
        return "^Down"
    pref := ""
    rest := s
    while StrLen(rest) && InStr("!^+#", SubStr(rest, 1, 1)) {
        pref .= SubStr(rest, 1, 1)
        rest := SubStr(rest, 2)
    }
    rest := Trim(rest)
    if rest = ""
        return "^Down"
    nk := NormalizeHotkeyName(rest)
    if nk = ""
        return "^Down"
    return pref . nk
}


SaveMainToggleToIni() {
    global SettingsFile, MainToggleHotkey

    IniWrite MainToggleHotkey, SettingsFile, "HUD", "MainToggleHotkey"
}


PassthroughSpecBlocksSlot(spec, slotKeyLower) {
    rest := Trim(String(spec))
    if rest = ""
        return false

    wantAlt := false
    wantCtrl := false
    wantShift := false
    wantWin := false

    while SubStr(rest, 1, 1) ~= "[!^+#]" {
        c := SubStr(rest, 1, 1)
        switch c {
            case "!":
                wantAlt := true
            case "^":
                wantCtrl := true
            case "+":
                wantShift := true
            case "#":
                wantWin := true
        }
        rest := SubStr(rest, 2)
    }

    trig := StrLower(NormalizeHotkeyName(Trim(rest)))
    if trig = "" || trig != slotKeyLower
        return false

    if wantAlt && !GetKeyState("Alt", "P")
        return false
    if wantCtrl && !GetKeyState("Ctrl", "P")
        return false
    if wantShift && !GetKeyState("Shift", "P")
        return false
    if wantWin && !GetKeyState("LWin", "P") && !GetKeyState("RWin", "P")
        return false

    return true
}


IsPassthroughComboBlockingSlot(slot) {
    global AltPassthroughSpecs, KeyBindings

    slotKey := StrLower(KeyBindings[slot])
    for spec in AltPassthroughSpecs {
        if PassthroughSpecBlocksSlot(spec, slotKey)
            return true
    }
    return false
}


KeyWaitKeyName(normalizedKey) {
    nk := StrLower(String(normalizedKey))
    if nk = "space"
        return " "
    return normalizedKey
}


AltPassthroughTogglePressed(keyWaitName, *) {
    global MacrosEnabled, CaptureHotkeyUiActive

    if CaptureHotkeyUiActive
        return
    SetMacrosEnabled(!MacrosEnabled)
    KeyWait KeyWaitKeyName(keyWaitName)
}


RegisterAltPassthroughHotkeys() {
    global AltPassthroughSpecs, RegisteredAltHotkeys, MainToggleHotkey

    for item in RegisteredAltHotkeys {
        try Hotkey item["hk"], "Off"
    }
    RegisteredAltHotkeys := []

    mainL := Trim(StrLower(MainToggleHotkey))
    for spec in AltPassthroughSpecs {
        spec := Trim(String(spec))
        if spec = ""
            continue
        if mainL != "" && Trim(StrLower(spec)) = mainL
            continue

        rest := spec
        while SubStr(rest, 1, 1) ~= "[!^+#]"
            rest := SubStr(rest, 2)
        waitKey := NormalizeHotkeyName(Trim(rest))
        if waitKey = ""
            continue

        hk := "~" . spec
        fn := AltPassthroughTogglePressed.Bind(KeyWaitKeyName(waitKey))
        try {
            Hotkey hk, fn, "On"
            RegisteredAltHotkeys.Push({ hk: hk, fn: fn })
        }
    }
}


SaveSettingsBridge(jsonStr) {
    global SpamDelay, SpamJitter, EnterConfirmDelay, SpamHoldDelayMs, TargetProcess
    global ZenBrowserExe, NaviClipboardEnabled, NaviRequireZen, AltPassthroughSpecs, SlotBehaviors
    global MainToggleHotkey, ElementOverlayEnabled

    try data := JsonParseSimple(String(jsonStr))
    catch
        return "error"

    SpamDelay := Max(10, ToIntSafe(data, "spamDelay", SpamDelay))
    SpamJitter := Max(0, ToIntSafe(data, "spamJitter", SpamJitter))
    if data.Has("enterConfirmDelay")
        EnterConfirmDelay := Max(0, ToIntSafe(data, "enterConfirmDelay", EnterConfirmDelay))
    else if data.Has("rConfirmDelay")
        EnterConfirmDelay := Max(0, ToIntSafe(data, "rConfirmDelay", EnterConfirmDelay))
    SpamHoldDelayMs := Max(0, ToIntSafe(data, "spamHoldDelayMs", SpamHoldDelayMs))

    tp := Trim(String(data.Has("targetProcess") ? data["targetProcess"] : TargetProcess))
    if tp != ""
        TargetProcess := tp

    ze := Trim(String(data.Has("zenBrowserExe") ? data["zenBrowserExe"] : ZenBrowserExe))
    if ze != ""
        ZenBrowserExe := ze

    if data.Has("naviClipboardEnabled")
        NaviClipboardEnabled := data["naviClipboardEnabled"] ? true : false
    if data.Has("naviRequireZen")
        NaviRequireZen := data["naviRequireZen"] ? true : false

    newSpecs := []
    if data.Has("altPassthrough") && data["altPassthrough"] is Array {
        for spec in data["altPassthrough"] {
            t := Trim(String(spec))
            if t != ""
                newSpecs.Push(t)
        }
    }
    if newSpecs.Length = 0
        newSpecs := ["!e", "!q", "!z"]
    if data.Has("mainToggleHotkey")
        MainToggleHotkey := NormalizeMainToggleSpec(data["mainToggleHotkey"])
    mainL := Trim(StrLower(MainToggleHotkey))
    seen := Map()
    filtered := []
    for spec in newSpecs {
        t := Trim(String(spec))
        if t = "" || seen.Has(t)
            continue
        if mainL != "" && StrLower(t) = mainL
            continue
        seen[t] := true
        filtered.Push(t)
    }
    if filtered.Length = 0 {
        for spec in ["!e", "!q", "!z"] {
            t := Trim(String(spec))
            if mainL != "" && StrLower(t) = mainL
                continue
            filtered.Push(t)
        }
    }
    if filtered.Length = 0
        filtered.Push("!e")
    AltPassthroughSpecs := filtered

    for smSlot in ["Q", "W", "E", "R", "Z", "X", "C", "V"] {
        mk := "slotMode" . smSlot
        if data.Has(mk) {
            mv := Trim(StrLower(String(data[mk])))
            SlotBehaviors[smSlot] := (mv = "enter_after" || mv = "enter") ? "enter_after" : "spam"
        }
    }

    ApplyElementOverlaySettingsFromJson(data)
    SaveElementOverlayIni()

    SaveTimingToIni()
    SaveMainToggleToIni()
    SaveAltPassthroughSpecs()
    SaveSlotBehaviors()
    SaveNaviState()
    RegisterMainToggleHotkey()
    RegisterAltPassthroughHotkeys()
    RegisterMacroHotkeys()
    UpdateTray()
    PushState()
    RefreshElementOverlayGuis()
    SetTimer(ElementOverlayRaiseAll, -250)
    SetTimer(RefreshGameServerPing, -500)
    return GetStateJSON()
}


ToIntSafe(data, key, def) {
    if !data.Has(key)
        return def
    v := data[key]
    v := Trim(String(v))
    return RegExMatch(v, "^-?\d+$") ? Integer(v) : def
}


JsonUnescape(s) {
    out := ""
    i := 1
    L := StrLen(s)
    while i <= L {
        c := SubStr(s, i, 1)
        if c = "\" && i < L {
            n := SubStr(s, i + 1, 1)
            if n = '"'
                out .= '"', i += 2
            else if n = "\"
                out .= "\", i += 2
            else {
                out .= c
                i += 1
            }
        } else {
            out .= c
            i += 1
        }
    }
    return out
}


JsonParseSimple(json) {
    ; Parse JSON from JS JSON.stringify: string keys, string/number/boolean values, altPassthrough string[].
    o := Map()
    json := Trim(json)
    if SubStr(json, 1, 1) != "{" || SubStr(json, -1) != "}"
        throw Error("bad json")

    pos := 2
    len := StrLen(json)
    while pos <= len {
        while pos <= len && InStr(" `t`r`n", SubStr(json, pos, 1))
            pos += 1
        if pos > len || SubStr(json, pos, 1) = "}"
            break
        if SubStr(json, pos, 1) != '"'
            throw Error("bad json key")
        pos += 1
        ks := pos
        while pos <= len {
            ch := SubStr(json, pos, 1)
            if ch = "\" {
                pos += 2
                continue
            }
            if ch = '"' {
                break
            }
            pos += 1
        }
        key := SubStr(json, ks, pos - ks)
        pos += 1
        while pos <= len && InStr(" `t`r`n", SubStr(json, pos, 1))
            pos += 1
        if SubStr(json, pos, 1) != ":"
            throw Error("bad json")
        pos += 1
        while pos <= len && InStr(" `t`r`n", SubStr(json, pos, 1))
            pos += 1

        if key = "altPassthrough" {
            if SubStr(json, pos, 1) != "["
                throw Error("bad altPassthrough")
            pos += 1
            o["altPassthrough"] := []
            while pos <= len {
                while pos <= len && InStr(" `t`r`n,", SubStr(json, pos, 1))
                    pos += 1
                if SubStr(json, pos, 1) = "]" {
                    pos += 1
                    break
                }
                if SubStr(json, pos, 1) != '"'
                    throw Error("bad altPassthrough elem")
                pos += 1
                es := pos
                while pos <= len {
                    ch := SubStr(json, pos, 1)
                    if ch = "\" {
                        pos += 2
                        continue
                    }
                    if ch = '"'
                        break
                    pos += 1
                }
                elem := SubStr(json, es, pos - es)
                pos += 1
                o["altPassthrough"].Push(JsonUnescape(elem))
            }
            while pos <= len && InStr(" `t`r`n,", SubStr(json, pos, 1))
                pos += 1
            continue
        }

        ch0 := SubStr(json, pos, 1)
        if ch0 = '"' {
            pos += 1
            vs := pos
            while pos <= len {
                ch := SubStr(json, pos, 1)
                if ch = "\" {
                    pos += 2
                    continue
                }
                if ch = '"'
                    break
                pos += 1
            }
            val := SubStr(json, vs, pos - vs)
            pos += 1
            o[key] := JsonUnescape(val)
        } else if RegExMatch(SubStr(json, pos), "^(true|false)", &mb) {
            o[key] := mb[1] = "true"
            pos += StrLen(mb[0])
        } else if RegExMatch(SubStr(json, pos), "^(-?\d+)", &mn) {
            o[key] := Integer(mn[1])
            pos += StrLen(mn[0])
        } else
            throw Error("bad json value")

        while pos <= len && InStr(" `t`r`n,", SubStr(json, pos, 1))
            pos += 1
    }

    if !o.Has("altPassthrough")
        o["altPassthrough"] := ["!e", "!q", "!z"]
    return o
}


SaveTimingToIni() {
    global SettingsFile, SpamDelay, SpamJitter, EnterConfirmDelay, SpamHoldDelayMs, TargetProcess

    IniWrite SpamDelay, SettingsFile, "Timing", "SpamDelay"
    IniWrite SpamJitter, SettingsFile, "Timing", "SpamJitter"
    IniWrite EnterConfirmDelay, SettingsFile, "Timing", "EnterConfirmDelay"
    IniWrite SpamHoldDelayMs, SettingsFile, "Timing", "SpamHoldDelayMs"
    IniWrite TargetProcess, SettingsFile, "Timing", "TargetProcess"
}


SaveState() {
    global SettingsFile, MacrosEnabled, QMacroEnabled, WMacroEnabled, EMacroEnabled, RMacroEnabled
    global ZMacroEnabled, XMacroEnabled, CMacroEnabled, VMacroEnabled, KeyBindings

    IniWrite MacrosEnabled ? 1 : 0, SettingsFile, "State", "MacrosEnabled"
    IniWrite QMacroEnabled ? 1 : 0, SettingsFile, "State", "QEnabled"
    IniWrite WMacroEnabled ? 1 : 0, SettingsFile, "State", "WEnabled"
    IniWrite EMacroEnabled ? 1 : 0, SettingsFile, "State", "EEnabled"
    IniWrite RMacroEnabled ? 1 : 0, SettingsFile, "State", "REnabled"
    IniWrite ZMacroEnabled ? 1 : 0, SettingsFile, "State", "ZEnabled"
    IniWrite XMacroEnabled ? 1 : 0, SettingsFile, "State", "XEnabled"
    IniWrite CMacroEnabled ? 1 : 0, SettingsFile, "State", "CEnabled"
    IniWrite VMacroEnabled ? 1 : 0, SettingsFile, "State", "VEnabled"
    IniWrite KeyBindings["Q"], SettingsFile, "Bindings", "Q"
    IniWrite KeyBindings["W"], SettingsFile, "Bindings", "W"
    IniWrite KeyBindings["E"], SettingsFile, "Bindings", "E"
    IniWrite KeyBindings["R"], SettingsFile, "Bindings", "R"
    IniWrite KeyBindings["Z"], SettingsFile, "Bindings", "Z"
    IniWrite KeyBindings["X"], SettingsFile, "Bindings", "X"
    IniWrite KeyBindings["C"], SettingsFile, "Bindings", "C"
    IniWrite KeyBindings["V"], SettingsFile, "Bindings", "V"
    SaveTimingToIni()
    SaveAltPassthroughSpecs()
    SaveSlotBehaviors()
}


SaveNaviState() {
    global SettingsFile, NaviClipboardEnabled, NaviRequireZen, ZenBrowserExe

    IniWrite NaviClipboardEnabled ? 1 : 0, SettingsFile, "Navi", "Enabled"
    IniWrite NaviRequireZen ? 1 : 0, SettingsFile, "Navi", "RequireZen"
    IniWrite ZenBrowserExe, SettingsFile, "Navi", "ZenExe"
}


PushState() {
    global WVGui

    try WVGui.ExecuteScriptAsync("window.updateState && window.updateState(" GetStateJSON() ");")
}


GetRandomDelay(BaseDelay) {
    global SpamJitter

    offset := Random(-SpamJitter, SpamJitter)
    delay := BaseDelay + offset

    if delay < 10
        delay := 10

    return delay
}


SaveHudPosition(*) {
    global WVGui, SettingsFile, HudX, HudY

    if !IsObject(WVGui)
        return

    try {
        WinGetPos &x, &y,,, "ahk_id " WVGui.Hwnd
        if (x != "" && y != "") {
            HudX := x
            HudY := y
            IniWrite x, SettingsFile, "HUD", "X"
            IniWrite y, SettingsFile, "HUD", "Y"
        }
    }
}


ExitSub(ExitReason, ExitCode) {
    global ElementOverlayGuis
    ElementOverlayStopTopmostTimer()
    for _n, _g in ElementOverlayGuis
        ElementOverlaySaveCoords(_n, _g)
    DestroyElementOverlayGuis()
    SaveState()
    SaveNaviState()
    SaveHudPosition()
}


BuildWebGui() {
    global WVGui, HudX, HudY, ROMacroVersion
    indexHtml := "
    (
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
:root {
  --void: #0c0c0e;
  --bar: #151517;
  --btn: #191919;
  --btn-hi: #222222;
  --btn-lo: #161616;
  --line: #2c2c30;
  --line-soft: #242428;
  --text: #f4f4f5;
  --muted: #a1a1aa;
  --dim: #71717a;
  --accent: #4ade80;
  --accent-dim: rgba(74, 222, 128, 0.2);
  --danger: #fb7185;
  --pill: #191919;
  --pill-hi: #1e1e1e;
  --pill-r: 4px;
  --radius: 4px;
  --radius-sm: 2px;
  --seg-pad-x: 9px;
  --seg-pad-y: 5px;
  --scroll-track: #151517;
  --scroll-thumb: #3f3f46;
  --scroll-thumb-hover: #52525c;
  --scroll-thumb-active: #63636f;
}
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
  scrollbar-width: thin;
  scrollbar-color: var(--scroll-thumb) var(--scroll-track);
}
*::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}
*::-webkit-scrollbar-corner {
  background: var(--scroll-track);
}
*::-webkit-scrollbar-track {
  background: var(--scroll-track);
  border-radius: var(--radius-sm);
}
*::-webkit-scrollbar-thumb {
  background: var(--scroll-thumb);
  border-radius: var(--radius-sm);
  border: 2px solid var(--scroll-track);
}
*::-webkit-scrollbar-thumb:hover {
  background: var(--scroll-thumb-hover);
}
*::-webkit-scrollbar-thumb:active {
  background: var(--scroll-thumb-active);
}
html, body {
  width: 100%;
  height: 100%;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: hidden;
  color-scheme: dark;
  background: transparent;
  color: var(--text);
  font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
  font-size: 12px;
  -webkit-font-smoothing: antialiased;
  user-select: none;
  -webkit-user-select: none;
}
body {
  background: var(--void);
  border: 1px solid var(--line);
  display: flex;
  flex-direction: column;
}
button.btn-primary:focus:not(:focus-visible),
button.window-btn:focus:not(:focus-visible),
.ob-footer button.btn-primary:focus:not(:focus-visible),
button.btn-cap:focus:not(:focus-visible) {
  outline: none;
  box-shadow: none;
}
.key-btn:focus,
.key-btn:focus-visible {
  outline: none;
  box-shadow: none;
}
button.macro-main-switch:focus:not(:focus-visible),
button.slot-mode-switch:focus:not(:focus-visible) {
  outline: none;
}
input[type="text"],
input[type="number"],
input[type="search"],
input[type="email"],
input[type="url"],
textarea {
  user-select: text;
  -webkit-user-select: text;
}
body.enabled .status-hero {
  border-color: rgba(74, 222, 128, 0.35);
  box-shadow: 0 0 0 1px rgba(74, 222, 128, 0.12);
}
body.macros-off .status-hero {
  border-color: rgba(251, 113, 133, 0.38);
  box-shadow: 0 0 0 1px rgba(251, 113, 133, 0.1);
}
.status-hero {
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: var(--btn);
  padding: 10px 14px 10px;
  flex-shrink: 0;
}
.status-hero-main {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 14px;
}
.status-hero-copy { min-width: 0; }
.status-eyebrow {
  color: var(--dim);
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
}
.status-big {
  margin-top: 4px;
  font-size: 28px;
  font-weight: 800;
  line-height: 1.05;
  letter-spacing: -0.02em;
  color: var(--text);
  transition: color 0.2s ease, text-shadow 0.2s ease;
}
body.enabled .status-big {
  color: var(--accent);
  text-shadow:
    0 0 12px rgba(74, 222, 128, 0.55),
    0 0 28px rgba(74, 222, 128, 0.28),
    0 0 42px rgba(74, 222, 128, 0.12);
}
body.macros-off .status-big {
  color: var(--danger);
  text-shadow:
    0 0 12px rgba(251, 113, 133, 0.45),
    0 0 26px rgba(251, 113, 133, 0.22),
    0 0 40px rgba(251, 113, 133, 0.1);
}
.status-target {
  margin-top: 5px;
  font-size: 12px;
  font-weight: 500;
  color: var(--muted);
}
.status-ping-hint {
  margin-top: 2px;
  font-size: 11px;
  color: var(--dim);
}
.macro-main-switch {
  position: relative;
  flex-shrink: 0;
  width: 92px;
  height: 34px;
  padding: 3px;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: var(--btn-lo);
  cursor: pointer;
  -webkit-app-region: no-drag;
  box-sizing: border-box;
  transition: border-color 0.22s ease, box-shadow 0.22s ease;
  -webkit-tap-highlight-color: transparent;
}
.macro-main-switch:focus,
.macro-main-switch:focus-visible {
  outline: none;
}
.macro-main-switch.is-on {
  border-color: rgba(74, 222, 128, 0.75);
  box-shadow:
    0 0 10px rgba(74, 222, 128, 0.4),
    0 0 22px rgba(74, 222, 128, 0.22),
    0 0 36px rgba(74, 222, 128, 0.1);
}
.macro-main-switch.is-off {
  border-color: rgba(251, 113, 133, 0.72);
  box-shadow:
    0 0 10px rgba(251, 113, 133, 0.35),
    0 0 22px rgba(251, 113, 133, 0.18),
    0 0 34px rgba(251, 113, 133, 0.08);
}
.macro-main-switch .switch-hit {
  position: absolute;
  top: 3px;
  bottom: 3px;
  width: calc(50% - 2px);
  z-index: 4;
  pointer-events: auto;
  transition: background 0.14s ease;
}
.macro-main-switch .switch-hit-left {
  left: 3px;
  border-radius: var(--radius-sm) 0 0 var(--radius-sm);
}
.macro-main-switch .switch-hit-right {
  right: 3px;
  border-radius: 0 var(--radius-sm) var(--radius-sm) 0;
}
.macro-main-switch .switch-hit-left:hover,
.macro-main-switch .switch-hit-right:hover {
  background: rgba(244, 244, 245, 0.07);
}
.macro-switch-thumb {
  position: absolute;
  top: 3px;
  bottom: 3px;
  width: calc(50% - 4px);
  left: 3px;
  border-radius: var(--radius-sm);
  z-index: 0;
  transition: left 0.22s cubic-bezier(0.4, 0, 0.2, 1), background 0.22s ease, box-shadow 0.22s ease;
}
.macro-main-switch.is-on .macro-switch-thumb {
  left: 3px;
  background: rgba(74, 222, 128, 0.32);
  box-shadow: 0 0 0 1px rgba(74, 222, 128, 0.45);
}
.macro-main-switch.is-off .macro-switch-thumb {
  left: calc(50% + 1px);
  background: rgba(251, 113, 133, 0.28);
  box-shadow: 0 0 0 1px rgba(251, 113, 133, 0.42);
}
.macro-switch-words {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: stretch;
  z-index: 1;
  pointer-events: none;
}
.macro-switch-word {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 11px;
  font-weight: 800;
  letter-spacing: 0.12em;
  transition: color 0.18s ease;
}
.macro-main-switch.is-on .macro-sw-on {
  color: var(--accent);
}
.macro-main-switch.is-on .macro-sw-off {
  color: var(--dim);
}
.macro-main-switch.is-off .macro-sw-off {
  color: var(--danger);
}
.macro-main-switch.is-off .macro-sw-on {
  color: var(--dim);
}
.titlebar {
  flex-shrink: 0;
  position: relative;
  height: 34px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 8px 0 10px;
  background: var(--bar);
  border-bottom: 1px solid var(--line);
  user-select: none;
  -webkit-app-region: drag;
}
.titlebar-brand {
  flex: 1;
  min-width: 0;
  display: flex;
  align-items: baseline;
  flex-wrap: nowrap;
  gap: 4px;
  padding: 0 64px 0 0;
  overflow: hidden;
}
.titlebar-title {
  flex: 0 0 auto;
  text-align: left;
  font-size: 13px;
  font-weight: 600;
  letter-spacing: 0.02em;
  color: var(--text);
  padding: 0;
}
.titlebar-meta {
  flex: 0 1 auto;
  min-width: 0;
  font-size: 12px;
  font-weight: 500;
  color: var(--dim);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.titlebar-meta .tm-ver {
  color: var(--dim);
  font-weight: 500;
}
.titlebar-meta .tm-sep {
  color: var(--dim);
  margin: 0 2px;
  font-weight: 400;
}
.titlebar-meta .tm-upd {
  color: var(--accent);
  cursor: pointer;
  font-weight: 700;
  text-decoration: underline;
  text-underline-offset: 2px;
}
.update-prompt {
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: nowrap;
  padding: 6px 10px 7px;
  background: rgba(74, 222, 128, 0.1);
  border-bottom: 1px solid rgba(74, 222, 128, 0.28);
  font-size: 11px;
  color: var(--text);
  min-height: 0;
}
.update-prompt.hidden {
  display: none !important;
}
.update-prompt-msg {
  flex: 1 1 auto;
  min-width: 0;
  line-height: 1.35;
}
.update-prompt-actions {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 4px;
}
.update-prompt-btn {
  font-size: 11px !important;
  padding: 4px 10px !important;
  min-height: 0;
}
.update-prompt-x {
  font-family: "Segoe UI", system-ui, sans-serif !important;
  font-size: 14px !important;
  line-height: 1;
  padding: 0 6px !important;
}
.titlebar-win {
  -webkit-app-region: no-drag;
  display: flex;
  align-items: center;
  gap: 2px;
  position: absolute;
  right: 6px;
  top: 50%;
  transform: translateY(-50%);
}
.window-btn {
  width: 28px;
  height: 26px;
  border: 0;
  border-radius: var(--radius-sm);
  color: var(--muted);
  background: transparent;
  cursor: pointer;
  font-family: Webdings;
  font-size: 10pt;
  transition: background 0.12s, color 0.12s;
}
.window-btn:hover { background: var(--btn-hi); color: var(--text); }
.window-btn.close:hover { background: rgba(251, 113, 133, 0.9); color: #0c0c0e; }
.window-btn.restart-btn {
  font-family: "Segoe UI Symbol", "Segoe UI", system-ui, sans-serif;
  font-size: 15px;
  line-height: 1;
}
.window-btn.restart-btn:hover { color: var(--accent); }
.shell {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: hidden;
}
.shell-pane {
  flex: 1 1 auto;
  min-height: 0;
  overflow: visible;
  display: flex;
  flex-direction: column;
}
#viewMain:not(.hidden) {
  overflow-y: auto;
}
#viewOnboarding:not(.hidden) {
  overflow-y: hidden;
}
.shell-pane.hidden {
  display: none !important;
}
.wrap {
  flex: 0 0 auto;
  padding: 8px 10px 10px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-height: 0;
}
/* Onboarding shares .wrap but must fill the shell height so lists scroll inside the carousel, not off-window */
.wrap.ob-wrap {
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
}
#viewMain {
  padding-top: 10px;
}
.row {
  display: flex;
  align-items: stretch;
  gap: 6px;
}
.pill {
  display: flex;
  align-items: stretch;
  flex: 1;
  min-width: 0;
  border: 1px solid var(--line);
  border-radius: var(--pill-r);
  background: var(--pill);
  overflow: hidden;
}
.pill-grow { flex: 1.35; }
.seg {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: var(--seg-pad-y) var(--seg-pad-x);
  color: var(--text);
  font-size: 11px;
  font-weight: 500;
  border-right: 1px solid var(--line-soft);
  background: var(--btn);
  min-width: 0;
}
.seg:last-child { border-right: none; }
.seg.shrink { flex: 0 0 auto; }
.seg.grow {
  flex: 1;
  justify-content: flex-start;
  font-weight: 600;
  font-size: 12px;
}
.seg.muted {
  color: var(--muted);
  font-size: 10px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}
.seg.mono {
  font-variant-numeric: tabular-nums;
  font-size: 10px;
  font-weight: 600;
  color: var(--muted);
  padding-left: 8px;
  padding-right: 8px;
}
.key-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 5px;
}
.key-btn {
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 0;
  color: var(--text);
  background: var(--btn-lo);
  cursor: default;
  font-family: inherit;
  overflow: hidden;
  transition: border-color 0.12s, background 0.12s;
  -webkit-tap-highlight-color: transparent;
}
.key-btn.listening {
  border-color: rgba(96, 165, 250, 0.55);
  background: #1a222e;
}
.key-btn .key {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 22px;
  padding: 5px 5px 4px;
  font-size: 15px;
  font-weight: 700;
  line-height: 1;
  cursor: pointer;
  background: transparent;
  transition: background 0.12s ease, box-shadow 0.12s ease, color 0.12s ease;
}
.key-btn .label {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 18px;
  padding: 3px 6px 4px;
  background: transparent;
  border-top: 1px solid var(--line-soft);
  color: var(--dim);
  font-size: 9px;
  font-weight: 700;
  letter-spacing: 0.07em;
  text-transform: uppercase;
  cursor: pointer;
  transition: background 0.12s ease, box-shadow 0.12s ease, color 0.12s ease;
}
.key-btn:not(.listening) .key:hover {
  background: var(--btn-hi);
  box-shadow: inset 0 0 0 1px rgba(113, 113, 122, 0.55);
}
.key-btn:not(.listening) .label:hover {
  background: var(--btn-hi);
  box-shadow: inset 0 0 0 1px rgba(113, 113, 122, 0.55);
}
.key-btn.listening .key:hover,
.key-btn.listening .label:hover {
  background: rgba(96, 165, 250, 0.14);
  box-shadow: inset 0 0 0 1px rgba(96, 165, 250, 0.35);
}
.key-btn.active .label { color: var(--accent); }
.key-btn.off .label { color: var(--danger); }
.key-btn.off .key { color: var(--muted); }
.timing-row .seg.label {
  color: var(--muted);
  font-size: 10px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}
.timing-row .seg.val {
  font-variant-numeric: tabular-nums;
  font-weight: 600;
  color: var(--text);
}
.timing-row .pill .seg.shrink {
  flex: 1 1 0%;
  min-width: 0;
}
.timing-row .pill {
  align-items: center;
}
.timing-row .pill .seg {
  position: relative;
  padding: 3px 4px;
  justify-content: center;
  text-align: center;
  border-right: none;
}
/* Short tick between label (header) and value within one metric */
.timing-row .pill .seg.label::after {
  content: '';
  position: absolute;
  right: 0;
  top: 50%;
  transform: translateY(-50%);
  height: 50%;
  border-right: 1px solid rgba(255, 255, 255, 0.14);
  pointer-events: none;
}
/* Full-height rule after each value (between metric groups) */
.timing-row .pill .seg.val:not(:last-child)::after {
  content: '';
  position: absolute;
  right: 0;
  top: 0;
  bottom: 0;
  border-right: 1px solid rgba(255, 255, 255, 0.14);
  pointer-events: none;
}
.settings-btn {
  font-family: 'Segoe UI', 'Segoe UI Symbol', system-ui, sans-serif;
  font-size: 15px;
  line-height: 1;
}
.settings-field label {
  display: block;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--dim);
  margin-bottom: 2px;
}
.settings-field input[type="text"],
.settings-field input[type="number"] {
  width: 100%;
  box-sizing: border-box;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 6px 9px;
  background: var(--btn);
  color: var(--text);
  font: inherit;
  outline: none;
  color-scheme: dark;
}
.settings-field input[type="number"]::-webkit-inner-spin-button,
.settings-field input[type="number"]::-webkit-outer-spin-button {
  -webkit-appearance: inner-spin-button;
  cursor: pointer;
  height: 1.4em;
  margin: 0;
  opacity: 1;
}
.settings-field .help {
  margin-top: 3px;
  font-size: 10px;
  color: var(--dim);
  line-height: 1.35;
}
.slot-mode-grid {
  display: grid;
  grid-template-columns: 18px 92px 18px 92px;
  gap: 8px 12px;
  align-items: center;
  margin-top: 4px;
}
.slot-mode-grid > span {
  font-size: 10px;
  font-weight: 700;
  color: var(--muted);
  text-align: right;
}
.slot-mode-switch {
  position: relative;
  width: 92px;
  height: 34px;
  padding: 6px;
  border: 1px solid var(--line);
  border-radius: var(--radius-sm);
  background: var(--btn-lo);
  cursor: pointer;
  box-sizing: border-box;
  transition: border-color 0.22s ease;
  -webkit-tap-highlight-color: transparent;
}
.slot-mode-switch:focus,
.slot-mode-switch:focus-visible {
  outline: none;
}
.slot-mode-switch.is-spam,
.slot-mode-switch.is-enter {
  border-color: rgba(113, 113, 122, 0.55);
}
.slot-mode-switch .slot-switch-thumb {
  position: absolute;
  top: 6px;
  bottom: 6px;
  width: calc(50% - 9px);
  left: 6px;
  border-radius: 2px;
  z-index: 0;
  transition: left 0.22s cubic-bezier(0.4, 0, 0.2, 1), background 0.22s ease;
}
.slot-mode-switch.is-spam .slot-switch-thumb {
  left: 6px;
  background: rgba(63, 63, 70, 0.85);
}
.slot-mode-switch.is-enter .slot-switch-thumb {
  left: calc(50% + 1px);
  background: rgba(63, 63, 70, 0.85);
}
.slot-mode-switch .slot-switch-words {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: stretch;
  z-index: 1;
  pointer-events: none;
}
.slot-mode-switch .slot-switch-word {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 9px;
  font-weight: 800;
  letter-spacing: 0.06em;
  transition: color 0.18s ease;
}
.slot-mode-switch .slot-sw-spam {
  padding-left: 4px;
}
.slot-mode-switch .slot-sw-enter {
  padding-right: 4px;
}
.slot-mode-switch.is-spam .slot-sw-spam {
  color: var(--text);
}
.slot-mode-switch.is-spam .slot-sw-enter {
  color: var(--dim);
}
.slot-mode-switch.is-enter .slot-sw-enter {
  color: var(--text);
}
.slot-mode-switch.is-enter .slot-sw-spam {
  color: var(--dim);
}
.slot-mode-switch .switch-hit {
  position: absolute;
  top: 6px;
  bottom: 6px;
  width: calc(50% - 3px);
  z-index: 4;
  pointer-events: auto;
  transition: background 0.14s ease;
}
.slot-mode-switch .switch-hit-left {
  left: 6px;
  border-radius: 2px 0 0 2px;
}
.slot-mode-switch .switch-hit-right {
  right: 6px;
  border-radius: 0 2px 2px 0;
}
.slot-mode-switch .switch-hit-left:hover,
.slot-mode-switch .switch-hit-right:hover {
  background: rgba(244, 244, 245, 0.07);
}
.settings-row2 {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
}
.alt-spec-row {
  display: flex;
  gap: 8px;
  align-items: center;
}
.alt-spec-ahk {
  display: none;
}
.alt-spec-kbd-host {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 6px;
}
.alt-spec-row .alt-spec-set,
.alt-spec-row .alt-spec-rm {
  flex-shrink: 0;
  border: 1px solid var(--line);
  border-radius: var(--radius-sm);
  padding: 6px 10px;
  background: var(--btn-lo);
  color: var(--muted);
  font: inherit;
  font-size: 11px;
  font-weight: 600;
  cursor: pointer;
}
.alt-spec-row .alt-spec-set:hover {
  color: var(--accent);
  border-color: rgba(74, 222, 128, 0.45);
}
.alt-spec-row .alt-spec-rm:hover {
  color: var(--danger);
  border-color: rgba(251, 113, 133, 0.45);
}
.alt-spec-row .alt-spec-set:focus,
.alt-spec-row .alt-spec-rm:focus,
.alt-spec-row .alt-spec-set:focus-visible,
.alt-spec-row .alt-spec-rm:focus-visible {
  outline: none;
}
.kbd-chip {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 1.5em;
  padding: 3px 8px;
  border-radius: 5px;
  border: 1px solid var(--line);
  background: var(--btn-lo);
  color: var(--text);
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.04em;
}
.kbd-chip--sm {
  padding: 2px 6px;
  font-size: 10px;
  border-radius: 4px;
}
.kbd-plus {
  color: var(--dim);
  font-size: 11px;
  font-weight: 700;
  user-select: none;
}
.kbd-muted {
  color: var(--dim);
  font-size: 12px;
}
.alt-pill-kbd .kbd-chip--sm {
  margin: 0;
}
#obMainToggleKbdHost.ob-main-toggle-preview,
#setMainToggleKbdHost {
  display: inline-flex;
  flex-direction: row;
  flex-wrap: nowrap;
  align-items: center;
  gap: 0;
}
.ob-main-toggle-row {
  display: flex;
  flex-direction: row;
  align-items: stretch;
  gap: 10px;
  width: 100%;
  box-sizing: border-box;
  margin-bottom: 10px;
  min-width: 0;
}
.ob-main-toggle-row #obMainToggleKbdHost.ob-main-toggle-preview {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: row;
  flex-wrap: nowrap;
  align-items: center;
  justify-content: center;
  gap: 6px;
  padding: 10px 14px;
  box-sizing: border-box;
  border: 1px solid rgba(74, 222, 128, 0.45);
  border-radius: var(--radius);
  background: var(--accent-dim);
}
.ob-main-toggle-row #obMainToggleKbdHost .kbd-chip.kbd-chip--sm {
  padding: 6px 10px;
  font-size: 12px;
  font-weight: 700;
  border-radius: var(--radius-sm);
}
.ob-main-toggle-row #obMainToggleKbdHost .kbd-plus {
  font-size: 12px;
  font-weight: 700;
  padding: 0 2px;
  color: var(--accent);
}
.ob-main-toggle-row > .btn-primary {
  flex: 0 0 auto;
  align-self: stretch;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  white-space: nowrap;
}
.modal-cap {
  position: fixed;
  inset: 0;
  z-index: 99999;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
  box-sizing: border-box;
}
.modal-cap.hidden {
  display: none !important;
}
.modal-cap-backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.55);
}
.modal-cap-card {
  position: relative;
  width: 100%;
  max-width: 300px;
  border-radius: var(--radius);
  border: 1px solid var(--line);
  background: var(--void);
  padding: 14px 16px 16px;
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.45);
  outline: none;
}
.modal-cap-card:focus-visible {
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.45), 0 0 0 2px rgba(74, 222, 128, 0.35);
}
.modal-cap-title {
  font-size: 14px;
  font-weight: 700;
  color: var(--text);
  margin: 0 0 6px;
}
.modal-cap-sub {
  margin: 0 0 12px;
  font-size: 12px;
  color: var(--muted);
  line-height: 1.45;
}
.alt-capture-preview {
  min-height: 40px;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 6px;
  padding: 10px 10px;
  border-radius: var(--radius-sm);
  border: 1px dashed var(--line);
  background: var(--btn);
  margin-bottom: 8px;
}
.alt-capture-err {
  margin: 0 0 10px;
  font-size: 11px;
  color: var(--danger);
}
.alt-capture-err.hidden {
  display: none !important;
}
.modal-cap-actions {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
}
.btn-cap {
  border-radius: var(--radius-sm);
  padding: 8px 14px;
  font: inherit;
  font-size: 12px;
  font-weight: 700;
  cursor: pointer;
  border: 1px solid var(--line);
}
.btn-cap-muted {
  background: var(--btn);
  color: var(--muted);
}
.btn-cap-primary {
  background: var(--accent-dim);
  color: var(--accent);
  border-color: rgba(74, 222, 128, 0.45);
}
.btn-cap-primary:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}
.btn-primary {
  border: 1px solid rgba(74, 222, 128, 0.45);
  border-radius: var(--radius);
  padding: 10px 14px;
  background: var(--accent-dim);
  color: var(--accent);
  font: inherit;
  font-weight: 700;
  cursor: pointer;
}
.btn-primary.btn-block {
  width: 100%;
  box-sizing: border-box;
  margin-top: 8px;
}
.settings-check {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  color: var(--muted);
}
.settings-check input {
  width: 16px;
  height: 16px;
  accent-color: var(--accent);
}
.settings-check input:focus {
  outline: none;
}
.element-overlay-grid {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-top: 6px;
}
.element-overlay-row {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  color: var(--muted);
  flex-wrap: nowrap;
  min-width: 0;
}
.element-overlay-tail {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-left: auto;
  flex-wrap: nowrap;
  flex-shrink: 1;
  min-width: 0;
}
.element-overlay-check {
  width: 16px;
  height: 16px;
  flex-shrink: 0;
  accent-color: var(--accent);
  cursor: pointer;
}
.element-overlay-preview {
  position: relative;
  flex: 0 0 30px;
  width: 30px;
  height: 30px;
  border-radius: 3px;
  display: flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  box-shadow: inset 0 0 0 1px rgba(0,0,0,0.12);
  overflow: hidden;
}
.element-overlay-prev-water {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 17px;
  font-weight: 800;
  line-height: 1;
  opacity: 0.38;
  pointer-events: none;
  user-select: none;
}
.element-overlay-prev-label {
  position: relative;
  z-index: 1;
  font-size: 6px;
  font-weight: 700;
  letter-spacing: 0.02em;
  line-height: 1;
  text-align: center;
  pointer-events: none;
  user-select: none;
}
.element-overlay-name {
  color: var(--text);
  font-weight: 600;
  flex: 0 0 auto;
  min-width: 44px;
}
.element-overlay-coords {
  display: flex;
  align-items: center;
  gap: 8px;
  flex: 0 1 auto;
  min-width: 0;
  justify-content: flex-start;
}
.element-overlay-coords .coord-lab {
  display: inline-flex;
  flex-direction: row;
  align-items: center;
  gap: 5px;
  font-size: 13px;
  color: var(--muted);
  font-weight: 700;
  letter-spacing: 0.02em;
  white-space: nowrap;
}
.element-overlay-coords .coord-inp {
  width: 44px;
  min-width: 0;
  padding: 2px 3px;
  font-size: 10px;
  border: 1px solid var(--line);
  border-radius: var(--radius-sm);
  background: var(--pill);
  color: var(--text);
  box-sizing: border-box;
}
.element-overlay-coords .coord-inp:focus {
  border-color: #3f3f46;
}
.settings-main-toggle-row {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.settings-field input[type="text"]:focus,
.settings-field input[type="text"]:focus-visible,
.settings-field input[type="number"]:focus,
.settings-field input[type="number"]:focus-visible {
  outline: none;
  border-color: #3f3f46;
  box-shadow: 0 0 0 1px rgba(63, 63, 70, 0.6);
}
.btn-primary:focus,
.btn-primary:focus-visible {
  outline: none;
  box-shadow: 0 0 0 1px rgba(74, 222, 128, 0.35);
}
.settings-scroll {
  flex: 0 0 auto;
  min-height: 0;
  overflow: visible;
  padding: 2px 16px 8px 2px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
#viewSettings:not(.hidden) {
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
#viewSettings:not(.hidden) .settings-scroll {
  flex: 1 1 auto;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: auto;
  -webkit-overflow-scrolling: touch;
}
.ob-wrap {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  padding: 0;
  min-height: 0;
  overflow: hidden;
}
.ob-layout {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: hidden;
}
.ob-header {
  flex-shrink: 0;
  padding: 6px 16px 10px;
  text-align: center;
  border-bottom: 1px solid var(--line-soft);
}
.ob-headline {
  margin: 0;
  font-size: 17px;
  font-weight: 700;
  color: var(--text);
  letter-spacing: -0.02em;
}
.ob-viewport {
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  overflow: hidden;
  position: relative;
}
.ob-viewport::-webkit-scrollbar {
  display: none;
}
.ob-track {
  display: flex;
  width: 800%;
  height: 100%;
  align-items: stretch;
  min-height: 0;
  transition: transform 0.38s cubic-bezier(0.32, 0.72, 0, 1);
  will-change: transform;
}
.ob-slide {
  flex: 0 0 calc(100% / 8);
  min-width: 0;
  min-height: 0;
  height: 100%;
  max-height: 100%;
  align-self: stretch;
  box-sizing: border-box;
  overflow-x: hidden;
  overflow-y: auto;
  -webkit-overflow-scrolling: touch;
}
.ob-slide-inner {
  padding: 12px 20px 20px;
  text-align: left;
  box-sizing: border-box;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 0;
}
/* Process-picker panels only (not e.g. #obMainToggleKbdHost — row layout for shortcut chips) */
.ob-slide-inner > div[id^="obPanel"]:not(.ob-panel-hidden) {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
}
.ob-text {
  font-size: 15px;
  color: var(--muted);
  line-height: 1.5;
  margin: 0 0 14px;
  flex-shrink: 0;
}
.ob-footer {
  flex-shrink: 0;
  padding: 10px 16px 12px;
  border-top: 1px solid var(--line);
  background: var(--void);
}
.ob-dots {
  display: flex;
  justify-content: center;
  align-items: center;
  gap: 8px;
  margin-bottom: 10px;
}
.ob-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--dim);
  transition: background 0.22s ease, transform 0.22s ease;
}
.ob-dot.active {
  background: var(--accent);
  transform: scale(1.2);
}
.ob-footer-actions {
  display: flex;
  align-items: center;
  gap: 8px;
}
.ob-footer-actions .ob-footer-grow {
  flex: 1;
  min-width: 6px;
}
.ob-btn-muted {
  background: var(--btn) !important;
  color: var(--muted) !important;
  border-color: var(--line) !important;
}
.ob-footer .btn-primary {
  min-width: 72px;
}
.ob-footer .hidden {
  display: none !important;
}
.ob-process-list {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  border: 1px solid var(--line);
  border-radius: var(--radius-sm);
  background: var(--btn);
  margin-bottom: 8px;
}
.ob-proc {
  padding: 8px 10px;
  font-size: 13px;
  cursor: pointer;
  border-bottom: 1px solid var(--line-soft);
  color: var(--text);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.ob-proc:last-child { border-bottom: none; }
.ob-proc:hover { background: var(--btn-hi); }
.ob-proc.selected {
  background: rgba(74, 222, 128, 0.12);
  box-shadow: inset 0 0 0 1px rgba(74, 222, 128, 0.35);
}
.ob-proc.guess-pref .ob-proc-name { color: var(--accent); font-weight: 700; }
.ob-pill {
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--accent);
  border: 1px solid rgba(74, 222, 128, 0.4);
  border-radius: var(--radius-sm);
  padding: 2px 6px;
  flex-shrink: 0;
}
.ob-file-line {
  font-size: 14px;
  color: var(--muted);
  margin: 8px 0 4px;
  word-break: break-all;
}
.ob-panel-hidden { display: none !important; }
body.onboarding .titlebar-win #btnViewToggle { visibility: hidden; }
.ob-key-tutorial-slide .ob-slide-inner {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  min-height: 120px;
}
.ob-key-tutorial-intro {
  text-align: center;
  margin-bottom: 8px;
}
.ob-key-tutorial-layout {
  display: flex;
  flex-direction: row;
  align-items: stretch;
  justify-content: center;
  gap: 8px;
  flex: 1;
  min-height: 100px;
  /* Match .key-btn: 1px top border + .key block (~31px) + 1px + .label (~25px) ≈ 58px; mids from top of button */
  --ob-tut-btn-h: 58px;
  --ob-tut-key-mid-y: 16.5px;
  --ob-tut-label-mid-y: 45.5px;
  --ob-tut-arrow-half: 14px;
}
.ob-key-tutorial-col {
  flex: 1;
  min-width: 0;
  min-height: 92px;
  position: relative;
}
.ob-key-tutorial-left {
  text-align: right;
  padding-right: 4px;
  padding-top: 2px;
}
.ob-key-tutorial-right {
  text-align: left;
  padding-left: 4px;
  padding-top: 2px;
}
.ob-key-tutorial-caption {
  font-size: 12px;
  line-height: 1.35;
  color: var(--muted);
  margin: 0;
  max-width: 120px;
}
.ob-key-tutorial-left .ob-key-tutorial-caption {
  margin-left: auto;
  margin-bottom: 12px;
}
.ob-key-tutorial-left .ob-key-tutorial-arrow {
  position: absolute;
  right: 4px;
  top: calc(50% - (var(--ob-tut-btn-h) / 2) + var(--ob-tut-key-mid-y) - var(--ob-tut-arrow-half));
}
.ob-key-tutorial-right .ob-key-tutorial-arrow {
  position: absolute;
  left: 4px;
  top: calc(50% - (var(--ob-tut-btn-h) / 2) + var(--ob-tut-label-mid-y) - var(--ob-tut-arrow-half));
}
.ob-key-tutorial-right .ob-key-tutorial-caption {
  position: absolute;
  left: 4px;
  top: calc(50% - (var(--ob-tut-btn-h) / 2) + var(--ob-tut-label-mid-y) + var(--ob-tut-arrow-half) + 12px);
  margin: 0;
  max-width: 120px;
}
.ob-key-tutorial-arrow {
  font-size: 28px;
  line-height: 1;
  color: var(--accent);
  font-weight: 700;
  user-select: none;
  -webkit-user-select: none;
}
.ob-key-tutorial-center {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0 2px;
}
.ob-key-tutorial-center .key-btn {
  width: 72px;
}
</style>
</head>
<body>
<header class="titlebar">
  <div class="titlebar-brand">
    <span class="titlebar-title" id="titlebarTitle">RO Macro</span>
    <span class="titlebar-meta" id="titlebarMeta"></span>
  </div>
  <div class="titlebar-win">
    <button id="btnViewToggle" class="window-btn settings-btn" type="button" onclick="toggleSettingsView()" title="Settings">&#9881;</button>
    <button type="button" class="window-btn restart-btn" onclick="ahk.global.RestartBridge()" title="Restart">&#x21bb;</button>
    <button class="window-btn" onclick="ahk.gui.Minimize()" title="Minimize">0</button>
    <button class="window-btn close" onclick="ahk.global.ExitBridge()" title="Exit">r</button>
  </div>
</header>
<div id="updatePromptBar" class="update-prompt hidden" role="region" aria-label="Update available">
  <span id="updatePromptText" class="update-prompt-msg"></span>
  <span class="update-prompt-actions">
    <button type="button" class="btn-primary update-prompt-btn" id="updatePromptGo">Open release page</button>
    <button type="button" class="window-btn update-prompt-x" id="updatePromptDismiss" title="Dismiss">&#215;</button>
  </span>
</div>

<div class="shell">
<div id="viewOnboarding" class="wrap shell-pane ob-wrap hidden">
  <div class="ob-layout">
    <header class="ob-header">
      <h1 class="ob-headline" id="obHeadline">Welcome</h1>
    </header>
    <div class="ob-viewport" id="obViewport">
      <div class="ob-track" id="obTrack">
        <section class="ob-slide" aria-label="Welcome">
          <div class="ob-slide-inner">
            <p class="ob-text">Pick your Ragnarok client and the web browser you use for navigation. You can change these later in Settings.</p>
          </div>
        </section>
        <section class="ob-slide" aria-label="Game">
          <div class="ob-slide-inner">
            <p class="ob-text">Is your Ragnarok game running right now?</p>
          </div>
        </section>
        <section class="ob-slide" aria-label="Choose game">
          <div class="ob-slide-inner">
            <div id="obPanelGameList" class="ob-panel-hidden">
              <p class="ob-text">Select your game process.</p>
              <div class="ob-process-list" id="obGameList" onclick="obListClick(event,'game')"></div>
            </div>
            <div id="obPanelGameFile" class="ob-panel-hidden">
              <p class="ob-text">Choose your Ragnarok client .exe on disk (start the game first if you prefer).</p>
              <button type="button" class="btn-primary" onclick="obPickGameFile()">Choose .exe file</button>
              <div class="ob-file-line" id="obGameFileLabel">No file selected yet.</div>
            </div>
          </div>
        </section>
        <section class="ob-slide" aria-label="Browser">
          <div class="ob-slide-inner">
            <p class="ob-text">Is your web browser running right now?</p>
          </div>
        </section>
        <section class="ob-slide" aria-label="Choose browser">
          <div class="ob-slide-inner">
            <div id="obPanelBrowserList" class="ob-panel-hidden">
              <p class="ob-text">Pick the browser you use for navigation. Likely matches are highlighted.</p>
              <div class="ob-process-list" id="obBrowserList" onclick="obListClick(event,'browser')"></div>
            </div>
            <div id="obPanelBrowserFile" class="ob-panel-hidden">
              <p class="ob-text">Choose your browser .exe (e.g. zen.exe, chrome.exe).</p>
              <button type="button" class="btn-primary" onclick="obPickBrowserFile()">Choose .exe file</button>
              <div class="ob-file-line" id="obBrowserFileLabel">No file selected yet.</div>
            </div>
          </div>
        </section>
        <section class="ob-slide" aria-label="Review">
          <div class="ob-slide-inner">
            <p class="ob-text">Game: <strong id="obRevGame" style="color:var(--text)"></strong><br>Browser: <strong id="obRevBrowser" style="color:var(--text)"></strong></p>
          </div>
        </section>
        <section class="ob-slide" aria-label="Activation key">
          <div class="ob-slide-inner">
            <p class="ob-text">Ctrl+Down is the default shortcut to pause or resume all macros. You can keep it or choose your own before finishing setup.</p>
            <div class="ob-main-toggle-row">
              <div id="obMainToggleKbdHost" class="alt-pill-kbd ob-main-toggle-preview"></div>
              <button type="button" class="btn-primary" onclick="openMainToggleCaptureForOnboarding()">Set activation shortcut</button>
            </div>
            <p class="ob-file-line" id="obMainToggleHint">Press Set to capture a different combo, or continue with the default.</p>
          </div>
        </section>
        <section class="ob-slide ob-key-tutorial-slide" aria-label="Hotkey slot tutorial">
          <div class="ob-slide-inner">
            <p class="ob-text ob-key-tutorial-intro">Each slot has a key you can rebind and an on/off toggle. Here is the Q slot as an example.</p>
            <div class="ob-key-tutorial-layout">
              <div class="ob-key-tutorial-col ob-key-tutorial-left">
                <p class="ob-key-tutorial-caption">Click here to change the key.</p>
                <div class="ob-key-tutorial-arrow" aria-hidden="true">&#8594;</div>
              </div>
              <div class="ob-key-tutorial-center">
                <button type="button" class="key-btn active" id="obTutorialQBtn">
                  <span class="key" onclick="event.stopPropagation(); beginRebind('Q')">Q</span>
                  <span class="label" onclick="event.stopPropagation(); toggleKey('Q')">ON</span>
                </button>
              </div>
              <div class="ob-key-tutorial-col ob-key-tutorial-right">
                <div class="ob-key-tutorial-arrow" aria-hidden="true">&#8592;</div>
                <p class="ob-key-tutorial-caption">Click here to toggle the hotkey on or off.</p>
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>
    <footer class="ob-footer">
      <div class="ob-dots" id="obDots" aria-label="Setup steps"></div>
      <div class="ob-footer-actions">
        <button type="button" class="btn-primary ob-btn-muted" id="obBtnBack" onclick="obBack()">Back</button>
        <span class="ob-footer-grow"></span>
        <button type="button" class="btn-primary ob-btn-muted hidden" id="obBtnNo" onclick="obAnswerNo()">No</button>
        <button type="button" class="btn-primary hidden" id="obBtnYes" onclick="obAnswerYes()">Yes</button>
        <button type="button" class="btn-primary" id="obBtnPrimary" onclick="obPrimary()">Continue</button>
      </div>
    </footer>
  </div>
</div>
<main id="viewMain" class="wrap shell-pane">
  <section class="status-hero">
    <div class="status-hero-main">
      <div class="status-hero-copy">
        <div class="status-eyebrow">Macro state</div>
        <div class="status-big" id="statusText">Paused</div>
        <div class="status-target" id="targetLine">Target: dw-ro.exe</div>
        <div class="status-target status-ping-hint" id="serverPingLine" title="ICMP ping to an IPv4 address your game client has an established TCP connection to. UDP-only or blocked ICMP will show a dash.">Server ping: —</div>
      </div>
      <button type="button" class="macro-main-switch is-off" id="macroMainSwitch" onclick="toggleMainSwitch()" title="Toggle macros on/off" role="switch" aria-checked="false">
        <span class="switch-hit switch-hit-left" aria-hidden="true"></span>
        <span class="switch-hit switch-hit-right" aria-hidden="true"></span>
        <span class="macro-switch-thumb" aria-hidden="true"></span>
        <span class="macro-switch-words">
          <span class="macro-switch-word macro-sw-on">ON</span>
          <span class="macro-switch-word macro-sw-off">OFF</span>
        </span>
      </button>
    </div>
  </section>

    <div class="row">
    <div class="pill" id="togglePills"></div>
  </div>

  <div class="key-grid">
    <button class="key-btn active" id="qBtn">
      <span class="key" onclick="event.stopPropagation(); beginRebind('Q')">Q</span>
      <span class="label" onclick="event.stopPropagation(); toggleKey('Q')">ON</span>
    </button>
    <button class="key-btn active" id="wBtn">
      <span class="key" onclick="event.stopPropagation(); beginRebind('W')">W</span>
      <span class="label" onclick="event.stopPropagation(); toggleKey('W')">ON</span>
    </button>
    <button class="key-btn active" id="eBtn">
      <span class="key" onclick="event.stopPropagation(); beginRebind('E')">E</span>
      <span class="label" onclick="event.stopPropagation(); toggleKey('E')">ON</span>
    </button>
    <button class="key-btn active" id="rBtn">
      <span class="key" onclick="event.stopPropagation(); beginRebind('R')">R</span>
      <span class="label" onclick="event.stopPropagation(); toggleKey('R')">ON</span>
    </button>
    <button class="key-btn active" id="zBtn">
      <span class="key" onclick="event.stopPropagation(); beginRebind('Z')">Z</span>
      <span class="label" onclick="event.stopPropagation(); toggleKey('Z')">ON</span>
    </button>
    <button class="key-btn active" id="xBtn">
      <span class="key" onclick="event.stopPropagation(); beginRebind('X')">X</span>
      <span class="label" onclick="event.stopPropagation(); toggleKey('X')">ON</span>
    </button>
    <button class="key-btn active" id="cBtn">
      <span class="key" onclick="event.stopPropagation(); beginRebind('C')">C</span>
      <span class="label" onclick="event.stopPropagation(); toggleKey('C')">ON</span>
    </button>
    <button class="key-btn active" id="vBtn">
      <span class="key" onclick="event.stopPropagation(); beginRebind('V')">V</span>
      <span class="label" onclick="event.stopPropagation(); toggleKey('V')">ON</span>
    </button>
  </div>

  <div class="row timing-row">
    <div class="pill timing-pill">
      <div class="seg label shrink">Press</div>
      <div class="seg val shrink" id="delayKeyPress">80 ms</div>
      <div class="seg label shrink">Jitter</div>
      <div class="seg val shrink" id="jitterVal">±5 ms</div>
      <div class="seg label shrink">Hold</div>
      <div class="seg val shrink" id="delayHold">100 ms</div>
    </div>
  </div>
</main>

<div id="viewSettings" class="wrap shell-pane hidden">
    <div class="settings-scroll">
      <div class="settings-field">
        <label for="setSpamDelay">Key Press Delay (ms)</label>
        <input type="number" id="setSpamDelay" min="10" step="1">
        <div class="help">Milliseconds between repeated key sends while you hold any slot set to Spam key. All spam slots share this value. Slots set to Wait, then Enter use Enter-after wait instead, not this delay.</div>
      </div>
      <div class="settings-row2">
        <div class="settings-field">
          <label for="setJitter">Jitter (±ms)</label>
          <input type="number" id="setJitter" min="0" step="1">
        </div>
        <div class="settings-field">
          <label for="setHoldDelay">Spam hold delay (ms)</label>
          <input type="number" id="setHoldDelay" min="0" step="1">
          <div class="help">One normal send, wait, then rapid repeat while held.</div>
        </div>
      </div>
      <div class="settings-field">
        <label for="setEnterConfirm">Enter-after wait (ms)</label>
        <input type="number" id="setEnterConfirm" min="0" step="1">
        <div class="help">Used for any slot set to &quot;Wait, then Enter&quot; (not spam).</div>
      </div>
      <div class="settings-field">
        <label>Per-slot action</label>
        <div class="help">Use the toggle beside each key: Spam repeats the bound key while held; Enter waits (see Enter-after wait), then sends Enter once (menus / confirm).</div>
        <div class="slot-mode-grid">
          <span>Q</span><button type="button" class="slot-mode-switch is-spam" id="slotModeSwitchQ" onclick="toggleSlotBehavior('Q')" title="Q: Spam or Enter" role="switch" aria-checked="true"><span class="switch-hit switch-hit-left" aria-hidden="true"></span><span class="switch-hit switch-hit-right" aria-hidden="true"></span><span class="slot-switch-thumb" aria-hidden="true"></span><span class="slot-switch-words"><span class="slot-switch-word slot-sw-spam">Spam</span><span class="slot-switch-word slot-sw-enter">Enter</span></span></button>
          <span>Z</span><button type="button" class="slot-mode-switch is-spam" id="slotModeSwitchZ" onclick="toggleSlotBehavior('Z')" title="Z: Spam or Enter" role="switch" aria-checked="true"><span class="switch-hit switch-hit-left" aria-hidden="true"></span><span class="switch-hit switch-hit-right" aria-hidden="true"></span><span class="slot-switch-thumb" aria-hidden="true"></span><span class="slot-switch-words"><span class="slot-switch-word slot-sw-spam">Spam</span><span class="slot-switch-word slot-sw-enter">Enter</span></span></button>
          <span>W</span><button type="button" class="slot-mode-switch is-spam" id="slotModeSwitchW" onclick="toggleSlotBehavior('W')" title="W: Spam or Enter" role="switch" aria-checked="true"><span class="switch-hit switch-hit-left" aria-hidden="true"></span><span class="switch-hit switch-hit-right" aria-hidden="true"></span><span class="slot-switch-thumb" aria-hidden="true"></span><span class="slot-switch-words"><span class="slot-switch-word slot-sw-spam">Spam</span><span class="slot-switch-word slot-sw-enter">Enter</span></span></button>
          <span>X</span><button type="button" class="slot-mode-switch is-spam" id="slotModeSwitchX" onclick="toggleSlotBehavior('X')" title="X: Spam or Enter" role="switch" aria-checked="true"><span class="switch-hit switch-hit-left" aria-hidden="true"></span><span class="switch-hit switch-hit-right" aria-hidden="true"></span><span class="slot-switch-thumb" aria-hidden="true"></span><span class="slot-switch-words"><span class="slot-switch-word slot-sw-spam">Spam</span><span class="slot-switch-word slot-sw-enter">Enter</span></span></button>
          <span>E</span><button type="button" class="slot-mode-switch is-spam" id="slotModeSwitchE" onclick="toggleSlotBehavior('E')" title="E: Spam or Enter" role="switch" aria-checked="true"><span class="switch-hit switch-hit-left" aria-hidden="true"></span><span class="switch-hit switch-hit-right" aria-hidden="true"></span><span class="slot-switch-thumb" aria-hidden="true"></span><span class="slot-switch-words"><span class="slot-switch-word slot-sw-spam">Spam</span><span class="slot-switch-word slot-sw-enter">Enter</span></span></button>
          <span>C</span><button type="button" class="slot-mode-switch is-spam" id="slotModeSwitchC" onclick="toggleSlotBehavior('C')" title="C: Spam or Enter" role="switch" aria-checked="true"><span class="switch-hit switch-hit-left" aria-hidden="true"></span><span class="switch-hit switch-hit-right" aria-hidden="true"></span><span class="slot-switch-thumb" aria-hidden="true"></span><span class="slot-switch-words"><span class="slot-switch-word slot-sw-spam">Spam</span><span class="slot-switch-word slot-sw-enter">Enter</span></span></button>
          <span>R</span><button type="button" class="slot-mode-switch is-spam" id="slotModeSwitchR" onclick="toggleSlotBehavior('R')" title="R: Spam or Enter" role="switch" aria-checked="true"><span class="switch-hit switch-hit-left" aria-hidden="true"></span><span class="switch-hit switch-hit-right" aria-hidden="true"></span><span class="slot-switch-thumb" aria-hidden="true"></span><span class="slot-switch-words"><span class="slot-switch-word slot-sw-spam">Spam</span><span class="slot-switch-word slot-sw-enter">Enter</span></span></button>
          <span>V</span><button type="button" class="slot-mode-switch is-spam" id="slotModeSwitchV" onclick="toggleSlotBehavior('V')" title="V: Spam or Enter" role="switch" aria-checked="true"><span class="switch-hit switch-hit-left" aria-hidden="true"></span><span class="switch-hit switch-hit-right" aria-hidden="true"></span><span class="slot-switch-thumb" aria-hidden="true"></span><span class="slot-switch-words"><span class="slot-switch-word slot-sw-spam">Spam</span><span class="slot-switch-word slot-sw-enter">Enter</span></span></button>
        </div>
      </div>
      <div class="settings-field">
        <label for="setTargetExe">Target process</label>
        <input type="text" id="setTargetExe" autocomplete="off">
        <div class="help">Executable file name, e.g. dw-ro.exe</div>
      </div>
      <div class="settings-field">
        <label for="setZenExe">Web browser exe</label>
        <input type="text" id="setZenExe" autocomplete="off">
      </div>
      <label class="settings-check"><input type="checkbox" id="setNaviEnabled"> Navi clipboard paste into game</label>
      <label class="settings-check"><input type="checkbox" id="setNaviZen"> Require web browser foreground for Navi</label>
      <div class="settings-field">
        <label>Setup cache</label>
        <div class="help">Clears the saved first-time setup flag and opens the onboarding wizard again so you can re-pick your game process and web browser. Other settings (timing, keys, pass-through combos) are not changed until you finish the wizard.</div>
        <button type="button" class="btn-primary" onclick="clearSetupCacheAndOnboard()">Clear setup cache</button>
      </div>
      <div class="settings-field">
        <label>Primary macro toggle</label>
        <div class="help">Keyboard shortcut that pauses or resumes every slot. Default is Ctrl+Down. Click Set, press your combo, then Confirm.</div>
        <div class="settings-main-toggle-row">
          <input type="hidden" id="setMainToggleAhk" value=''>
          <div id="setMainToggleKbdHost" class="alt-pill-kbd"></div>
          <button type="button" class="btn-primary" onclick="openMainToggleHotkeyCapture()">Set</button>
        </div>
      </div>
      <div class="settings-field">
        <label>Pass-through toggles</label>
        <div class="help">Shortcuts pass through to the game and toggle macros on/off. Click Set, press your combo (for example Alt+Q), then Confirm.</div>
        <div id="altSpecList"></div>
        <button type="button" class="btn-primary btn-block" onclick="addAltSpecRow('')">Add combo</button>
      </div>
      <div class="settings-field">
        <label>Element overlays on game</label>
        <div class="help">50×50 on-screen tiles (this <strong>AutoHotkey</strong> process). Previews here are smaller. Toggle applies immediately. <strong>X/Y</strong> update live while you drag a tile; you can also type coordinates and they apply after a short pause. Tiles <strong>hide automatically</strong> unless the <strong>target game</strong> window is the foreground (active) window. With Magpie fullscreen, z-order is refreshed ~12×/second. Tray: <strong>Show Earth element tile (test)</strong>.</div>
        <div class="element-overlay-grid">
          <div class="element-overlay-row"><span class="element-overlay-name">Earth</span><div class="element-overlay-tail"><span class="element-overlay-preview" style="background:#6D4C41;color:#F5E6D3"><span class="element-overlay-prev-water" aria-hidden="true">1</span><span class="element-overlay-prev-label">EART</span></span><div class="element-overlay-coords"><label class="coord-lab">X<input type="number" id="setOverlayEarthX" class="coord-inp" step="1" autocomplete="off"></label><label class="coord-lab">Y<input type="number" id="setOverlayEarthY" class="coord-inp" step="1" autocomplete="off"></label></div><input type="checkbox" id="setOverlayEarth" class="element-overlay-check" aria-label="Show Earth overlay"></div></div>
          <div class="element-overlay-row"><span class="element-overlay-name">Wind</span><div class="element-overlay-tail"><span class="element-overlay-preview" style="background:#0EA5E9;color:#082F49"><span class="element-overlay-prev-water" aria-hidden="true">2</span><span class="element-overlay-prev-label">WIND</span></span><div class="element-overlay-coords"><label class="coord-lab">X<input type="number" id="setOverlayWindX" class="coord-inp" step="1" autocomplete="off"></label><label class="coord-lab">Y<input type="number" id="setOverlayWindY" class="coord-inp" step="1" autocomplete="off"></label></div><input type="checkbox" id="setOverlayWind" class="element-overlay-check" aria-label="Show Wind overlay"></div></div>
          <div class="element-overlay-row"><span class="element-overlay-name">Water</span><div class="element-overlay-tail"><span class="element-overlay-preview" style="background:#1D4ED8;color:#E8F1FF"><span class="element-overlay-prev-water" aria-hidden="true">3</span><span class="element-overlay-prev-label">WATR</span></span><div class="element-overlay-coords"><label class="coord-lab">X<input type="number" id="setOverlayWaterX" class="coord-inp" step="1" autocomplete="off"></label><label class="coord-lab">Y<input type="number" id="setOverlayWaterY" class="coord-inp" step="1" autocomplete="off"></label></div><input type="checkbox" id="setOverlayWater" class="element-overlay-check" aria-label="Show Water overlay"></div></div>
          <div class="element-overlay-row"><span class="element-overlay-name">Fire</span><div class="element-overlay-tail"><span class="element-overlay-preview" style="background:#DC2626;color:#FEF2F2"><span class="element-overlay-prev-water" aria-hidden="true">4</span><span class="element-overlay-prev-label">FIRE</span></span><div class="element-overlay-coords"><label class="coord-lab">X<input type="number" id="setOverlayFireX" class="coord-inp" step="1" autocomplete="off"></label><label class="coord-lab">Y<input type="number" id="setOverlayFireY" class="coord-inp" step="1" autocomplete="off"></label></div><input type="checkbox" id="setOverlayFire" class="element-overlay-check" aria-label="Show Fire overlay"></div></div>
          <div class="element-overlay-row"><span class="element-overlay-name">Ghost</span><div class="element-overlay-tail"><span class="element-overlay-preview" style="background:#7C3AED;color:#EDE9FE"><span class="element-overlay-prev-water" aria-hidden="true">5</span><span class="element-overlay-prev-label">GHST</span></span><div class="element-overlay-coords"><label class="coord-lab">X<input type="number" id="setOverlayGhostX" class="coord-inp" step="1" autocomplete="off"></label><label class="coord-lab">Y<input type="number" id="setOverlayGhostY" class="coord-inp" step="1" autocomplete="off"></label></div><input type="checkbox" id="setOverlayGhost" class="element-overlay-check" aria-label="Show Ghost overlay"></div></div>
          <div class="element-overlay-row"><span class="element-overlay-name">Shadow</span><div class="element-overlay-tail"><span class="element-overlay-preview" style="background:#312E81;color:#E0E7FF"><span class="element-overlay-prev-water" aria-hidden="true">6</span><span class="element-overlay-prev-label">SHDW</span></span><div class="element-overlay-coords"><label class="coord-lab">X<input type="number" id="setOverlayShadowX" class="coord-inp" step="1" autocomplete="off"></label><label class="coord-lab">Y<input type="number" id="setOverlayShadowY" class="coord-inp" step="1" autocomplete="off"></label></div><input type="checkbox" id="setOverlayShadow" class="element-overlay-check" aria-label="Show Shadow overlay"></div></div>
          <div class="element-overlay-row"><span class="element-overlay-name">Holy</span><div class="element-overlay-tail"><span class="element-overlay-preview" style="background:#CA8A04;color:#1C1917"><span class="element-overlay-prev-water" aria-hidden="true">7</span><span class="element-overlay-prev-label">HOLY</span></span><div class="element-overlay-coords"><label class="coord-lab">X<input type="number" id="setOverlayHolyX" class="coord-inp" step="1" autocomplete="off"></label><label class="coord-lab">Y<input type="number" id="setOverlayHolyY" class="coord-inp" step="1" autocomplete="off"></label></div><input type="checkbox" id="setOverlayHoly" class="element-overlay-check" aria-label="Show Holy overlay"></div></div>
        </div>
      </div>
      <button type="button" class="btn-primary" onclick="saveSettings()">Save settings</button>
    </div>
</div>
</div>

<div id="altHotkeyCaptureModal" class="modal-cap hidden" role="dialog" aria-modal="true" aria-labelledby="altCapTitle" aria-hidden="true" onclick="if(event.target===this)closeAltHotkeyCapture()">
  <div class="modal-cap-backdrop" onclick="closeAltHotkeyCapture()"></div>
  <div class="modal-cap-card" tabindex="-1">
    <div class="modal-cap-title" id="altCapTitle">Set pass-through shortcut</div>
    <p class="modal-cap-sub">Press the key combination you want. Esc cancels.</p>
    <div id="altCapturePreview" class="alt-capture-preview" aria-live="polite"></div>
    <p id="altCaptureErr" class="alt-capture-err hidden"></p>
    <div class="modal-cap-actions">
      <button type="button" class="btn-cap btn-cap-muted" id="altCaptureCancel">Cancel</button>
      <button type="button" class="btn-cap btn-cap-primary" id="altCaptureConfirm" disabled>Confirm</button>
    </div>
  </div>
</div>

<script>
var listeningSlot = null;
window.altHotkeyCaptureActive = false;
window.altCaptureTargetRow = null;
window.altCapturePendingSpec = null;
window.lastState = null;
var settingsOpen = false;
window.onboardingActive = false;
window.onboardingWizardStarted = false;

window.updateGamePing = function(ms, host) {
  var el = document.getElementById('serverPingLine');
  if (!el) return;
  host = host != null ? String(host) : '';
  if (ms != null && ms !== '' && !isNaN(Number(ms))) {
    el.textContent = 'Server ping: ' + Math.round(Number(ms)) + ' ms' + (host ? ' (' + host + ')' : '');
  } else if (host) {
    el.textContent = 'Server ping: — (' + host + ', no ICMP reply)';
  } else {
    el.textContent = 'Server ping: — (no game / no TCP peers)';
  }
};

var OB_SLIDE_COUNT = 8;
var OB_TITLES = ['Welcome', 'Game process', 'Choose game', 'Web browser', 'Choose browser', 'Review', 'Activation key', 'Hotkey tutorial'];

function syncObOnboardingQKeys() {
  if (!window.lastState) return;
  var st = window.lastState;
  var lab = st.qEnabled ? slotActiveBottomLabel('Q', st) : 'OFF';
  updateKey('qBtn', !!st.qEnabled, lab, st.qKeyDisplay);
  if (document.getElementById('obTutorialQBtn'))
    updateKey('obTutorialQBtn', !!st.qEnabled, lab, st.qKeyDisplay);
}

function obBuildDots() {
  var d = document.getElementById('obDots');
  if (!d) return;
  d.innerHTML = '';
  for (var j = 0; j < OB_SLIDE_COUNT; j++) {
    var s = document.createElement('span');
    s.className = 'ob-dot';
    s.setAttribute('aria-hidden', 'true');
    d.appendChild(s);
  }
}

function obSyncDots() {
  var d = document.getElementById('obDots');
  if (!d) return;
  var dots = d.querySelectorAll('.ob-dot');
  var idx = window.obSlideIndex | 0;
  for (var j = 0; j < dots.length; j++) {
    dots[j].classList.toggle('active', j === idx);
  }
}

function obSyncHeadline() {
  var h = document.getElementById('obHeadline');
  if (!h) return;
  var idx = window.obSlideIndex | 0;
  h.textContent = OB_TITLES[idx] || OB_TITLES[0];
}

function obSyncPanels() {
  var i = window.obSlideIndex | 0;
  var pGL = document.getElementById('obPanelGameList');
  var pGF = document.getElementById('obPanelGameFile');
  var pBL = document.getElementById('obPanelBrowserList');
  var pBF = document.getElementById('obPanelBrowserFile');
  if (pGL && pGF) {
    if (i !== 2) {
      pGL.classList.add('ob-panel-hidden');
      pGF.classList.add('ob-panel-hidden');
    } else {
      pGL.classList.toggle('ob-panel-hidden', window.obGamePickMode !== 'list');
      pGF.classList.toggle('ob-panel-hidden', window.obGamePickMode !== 'file');
    }
  }
  if (pBL && pBF) {
    if (i !== 4) {
      pBL.classList.add('ob-panel-hidden');
      pBF.classList.add('ob-panel-hidden');
    } else {
      pBL.classList.toggle('ob-panel-hidden', window.obBrowserPickMode !== 'list');
      pBF.classList.toggle('ob-panel-hidden', window.obBrowserPickMode !== 'file');
    }
  }
}

function obPrimaryEnabled() {
  var i = window.obSlideIndex | 0;
  if (i === 2) {
    if (window.obGamePickMode === 'list') return !!window.obSelGame;
    return !!window.obGameExe;
  }
  if (i === 4) {
    if (window.obBrowserPickMode === 'list') return !!window.obSelBrowser;
    return !!window.obBrowserExe;
  }
  return true;
}

function obSyncFooter() {
  var i = window.obSlideIndex | 0;
  var back = document.getElementById('obBtnBack');
  var no = document.getElementById('obBtnNo');
  var yes = document.getElementById('obBtnYes');
  var prim = document.getElementById('obBtnPrimary');
  if (!prim) return;
  function vis(el, on) {
    if (el) el.classList.toggle('hidden', !on);
  }
  vis(back, i > 0);
  vis(yes, i === 1 || i === 3);
  vis(no, i === 1 || i === 3);
  vis(prim, i !== 1 && i !== 3);
  prim.textContent = i === 7 ? 'Finish setup' : 'Continue';
  prim.disabled = (i === 2 || i === 4) && !obPrimaryEnabled();
}

function obApplySlideTransform(instant) {
  var tr = document.getElementById('obTrack');
  if (!tr) return;
  var idx = window.obSlideIndex | 0;
  var pct = (-idx * 100) / OB_SLIDE_COUNT;
  if (instant) {
    tr.style.transition = 'none';
    tr.style.transform = 'translateX(' + pct + '%)';
    void tr.offsetHeight;
    tr.style.transition = '';
  } else {
    tr.style.transform = 'translateX(' + pct + '%)';
  }
  if ((window.obSlideIndex | 0) === 6) refreshObMainTogglePreview();
  if ((window.obSlideIndex | 0) === 7) syncObOnboardingQKeys();
}

function obNavigateTo(idx, opts) {
  opts = opts || {};
  window.obSlideIndex = idx;
  obApplySlideTransform(!!opts.instant);
  if (opts.reloadGameList) obLoadProcessList('game');
  if (opts.reloadBrowserList) obLoadProcessList('browser');
  obSyncPanels();
  obSyncHeadline();
  obSyncFooter();
  obSyncDots();
}

function obBack() {
  var i = window.obSlideIndex | 0;
  if (i <= 0) return;
  obNavigateTo(i - 1, {});
}

function obAnswerYes() {
  var i = window.obSlideIndex | 0;
  if (i === 1) {
    window.obGamePickMode = 'list';
    obNavigateTo(2, { reloadGameList: true });
  } else if (i === 3) {
    window.obBrowserPickMode = 'list';
    obNavigateTo(4, { reloadBrowserList: true });
  }
}

function obAnswerNo() {
  var i = window.obSlideIndex | 0;
  if (i === 1) {
    window.obGamePickMode = 'file';
    obNavigateTo(2, {});
  } else if (i === 3) {
    window.obBrowserPickMode = 'file';
    obNavigateTo(4, {});
  }
}

function obPrimary() {
  var i = window.obSlideIndex | 0;
  if (i === 0) {
    obNavigateTo(1, {});
    return;
  }
  if (i === 2) {
    if (window.obGamePickMode === 'list') {
      if (!window.obSelGame) return;
      window.obGameExe = window.obSelGame;
      window.obGameDoneFrom = 'list';
    } else {
      if (!window.obGameExe) return;
      window.obGameDoneFrom = 'file';
    }
    obNavigateTo(3, {});
    return;
  }
  if (i === 4) {
    if (window.obBrowserPickMode === 'list') {
      if (!window.obSelBrowser) return;
      window.obBrowserExe = window.obSelBrowser;
      window.obBrowserDoneFrom = 'list';
    } else {
      if (!window.obBrowserExe) return;
      window.obBrowserDoneFrom = 'file';
    }
    var rg = document.getElementById('obRevGame');
    var rb = document.getElementById('obRevBrowser');
    if (rg) rg.textContent = window.obGameExe;
    if (rb) rb.textContent = window.obBrowserExe;
    obNavigateTo(5, {});
    return;
  }
  if (i === 5) {
    obNavigateTo(6, {});
    return;
  }
  if (i === 6) {
    obNavigateTo(7, {});
    return;
  }
  if (i === 7) {
    obFinish();
  }
}

function obWizardReset() {
  window.obSelGame = '';
  window.obSelBrowser = '';
  window.obGameExe = '';
  window.obBrowserExe = '';
  window.obGameDoneFrom = 'list';
  window.obBrowserDoneFrom = 'list';
  window.obGamePickMode = 'list';
  window.obBrowserPickMode = 'list';
  window.obSlideIndex = 0;
  var gl = document.getElementById('obGameList');
  var bl = document.getElementById('obBrowserList');
  if (gl) gl.innerHTML = '';
  if (bl) bl.innerHTML = '';
  var gfl = document.getElementById('obGameFileLabel');
  var bfl = document.getElementById('obBrowserFileLabel');
  if (gfl) gfl.textContent = 'No file selected yet.';
  if (bfl) bfl.textContent = 'No file selected yet.';
  window.obMainToggleAhk = (window.lastState && window.lastState.mainToggleHotkey) ? window.lastState.mainToggleHotkey : '^Down';
  obBuildDots();
  obNavigateTo(0, { instant: true });
}

function applyOnboardingFromState(state) {
  window.onboardingActive = !!state.needsOnboarding;
  var ob = document.getElementById('viewOnboarding');
  var main = document.getElementById('viewMain');
  var st = document.getElementById('viewSettings');
  if (!ob) return;
  if (window.onboardingActive) {
    ob.classList.remove('hidden');
    main.classList.add('hidden');
    st.classList.add('hidden');
    settingsOpen = false;
    document.body.classList.add('onboarding');
    if (!window.onboardingWizardStarted) {
      window.onboardingWizardStarted = true;
      obWizardReset();
    }
  } else {
    ob.classList.add('hidden');
    document.body.classList.remove('onboarding');
    window.onboardingWizardStarted = false;
    if (!settingsOpen) {
      main.classList.remove('hidden');
    }
  }
  applyViewChrome();
}

function obLoadProcessList(kind) {
  var listId = kind === 'game' ? 'obGameList' : 'obBrowserList';
  var selKey = kind === 'game' ? 'obSelGame' : 'obSelBrowser';
  window[selKey] = '';
  var el = document.getElementById(listId);
  if (!el) return;
  el.innerHTML = '<div class="ob-proc ob-loading"><span class="ob-proc-name">Loading…</span></div>';
  obSyncFooter();
  ahk.global.GetRunningExesJSON(kind).then(function(json) {
    var arr;
    try {
      arr = JSON.parse(json);
    } catch (e) {
      arr = [];
    }
    el.innerHTML = '';
    if (!arr.length) {
      el.innerHTML = '<div class="ob-proc"><span class="ob-proc-name">No processes found</span></div>';
      obSyncFooter();
      return;
    }
    for (var i = 0; i < arr.length; i++) {
      var row = document.createElement('div');
      row.className = 'ob-proc' + (arr[i].guess ? ' guess-pref' : '');
      row.setAttribute('data-exe', arr[i].exe);
      var nm = document.createElement('span');
      nm.className = 'ob-proc-name';
      nm.textContent = arr[i].exe;
      row.appendChild(nm);
      if (arr[i].guess) {
        var pill = document.createElement('span');
        pill.className = 'ob-pill';
        pill.textContent = kind === 'game' ? 'RO-like' : 'Likely';
        row.appendChild(pill);
      }
      el.appendChild(row);
    }
    obSyncFooter();
  }).catch(function() {
    el.innerHTML = '<div class="ob-proc"><span class="ob-proc-name">Could not list processes</span></div>';
    obSyncFooter();
  });
}

function obListClick(ev, kind) {
  var row = ev.target.closest ? ev.target.closest('.ob-proc') : null;
  if (!row || row.classList.contains('ob-loading')) return;
  var exe = row.getAttribute('data-exe');
  if (!exe) return;
  var listId = kind === 'game' ? 'obGameList' : 'obBrowserList';
  var selKey = kind === 'game' ? 'obSelGame' : 'obSelBrowser';
  var root = document.getElementById(listId);
  if (!root) return;
  var rows = root.querySelectorAll('.ob-proc');
  for (var i = 0; i < rows.length; i++) {
    rows[i].classList.remove('selected');
  }
  row.classList.add('selected');
  window[selKey] = exe;
  obSyncFooter();
}

function obPickGameFile() {
  ahk.global.PickExeFileBridge('Select your Ragnarok game .exe').then(function(fn) {
    if (!fn) return;
    window.obGameExe = fn;
    var gfl = document.getElementById('obGameFileLabel');
    if (gfl) gfl.textContent = 'Selected: ' + fn;
    obSyncFooter();
  });
}

function obPickBrowserFile() {
  ahk.global.PickExeFileBridge('Select your web browser .exe').then(function(fn) {
    if (!fn) return;
    window.obBrowserExe = fn;
    var bfl = document.getElementById('obBrowserFileLabel');
    if (bfl) bfl.textContent = 'Selected: ' + fn;
    obSyncFooter();
  });
}

function obFinish() {
  var payload = JSON.stringify({
    targetProcess: window.obGameExe,
    zenBrowserExe: window.obBrowserExe,
    mainToggleHotkey: window.obMainToggleAhk || '^Down'
  });
  ahk.global.FinishOnboardingBridge(payload).then(function(json) {
    if (String(json) === 'error') {
      alert('Could not save setup.');
      return;
    }
    updateState(JSON.parse(json));
  });
}

function escapeHtml(s) {
  if (s == null) return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function syncTitlebarMeta() {
  var meta = document.getElementById('titlebarMeta');
  if (!meta) return;
  var st = window.lastState;
  if (!st || window.onboardingActive) {
    meta.textContent = '';
    return;
  }
  var v = st.appVersion != null ? String(st.appVersion) : '';
  var html = '';
  if (v)
    html += '<span class="tm-ver">v' + escapeHtml(v) + '</span>';
  if (st.updateAvailable && st.releasesUrl) {
    html += '<span class="tm-sep">\u00b7</span><span class="tm-upd" role="button" tabindex="0" data-url="' + escapeHtml(st.releasesUrl) + '" title="Open GitHub releases">Update</span>';
  }
  meta.innerHTML = html;
  var el = meta.querySelector('.tm-upd');
  if (el) {
    el.onclick = function(ev) {
      ev.preventDefault();
      var u = el.getAttribute('data-url');
      if (u && window.ahk && window.ahk.global && window.ahk.global.OpenUrlBridge)
        window.ahk.global.OpenUrlBridge(u);
    };
    el.onkeydown = function(ev) {
      if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); el.click(); }
    };
  }
}

function syncUpdatePromptBar() {
  var bar = document.getElementById('updatePromptBar');
  if (!bar) return;
  var st = window.lastState;
  if (!st || !st.updateAvailable || window.onboardingActive) {
    bar.classList.add('hidden');
    return;
  }
  try {
    if (sessionStorage.getItem('romUpdatePromptDismissed') === '1') {
      bar.classList.add('hidden');
      return;
    }
  } catch (e0) {}
  bar.classList.remove('hidden');
  var tx = document.getElementById('updatePromptText');
  var tag = st.updateLatestTag != null ? String(st.updateLatestTag) : '';
  if (tx)
    tx.textContent = 'A newer release is on GitHub' + (tag ? ' (' + tag + ').' : '.');
}

function applyViewChrome() {
  var title = document.getElementById('titlebarTitle');
  var btn = document.getElementById('btnViewToggle');
  if (title) {
    if (window.onboardingActive) {
      title.textContent = 'First-time setup';
    } else {
      title.textContent = settingsOpen ? 'Settings' : 'RO Macro';
    }
  }
  syncTitlebarMeta();
  syncUpdatePromptBar();
  if (btn) {
    if (window.onboardingActive) {
      btn.title = '';
      btn.innerHTML = '&#9881;';
    } else {
      btn.title = settingsOpen ? 'Back to macros' : 'Settings';
      btn.innerHTML = settingsOpen ? '&#8592;' : '&#9881;';
    }
  }
}

function setSettingsOpen(on) {
  if (window.onboardingActive) return;
  closeAltHotkeyCapture();
  settingsOpen = !!on;
  if (on && listeningSlot) {
    var s = listeningSlot;
    listeningSlot = null;
    notifyCaptureHotkeyUi(false);
    var el = document.getElementById(obRebindButtonId(s));
    if (el) {
      el.classList.remove('listening');
    }
    if (window.lastState) {
      var st0 = window.lastState;
      updateKey('qBtn', !!st0.qEnabled, st0.qEnabled ? slotActiveBottomLabel('Q', st0) : 'OFF', st0.qKeyDisplay);
      updateKey('wBtn', !!st0.wEnabled, st0.wEnabled ? slotActiveBottomLabel('W', st0) : 'OFF', st0.wKeyDisplay);
      updateKey('eBtn', !!st0.eEnabled, st0.eEnabled ? slotActiveBottomLabel('E', st0) : 'OFF', st0.eKeyDisplay);
      updateKey('rBtn', !!st0.rEnabled, st0.rEnabled ? slotActiveBottomLabel('R', st0) : 'OFF', st0.rKeyDisplay);
      updateKey('zBtn', !!st0.zEnabled, st0.zEnabled ? slotActiveBottomLabel('Z', st0) : 'OFF', st0.zKeyDisplay);
      updateKey('xBtn', !!st0.xEnabled, st0.xEnabled ? slotActiveBottomLabel('X', st0) : 'OFF', st0.xKeyDisplay);
      updateKey('cBtn', !!st0.cEnabled, st0.cEnabled ? slotActiveBottomLabel('C', st0) : 'OFF', st0.cKeyDisplay);
      updateKey('vBtn', !!st0.vEnabled, st0.vEnabled ? slotActiveBottomLabel('V', st0) : 'OFF', st0.vKeyDisplay);
    }
  }
  var main = document.getElementById('viewMain');
  var st = document.getElementById('viewSettings');
  if (main) {
    main.classList.toggle('hidden', settingsOpen);
  }
  if (st) {
    st.classList.toggle('hidden', !settingsOpen);
  }
  applyViewChrome();
  if (settingsOpen && window.lastState) {
    populateSettingsFromState(window.lastState);
    window.setTimeout(function() {
      try {
        wireElementOverlayCheckboxListeners();
        syncElementOverlayFromGrid();
      } catch (e4) {}
    }, 0);
  }
}

function toggleSettingsView() {
  setSettingsOpen(!settingsOpen);
}

function setMain(enabled) {
  ahk.global.SetMainBridge(enabled).then(function(json) {
    updateState(JSON.parse(json));
  });
}

function toggleMainSwitch() {
  setMain(!document.body.classList.contains('enabled'));
}

function toggleKey(key) {
  ahk.global.ToggleKeyBridge(key).then(function(json) {
    updateState(JSON.parse(json));
  });
}

function slotId(slot) {
  return slot.toLowerCase() + 'Btn';
}

function obRebindButtonId(slot) {
  if (slot === 'Q' && window.onboardingActive && (window.obSlideIndex | 0) === 7)
    return 'obTutorialQBtn';
  return slotId(slot);
}

function beginRebind(slot) {
  if (window.altHotkeyCaptureActive) return;
  if (listeningSlot) {
    var prev = document.getElementById(obRebindButtonId(listeningSlot));
    if (prev) prev.classList.remove('listening');
  }
  listeningSlot = slot;
  var btn = document.getElementById(obRebindButtonId(slot));
  if (!btn) {
    listeningSlot = null;
    return;
  }
  btn.classList.add('listening');
  btn.querySelector('.key').textContent = '...';
  notifyCaptureHotkeyUi(true);
}

function eventKeyName(ev) {
  if (ev.key && ev.key.length === 1) return ev.key.toUpperCase();
  return ev.key || '';
}

document.addEventListener('keydown', function(ev) {
  if (window.altHotkeyCaptureActive) {
    altHotkeyCaptureOnKeydown(ev);
    return;
  }
  if (!listeningSlot) return;

  ev.preventDefault();
  ev.stopPropagation();

  var slot = listeningSlot;
  listeningSlot = null;
  notifyCaptureHotkeyUi(false);
  var rebBtn = document.getElementById(obRebindButtonId(slot));
  if (rebBtn) rebBtn.classList.remove('listening');

  ahk.global.SaveKeyBindingBridge(slot, eventKeyName(ev)).then(function(result) {
    result = String(result);
    if (result === 'invalid') {
      alert('That key cannot be used as a macro hotkey.');
      return ahk.global.GetStateJSON().then(function(json) { updateState(JSON.parse(json)); });
    }
    if (result === 'duplicate') {
      alert('That key is already assigned to another macro.');
      return ahk.global.GetStateJSON().then(function(json) { updateState(JSON.parse(json)); });
    }
    updateState(JSON.parse(result));
  });
}, true);

function updateKey(id, enabled, activeLabel, keyText) {
  var btn = document.getElementById(id);
  if (!btn) return;
  btn.classList.toggle('active', enabled);
  btn.classList.toggle('off', !enabled);
  if (keyText) btn.querySelector('.key').textContent = keyText;
  btn.querySelector('.label').textContent = enabled ? (activeLabel || 'ON') : 'OFF';
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function normalizeMainKeyFromEvent(ev) {
  var code = ev.code || '';
  if (code === 'Escape') return null;
  switch (code) {
    case 'Space':
      return 'Space';
    case 'ArrowUp':
      return 'Up';
    case 'ArrowDown':
      return 'Down';
    case 'ArrowLeft':
      return 'Left';
    case 'ArrowRight':
      return 'Right';
    case 'Home':
      return 'Home';
    case 'End':
      return 'End';
    case 'PageUp':
      return 'PgUp';
    case 'PageDown':
      return 'PgDn';
    case 'Insert':
      return 'Insert';
    case 'Delete':
      return 'Delete';
    case 'Backspace':
      return 'Backspace';
    case 'Tab':
      return 'Tab';
    case 'Enter':
      return 'Enter';
    default:
      break;
  }
  if (/^Numpad/i.test(code)) return null;
  var m = /^Key([A-Z])$/i.exec(code);
  if (m) return m[1].toLowerCase();
  m = /^Digit([0-9])$/.exec(code);
  if (m) return m[1];
  m = /^F([1-9]|1[0-2])$/i.exec(code);
  if (m) return 'F' + m[1];
  var k = ev.key || '';
  m = /^F([1-9]|1[0-2])$/i.exec(k);
  if (m) return 'F' + m[1];
  return null;
}

function buildAltPassthroughFromEvent(ev) {
  var mods = '';
  if (ev.metaKey) mods += '#';
  if (ev.ctrlKey) mods += '^';
  if (ev.shiftKey) mods += '+';
  if (ev.altKey) mods += '!';
  var main = normalizeMainKeyFromEvent(ev);
  if (main === null) return 'BADKEY';
  return mods + main;
}

function buildMainToggleSpecFromEvent(ev) {
  var modCount = (ev.altKey ? 1 : 0) + (ev.ctrlKey ? 1 : 0) + (ev.shiftKey ? 1 : 0) + (ev.metaKey ? 1 : 0);
  if (modCount >= 1) return buildAltPassthroughFromEvent(ev);
  var main = normalizeMainKeyFromEvent(ev);
  if (main === null) return 'BADKEY';
  return main;
}

function displayKeyLabelForSpec(k) {
  if (!k) return '';
  var u = {
    Space: 'SPACE',
    Up: 'UP',
    Down: 'DOWN',
    Left: 'LEFT',
    Right: 'RIGHT',
    Home: 'HOME',
    End: 'END',
    PgUp: 'PAGE UP',
    PgDn: 'PAGE DOWN',
    Insert: 'INSERT',
    Delete: 'DELETE',
    Backspace: 'BACKSPACE',
    Tab: 'TAB',
    Enter: 'ENTER',
    Esc: 'ESC'
  };
  if (u[k]) return u[k];
  if (k.length === 1 && /[a-z0-9]/i.test(k)) return k.toUpperCase();
  if (/^F([1-9]|1[0-2])$/i.test(k)) return k.toUpperCase();
  return k.toUpperCase();
}

function formatToggleSpecAsKbdHtml(spec, small) {
  var rest = String(spec || '').trim();
  if (!rest) return '<span class="kbd-muted">Not set</span>';
  var has = { '!': false, '^': false, '+': false, '#': false };
  while (rest.length && '!^+#'.indexOf(rest.charAt(0)) !== -1) {
    has[rest.charAt(0)] = true;
    rest = rest.slice(1);
  }
  var chips = [];
  var cls = small ? 'kbd-chip kbd-chip--sm' : 'kbd-chip';
  if (has['!']) chips.push('ALT');
  if (has['^']) chips.push('CTRL');
  if (has['+']) chips.push('SHIFT');
  if (has['#']) chips.push('WIN');
  var keyPart = rest.trim();
  if (keyPart) chips.push(displayKeyLabelForSpec(keyPart));
  var html = '';
  for (var i = 0; i < chips.length; i++) {
    if (i) html += '<span class="kbd-plus">+</span>';
    html += '<kbd class="' + cls + '">' + escapeHtml(chips[i]) + '</kbd>';
  }
  return html;
}

function notifyCaptureHotkeyUi(active) {
  try {
    if (window.ahk && window.ahk.global && window.ahk.global.SetCaptureHotkeyUiBridge)
      window.ahk.global.SetCaptureHotkeyUiBridge(active ? 'true' : 'false');
  } catch (e0) {}
}

function closeAltHotkeyCapture() {
  notifyCaptureHotkeyUi(false);
  window.altHotkeyCaptureActive = false;
  window.altCaptureTargetRow = null;
  window.altCapturePendingSpec = null;
  window.hotkeyCaptureKind = '';
  var modal = document.getElementById('altHotkeyCaptureModal');
  if (modal) {
    modal.classList.add('hidden');
    modal.setAttribute('aria-hidden', 'true');
  }
  var prev = document.getElementById('altCapturePreview');
  if (prev) prev.innerHTML = '';
  var err = document.getElementById('altCaptureErr');
  if (err) {
    err.textContent = '';
    err.classList.add('hidden');
  }
  var conf = document.getElementById('altCaptureConfirm');
  if (conf) conf.disabled = true;
}

function openAltHotkeyCapture(row) {
  window.hotkeyCaptureKind = 'alt';
  window.altCaptureTargetRow = row;
  window.altCapturePendingSpec = null;
  window.altHotkeyCaptureActive = true;
  var modal0 = document.getElementById('altHotkeyCaptureModal');
  var tit = document.getElementById('altCapTitle');
  var sub0 = modal0 ? modal0.querySelector('.modal-cap-sub') : null;
  if (tit) tit.textContent = 'Set pass-through shortcut';
  if (sub0) sub0.textContent = 'Press the key combination you want. Esc cancels.';
  var prev = document.getElementById('altCapturePreview');
  if (prev) prev.innerHTML = '<span class="kbd-muted">Waiting\u2026</span>';
  var err = document.getElementById('altCaptureErr');
  if (err) err.classList.add('hidden');
  var conf = document.getElementById('altCaptureConfirm');
  if (conf) conf.disabled = true;
  var modal = document.getElementById('altHotkeyCaptureModal');
  if (modal) {
    modal.classList.remove('hidden');
    modal.setAttribute('aria-hidden', 'false');
  }
  var card = document.querySelector('.modal-cap-card');
  if (card) card.focus();
  notifyCaptureHotkeyUi(true);
}

function openMainToggleHotkeyCapture() {
  window.hotkeyCaptureKind = 'main';
  window.altCaptureTargetRow = null;
  window.altCapturePendingSpec = null;
  window.altHotkeyCaptureActive = true;
  var modal = document.getElementById('altHotkeyCaptureModal');
  var tit = document.getElementById('altCapTitle');
  var sub = modal ? modal.querySelector('.modal-cap-sub') : null;
  if (tit) tit.textContent = 'Set primary toggle shortcut';
  if (sub) sub.textContent = 'Press the combination you want (for example Ctrl+Down). Esc cancels.';
  var prev = document.getElementById('altCapturePreview');
  var hid = document.getElementById('setMainToggleAhk');
  var cur = (hid && hid.value) ? hid.value : '^Down';
  if (prev) prev.innerHTML = formatToggleSpecAsKbdHtml(cur);
  var err = document.getElementById('altCaptureErr');
  if (err) err.classList.add('hidden');
  var conf = document.getElementById('altCaptureConfirm');
  if (conf) conf.disabled = true;
  if (modal) {
    modal.classList.remove('hidden');
    modal.setAttribute('aria-hidden', 'false');
  }
  var card = document.querySelector('.modal-cap-card');
  if (card) card.focus();
  notifyCaptureHotkeyUi(true);
}

function openMainToggleCaptureForOnboarding() {
  window.hotkeyCaptureKind = 'mainOnboarding';
  window.altCaptureTargetRow = null;
  window.altCapturePendingSpec = null;
  window.altHotkeyCaptureActive = true;
  var modal = document.getElementById('altHotkeyCaptureModal');
  var tit = document.getElementById('altCapTitle');
  var sub = modal ? modal.querySelector('.modal-cap-sub') : null;
  if (tit) tit.textContent = 'Set primary toggle shortcut';
  if (sub) sub.textContent = 'Press your combination (default is Ctrl+Down). Esc cancels.';
  var prev = document.getElementById('altCapturePreview');
  var cur = window.obMainToggleAhk || '^Down';
  if (prev) prev.innerHTML = formatToggleSpecAsKbdHtml(cur);
  var err = document.getElementById('altCaptureErr');
  if (err) err.classList.add('hidden');
  var conf = document.getElementById('altCaptureConfirm');
  if (conf) conf.disabled = true;
  if (modal) {
    modal.classList.remove('hidden');
    modal.setAttribute('aria-hidden', 'false');
  }
  var card = document.querySelector('.modal-cap-card');
  if (card) card.focus();
  notifyCaptureHotkeyUi(true);
}

function altAhkSpecUsedElsewhere(ahk, row) {
  var rows = document.querySelectorAll('.alt-spec-ahk');
  var want = String(ahk || '').trim().toLowerCase();
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i].closest('.alt-spec-row');
    if (r === row) continue;
    if (String(rows[i].value || '').trim().toLowerCase() === want) return true;
  }
  return false;
}

function confirmHotkeyCapture() {
  var spec = window.altCapturePendingSpec;
  if (!spec) return;
  var kind = window.hotkeyCaptureKind || 'alt';
  if (kind === 'alt') {
    var row = window.altCaptureTargetRow;
    if (!row) return;
    if (altAhkSpecUsedElsewhere(spec, row)) {
      var err = document.getElementById('altCaptureErr');
      if (err) {
        err.textContent = 'That shortcut is already listed.';
        err.classList.remove('hidden');
      }
      return;
    }
    var hid = row.querySelector('.alt-spec-ahk');
    if (hid) hid.value = spec;
    renderAltSpecRowDisplay(row);
    closeAltHotkeyCapture();
    return;
  }
  if (kind === 'main') {
    var hidm = document.getElementById('setMainToggleAhk');
    if (hidm) hidm.value = spec;
    renderMainToggleKbdHost();
    closeAltHotkeyCapture();
    return;
  }
  if (kind === 'mainOnboarding') {
    window.obMainToggleAhk = spec;
    refreshObMainTogglePreview();
    closeAltHotkeyCapture();
  }
}

function altHotkeyCaptureOnKeydown(ev) {
  ev.preventDefault();
  ev.stopPropagation();
  var errEl = document.getElementById('altCaptureErr');
  var prevEl = document.getElementById('altCapturePreview');
  var conf = document.getElementById('altCaptureConfirm');
  if (ev.key === 'Escape') {
    closeAltHotkeyCapture();
    return;
  }
  if (ev.repeat) return;
  if (ev.key === 'Control' || ev.key === 'Shift' || ev.key === 'Alt' || ev.key === 'Meta') return;
  var kind = window.hotkeyCaptureKind || 'alt';
  var useMain = kind === 'main' || kind === 'mainOnboarding';
  var modCount = (ev.altKey ? 1 : 0) + (ev.ctrlKey ? 1 : 0) + (ev.shiftKey ? 1 : 0) + (ev.metaKey ? 1 : 0);
  var spec;
  if (useMain) {
    spec = buildMainToggleSpecFromEvent(ev);
  } else {
    if (!modCount) {
      if (errEl) {
        errEl.textContent = 'Hold a modifier (Alt, Ctrl, Shift, or Win) with your key.';
        errEl.classList.remove('hidden');
      }
      if (conf) conf.disabled = true;
      return;
    }
    spec = buildAltPassthroughFromEvent(ev);
  }
  if (spec === 'BADKEY') {
    if (errEl) {
      errEl.textContent = useMain
        ? 'That key is not supported here. Try with a modifier, or F1–F12, arrows, Space, Tab, or Enter.'
        : 'That key is not supported. Try letters, digits, F1–F12, or arrows / Space / Tab / Enter.';
      errEl.classList.remove('hidden');
    }
    if (conf) conf.disabled = true;
    return;
  }
  if (errEl) errEl.classList.add('hidden');
  window.altCapturePendingSpec = spec;
  if (prevEl) prevEl.innerHTML = formatToggleSpecAsKbdHtml(spec);
  if (conf) conf.disabled = false;
}

function renderAltSpecRowDisplay(row) {
  var hid = row.querySelector('.alt-spec-ahk');
  var host = row.querySelector('.alt-spec-kbd-host');
  if (!hid || !host) return;
  host.innerHTML = formatToggleSpecAsKbdHtml(hid.value);
}

function renderMainToggleKbdHost() {
  var hid = document.getElementById('setMainToggleAhk');
  var host = document.getElementById('setMainToggleKbdHost');
  if (!hid || !host) return;
  host.innerHTML = formatToggleSpecAsKbdHtml(hid.value || '^Down', true);
}

function refreshObMainTogglePreview() {
  var host = document.getElementById('obMainToggleKbdHost');
  if (!host) return;
  var spec = window.obMainToggleAhk || '^Down';
  host.innerHTML = formatToggleSpecAsKbdHtml(spec, true);
}

function rebuildTogglePills(state) {
  var pill = document.getElementById('togglePills');
  if (!pill) return;
  var primary = state && state.mainToggleHotkey ? state.mainToggleHotkey : '^Down';
  var html = '<div class="seg shrink alt-pill-kbd toggle-primary-kbd">' + formatToggleSpecAsKbdHtml(primary, true) + '</div>';
  if (state.altPassthrough && state.altPassthrough.length) {
    for (var i = 0; i < state.altPassthrough.length; i++) {
      html +=
        '<div class="seg shrink alt-pill-kbd">' +
        formatToggleSpecAsKbdHtml(state.altPassthrough[i], true) +
        '</div>';
    }
  }
  pill.innerHTML = html;
}

function addAltSpecRow(val) {
  var list = document.getElementById('altSpecList');
  var row = document.createElement('div');
  row.className = 'alt-spec-row';
  var hid = document.createElement('input');
  hid.type = 'hidden';
  hid.className = 'alt-spec-ahk';
  hid.value = val || '';
  var host = document.createElement('div');
  host.className = 'alt-spec-kbd-host';
  host.innerHTML = formatToggleSpecAsKbdHtml(val || '');
  var btnSet = document.createElement('button');
  btnSet.type = 'button';
  btnSet.className = 'alt-spec-set';
  btnSet.textContent = 'Set';
  btnSet.onclick = function() {
    openAltHotkeyCapture(row);
  };
  var btnRm = document.createElement('button');
  btnRm.type = 'button';
  btnRm.className = 'alt-spec-rm';
  btnRm.textContent = 'Remove';
  btnRm.onclick = function() {
    row.remove();
  };
  row.appendChild(hid);
  row.appendChild(host);
  row.appendChild(btnSet);
  row.appendChild(btnRm);
  list.appendChild(row);
}

function altSpecsFromList() {
  var rows = document.querySelectorAll('.alt-spec-ahk');
  var out = [];
  for (var i = 0; i < rows.length; i++) {
    var t = rows[i].value.trim();
    if (t) out.push(t);
  }
  return out;
}

function enterConfirmMs(state) {
  if (state.enterConfirmDelay != null) return state.enterConfirmDelay;
  if (state.rConfirmDelay != null) return state.rConfirmDelay;
  return 180;
}

function slotActiveBottomLabel(slotCh, state) {
  var m = state['slotMode' + slotCh];
  if (m === 'enter_after') return 'ENTER';
  return 'ON';
}

function setSlotBehaviorSwitch(slotCh, mode) {
  var el = document.getElementById('slotModeSwitch' + slotCh);
  if (!el) return;
  var isEnter = mode === 'enter_after';
  el.classList.toggle('is-spam', !isEnter);
  el.classList.toggle('is-enter', isEnter);
  el.setAttribute('aria-checked', isEnter ? 'false' : 'true');
}

function toggleSlotBehavior(slotCh) {
  var el = document.getElementById('slotModeSwitch' + slotCh);
  if (!el) return;
  setSlotBehaviorSwitch(slotCh, el.classList.contains('is-enter') ? 'spam' : 'enter_after');
}

window.roSuppressOverlayCoords = false;
window._roOvCoordTimers = window._roOvCoordTimers || {};

function overlayCoordFieldIds() {
  return [
    ['Earth', 'setOverlayEarthX', 'setOverlayEarthY'],
    ['Wind', 'setOverlayWindX', 'setOverlayWindY'],
    ['Water', 'setOverlayWaterX', 'setOverlayWaterY'],
    ['Fire', 'setOverlayFireX', 'setOverlayFireY'],
    ['Ghost', 'setOverlayGhostX', 'setOverlayGhostY'],
    ['Shadow', 'setOverlayShadowX', 'setOverlayShadowY'],
    ['Holy', 'setOverlayHolyX', 'setOverlayHolyY']
  ];
}

function applyOverlayCoordsFromHost(obj) {
  if (!obj || typeof obj !== 'object') return;
  window.roSuppressOverlayCoords = true;
  var rows = overlayCoordFieldIds();
  for (var i = 0; i < rows.length; i++) {
    var name = rows[i][0];
    var d = obj[name];
    var xe = document.getElementById(rows[i][1]);
    var ye = document.getElementById(rows[i][2]);
    if (!xe || !ye) continue;
    if (d && d.x != null && d.y != null && !isNaN(Number(d.x)) && !isNaN(Number(d.y))) {
      xe.value = String(Math.round(Number(d.x)));
      ye.value = String(Math.round(Number(d.y)));
    } else {
      xe.value = '';
      ye.value = '';
    }
  }
  window.roSuppressOverlayCoords = false;
}

function pushOverlayCoordsFromInputs(name, xid, yid) {
  if (window.roSuppressOverlayCoords) return;
  var xe = document.getElementById(xid);
  var ye = document.getElementById(yid);
  if (!xe || !ye) return;
  var xv = String(xe.value || '').trim();
  var yv = String(ye.value || '').trim();
  if (xv === '' || yv === '') return;
  var x = parseInt(xv, 10);
  var y = parseInt(yv, 10);
  if (isNaN(x) || isNaN(y)) return;
  var cv = typeof chrome !== 'undefined' ? chrome : window.chrome;
  if (!cv || !cv.webview || !window.ahk || !ahk.global) return;
  ahk.global.SetElementOverlayCoordsBridge(JSON.stringify({ element: name, x: x, y: y })).then(function(json) {
    if (String(json) === 'error') return;
    if (window.updateState) updateState(JSON.parse(json));
  }).catch(function() {});
}

function wireElementOverlayCoordInputs() {
  var rows = overlayCoordFieldIds();
  for (var i = 0; i < rows.length; i++) {
    (function(name, xid, yid) {
      var xe = document.getElementById(xid);
      var ye = document.getElementById(yid);
      if (!xe || !ye || xe._roCoordWired) return;
      xe._roCoordWired = true;
      ye._roCoordWired = true;
      function onField() {
        if (window.roSuppressOverlayCoords) return;
        clearTimeout(window._roOvCoordTimers[name]);
        window._roOvCoordTimers[name] = setTimeout(function() {
          pushOverlayCoordsFromInputs(name, xid, yid);
        }, 400);
      }
      xe.addEventListener('input', onField);
      ye.addEventListener('input', onField);
      xe.addEventListener('change', onField);
      ye.addEventListener('change', onField);
    })(rows[i][0], rows[i][1], rows[i][2]);
  }
}

function refreshElementOverlayCoordsFromHost() {
  try {
    if (!window.ahk || !ahk.global || !ahk.global.GetElementOverlayCoordsJSON) return;
    ahk.global.GetElementOverlayCoordsJSON().then(function(j) {
      try {
        applyOverlayCoordsFromHost(JSON.parse(j));
      } catch (e0) {}
    });
  } catch (e1) {}
}

function wireElementOverlayCheckboxListeners() {
  var ids = ['setOverlayEarth', 'setOverlayWind', 'setOverlayWater', 'setOverlayFire', 'setOverlayGhost', 'setOverlayShadow', 'setOverlayHoly'];
  for (var i = 0; i < ids.length; i++) {
    (function(id) {
      var el = document.getElementById(id);
      if (!el || el._roElOverlayWired) return;
      el._roElOverlayWired = true;
      el.addEventListener('change', syncElementOverlayFromGrid);
      el.addEventListener('click', function() { window.setTimeout(syncElementOverlayFromGrid, 0); });
    })(ids[i]);
  }
  wireElementOverlayCoordInputs();
}

function syncElementOverlayFromGrid() {
  function chk(id) {
    var e = document.getElementById(id);
    return !!(e && e.checked);
  }
  var payload = {
    overlayEarth: chk('setOverlayEarth'),
    overlayWind: chk('setOverlayWind'),
    overlayWater: chk('setOverlayWater'),
    overlayFire: chk('setOverlayFire'),
    overlayGhost: chk('setOverlayGhost'),
    overlayShadow: chk('setOverlayShadow'),
    overlayHoly: chk('setOverlayHoly')
  };
  var cv = (typeof chrome !== 'undefined' ? chrome : window.chrome);
  try {
    if (!cv || !cv.webview) {
      alert('Element overlay: WebView host is not available (chrome.webview).');
      return;
    }
    if (!window.ahk || !ahk.global) {
      alert('Element overlay: ahk host object is not ready yet.');
      return;
    }
    ahk.global.SyncElementOverlayTogglesBridge(JSON.stringify(payload)).then(function(json) {
      if (String(json) === 'error') {
        alert('Element overlay: host returned error (bad JSON or parse failure).');
        return;
      }
      if (window.updateState) updateState(JSON.parse(json));
    }).catch(function(err) {
      alert('Element overlay: ' + (err && err.message ? err.message : String(err)));
    });
  } catch (e0) {
    alert('Element overlay sync failed: ' + e0);
  }
}

function populateSettingsFromState(state) {
  document.getElementById('setSpamDelay').value = state.spamDelay;
  document.getElementById('setJitter').value = state.spamJitter;
  document.getElementById('setHoldDelay').value = state.spamHoldDelayMs != null ? state.spamHoldDelayMs : 100;
  document.getElementById('setEnterConfirm').value = enterConfirmMs(state);
  document.getElementById('setTargetExe').value = state.targetProcess || '';
  document.getElementById('setZenExe').value = state.zenBrowserExe || 'zen.exe';
  var mth = document.getElementById('setMainToggleAhk');
  if (mth) mth.value = state.mainToggleHotkey || '^Down';
  renderMainToggleKbdHost();
  document.getElementById('setNaviEnabled').checked = !!state.naviClipboardEnabled;
  document.getElementById('setNaviZen').checked = !!state.naviRequireZen;
  var slots = ['Q', 'W', 'E', 'R', 'Z', 'X', 'C', 'V'];
  for (var si = 0; si < slots.length; si++) {
    var ch = slots[si];
    setSlotBehaviorSwitch(ch, state['slotMode' + ch] === 'enter_after' ? 'enter_after' : 'spam');
  }
  var list = document.getElementById('altSpecList');
  list.innerHTML = '';
  var specs = (state.altPassthrough && state.altPassthrough.length) ? state.altPassthrough : ['!e', '!q', '!z'];
  for (var j = 0; j < specs.length; j++) addAltSpecRow(specs[j]);
  var ov = [['setOverlayEarth','overlayEarth'],['setOverlayWind','overlayWind'],['setOverlayWater','overlayWater'],['setOverlayFire','overlayFire'],['setOverlayGhost','overlayGhost'],['setOverlayShadow','overlayShadow'],['setOverlayHoly','overlayHoly']];
  for (var oi = 0; oi < ov.length; oi++) {
    var oel = document.getElementById(ov[oi][0]);
    if (oel) oel.checked = !!state[ov[oi][1]];
  }
  wireElementOverlayCoordInputs();
  refreshElementOverlayCoordsFromHost();
}

function clearSetupCacheAndOnboard() {
  if (!confirm('Clear setup cache and run the onboarding wizard again?')) return;
  ahk.global.ResetOnboardingBridge().then(function(json) {
    if (String(json) === 'error') {
      alert('Could not reset setup.');
      return;
    }
    window.onboardingWizardStarted = false;
    updateState(JSON.parse(json));
  });
}

function saveSettings() {
  var payload = {
    spamDelay: parseInt(document.getElementById('setSpamDelay').value, 10) || 80,
    spamJitter: parseInt(document.getElementById('setJitter').value, 10) || 0,
    enterConfirmDelay: parseInt(document.getElementById('setEnterConfirm').value, 10) || 0,
    spamHoldDelayMs: parseInt(document.getElementById('setHoldDelay').value, 10) || 0,
    targetProcess: document.getElementById('setTargetExe').value.trim() || 'dw-ro.exe',
    zenBrowserExe: document.getElementById('setZenExe').value.trim() || 'zen.exe',
    naviClipboardEnabled: document.getElementById('setNaviEnabled').checked,
    naviRequireZen: document.getElementById('setNaviZen').checked,
    mainToggleHotkey: (document.getElementById('setMainToggleAhk') && document.getElementById('setMainToggleAhk').value.trim()) || '^Down',
    altPassthrough: altSpecsFromList(),
    overlayEarth: document.getElementById('setOverlayEarth').checked,
    overlayWind: document.getElementById('setOverlayWind').checked,
    overlayWater: document.getElementById('setOverlayWater').checked,
    overlayFire: document.getElementById('setOverlayFire').checked,
    overlayGhost: document.getElementById('setOverlayGhost').checked,
    overlayShadow: document.getElementById('setOverlayShadow').checked,
    overlayHoly: document.getElementById('setOverlayHoly').checked
  };
  var slots2 = ['Q', 'W', 'E', 'R', 'Z', 'X', 'C', 'V'];
  for (var pi = 0; pi < slots2.length; pi++) {
    var c = slots2[pi];
    var sw = document.getElementById('slotModeSwitch' + c);
    payload['slotMode' + c] = sw && sw.classList.contains('is-enter') ? 'enter_after' : 'spam';
  }
  if (!payload.altPassthrough.length) payload.altPassthrough = ['!e', '!q', '!z'];
  ahk.global.SaveSettingsBridge(JSON.stringify(payload)).then(function(json) {
    if (String(json) === 'error') {
      alert('Could not save settings.');
      return;
    }
    updateState(JSON.parse(json));
    setSettingsOpen(false);
  });
}

window.updateState = function(state) {
  window.lastState = state;
  applyOnboardingFromState(state);
  if (window.onboardingActive) {
    syncObOnboardingQKeys();
    applyViewChrome();
    return;
  }

  document.body.classList.toggle('enabled', !!state.macrosEnabled);
  document.body.classList.toggle('macros-off', !state.macrosEnabled);
  document.getElementById('statusText').textContent = state.macrosEnabled ? 'Running' : 'Paused';
  var sw = document.getElementById('macroMainSwitch');
  if (sw) {
    sw.classList.toggle('is-on', !!state.macrosEnabled);
    sw.classList.toggle('is-off', !state.macrosEnabled);
    sw.setAttribute('aria-checked', state.macrosEnabled ? 'true' : 'false');
  }
  document.getElementById('targetLine').textContent = 'Target: ' + state.targetProcess;
  if (window.updateGamePing)
    window.updateGamePing(state.gamePingMs, state.gamePingHost);
  document.getElementById('delayKeyPress').textContent = state.spamDelay + ' ms';
  document.getElementById('jitterVal').textContent = '\u00B1' + state.spamJitter + ' ms';
  document.getElementById('delayHold').textContent = (state.spamHoldDelayMs != null ? state.spamHoldDelayMs : 100) + ' ms';
  rebuildTogglePills(state);
  updateKey('qBtn', !!state.qEnabled, state.qEnabled ? slotActiveBottomLabel('Q', state) : 'OFF', state.qKeyDisplay);
  updateKey('wBtn', !!state.wEnabled, state.wEnabled ? slotActiveBottomLabel('W', state) : 'OFF', state.wKeyDisplay);
  updateKey('eBtn', !!state.eEnabled, state.eEnabled ? slotActiveBottomLabel('E', state) : 'OFF', state.eKeyDisplay);
  updateKey('rBtn', !!state.rEnabled, state.rEnabled ? slotActiveBottomLabel('R', state) : 'OFF', state.rKeyDisplay);
  updateKey('zBtn', !!state.zEnabled, state.zEnabled ? slotActiveBottomLabel('Z', state) : 'OFF', state.zKeyDisplay);
  updateKey('xBtn', !!state.xEnabled, state.xEnabled ? slotActiveBottomLabel('X', state) : 'OFF', state.xKeyDisplay);
  updateKey('cBtn', !!state.cEnabled, state.cEnabled ? slotActiveBottomLabel('C', state) : 'OFF', state.cKeyDisplay);
  updateKey('vBtn', !!state.vEnabled, state.vEnabled ? slotActiveBottomLabel('V', state) : 'OFF', state.vKeyDisplay);
  applyViewChrome();
};

(function wireAltCaptureUi() {
  var c = document.getElementById('altCaptureCancel');
  var k = document.getElementById('altCaptureConfirm');
  if (c) c.onclick = function() { closeAltHotkeyCapture(); };
  if (k) k.onclick = confirmHotkeyCapture;
})();

(function wireUpdatePromptUi() {
  var d = document.getElementById('updatePromptDismiss');
  if (d) d.onclick = function() {
    try { sessionStorage.setItem('romUpdatePromptDismissed', '1'); } catch (e1) {}
    var bar = document.getElementById('updatePromptBar');
    if (bar) bar.classList.add('hidden');
  };
  var g = document.getElementById('updatePromptGo');
  if (g) g.onclick = function() {
    var st = window.lastState;
    var u = st && st.releasesUrl ? String(st.releasesUrl) : '';
    if (u && window.ahk && window.ahk.global && window.ahk.global.OpenUrlBridge)
      window.ahk.global.OpenUrlBridge(u);
  };
})();

ahk.global.GetStateJSON().then(function(json) {
  updateState(JSON.parse(json));
  wireElementOverlayCheckboxListeners();
  wireElementOverlayCoordInputs();
  refreshElementOverlayCoordsFromHost();
});
</script>
</body>
</html>
    )"
    WVGui := WebViewGui("+AlwaysOnTop -Caption", "RO Macro v" ROMacroVersion)
    WVGui.OnEvent("Close", (*) => (WVGui.Hide(), true))
    WVGui.AddTextRoute("index.html", indexHtml)

    WVGui.Navigate("index.html")
    WVGui.Show(Format("x{1} y{2} w380 h354 NA", HudX, HudY))
    ApplyShellIcons(WVGui)
    RomSyncNativeTitle()
    SetTimer(RefreshElementOverlayGuis, -400)
    SetTimer(RefreshGameServerPing, -1500)
    SetTimer(() => RomCheckForUpdateNow(), -6000)
}


MainToggleHotkeyHandler(*) {
    global MacrosEnabled, CaptureHotkeyUiActive

    if CaptureHotkeyUiActive
        return
    SetMacrosEnabled(!MacrosEnabled)
}


RegisterMainToggleHotkey() {
    global MainToggleHotkey, RegisteredMainToggleHk

    if RegisteredMainToggleHk != "" {
        try Hotkey RegisteredMainToggleHk, "Off"
        RegisteredMainToggleHk := ""
    }
    hk := Trim(String(MainToggleHotkey))
    if hk = ""
        hk := "^Down"
    MainToggleHotkey := hk
    hkReg := HotkeySpecWithPassthrough(hk)
    try {
        Hotkey hkReg, MainToggleHotkeyHandler, "On"
        RegisteredMainToggleHk := hkReg
    } catch {
        MainToggleHotkey := "^Down"
        hkReg := HotkeySpecWithPassthrough(MainToggleHotkey)
        try {
            Hotkey hkReg, MainToggleHotkeyHandler, "On"
            RegisteredMainToggleHk := hkReg
        }
    }
}


; Primary macro toggle is registered dynamically — see RegisterMainToggleHotkey().


; Secondary toggles (Alt+key etc.) are registered from INI via RegisterAltPassthroughHotkeys().


; Declare these expressions so dynamic HotIf registrations can reference them.
#HotIf MacroHotkeyAllowed("Q")
#HotIf MacroHotkeyAllowed("W")
#HotIf MacroHotkeyAllowed("E")
#HotIf MacroHotkeyAllowed("R")
#HotIf MacroHotkeyAllowed("Z")
#HotIf MacroHotkeyAllowed("X")
#HotIf MacroHotkeyAllowed("C")
#HotIf MacroHotkeyAllowed("V")
#HotIf


RegisterMacroHotkeys() {
    global KeyBindings

    for slot, _ in KeyBindings
        RegisterMacroHotkey(slot)
}


RegisterMacroHotkey(slot) {
    global KeyBindings, RegisteredHotkeys, SlotBehaviors

    if !KeyBindings.Has(slot)
        return

    key := KeyBindings[slot]
    if key = ""
        return

    criteria := 'MacroHotkeyAllowed("' slot '")'
    ; ~ = pass native key to the game/client as well as run this handler; $* = hook + all modifiers
    spec := "~$*" . key
    HotIf criteria
    try Hotkey spec, MacroHotkeyPressed.Bind(slot), "On"
    HotIf
    RegisteredHotkeys[slot] := Map("Spec", spec, "Criteria", criteria)
}


UnregisterMacroHotkey(slot) {
    global RegisteredHotkeys

    if RegisteredHotkeys.Has(slot) {
        hotkeyInfo := RegisteredHotkeys[slot]
        HotIf hotkeyInfo["Criteria"]
        try Hotkey hotkeyInfo["Spec"], "Off"
        HotIf
        RegisteredHotkeys.Delete(slot)
    }
}


MacroHotkeyAllowed(slot) {
    global MacrosEnabled, TargetProcess, KeyBindings, CaptureHotkeyUiActive

    if CaptureHotkeyUiActive
        return false
    if !(MacrosEnabled && IsKeyEnabled(slot) && WinActive("ahk_exe " TargetProcess))
        return false

    ; Allow Shift+<key> game binds to pass through without macro interception.
    if GetKeyState("Shift", "P")
        return false

    ; Let configured modifier combos act only as secondary state toggles (pass-through hotkeys).
    if IsPassthroughComboBlockingSlot(slot)
        return false

    return true
}


MacroHotkeyPressed(slot, *) {
    global QHeld, WHeld, EHeld, RHeld, ZHeld, XHeld, CHeld, VHeld
    global SpamDelay, EnterConfirmDelay, SpamHoldDelayMs, KeyBindings, SlotBehaviors

    if !MacroHotkeyAllowed(slot)
        return

    key := KeyBindings[slot]
    mode := SlotBehaviors.Has(slot) ? SlotBehaviors[slot] : "spam"

    if mode = "enter_after" {
        Sleep EnterConfirmDelay
        SendEvent "{Enter down}"
        Sleep 30
        SendEvent "{Enter up}"
        KeyWait key
        return
    }

    spamMs := SpamDelay

    SendBoundKey(slot)
    Sleep SpamHoldDelayMs
    if !MacroHotkeyAllowed(slot) || !GetKeyState(key, "P")
        return

    switch slot {
        case "Q":
            QHeld := true
            SetTimer SpamQ, -GetRandomDelay(spamMs)
            KeyWait key
            QHeld := false
            SetTimer SpamQ, 0
        case "W":
            WHeld := true
            SetTimer SpamW, -GetRandomDelay(spamMs)
            KeyWait key
            WHeld := false
            SetTimer SpamW, 0
        case "E":
            EHeld := true
            SetTimer SpamE, -GetRandomDelay(spamMs)
            KeyWait key
            EHeld := false
            SetTimer SpamE, 0
        case "R":
            RHeld := true
            SetTimer SpamR, -GetRandomDelay(spamMs)
            KeyWait key
            RHeld := false
            SetTimer SpamR, 0
        case "Z":
            ZHeld := true
            SetTimer SpamZ, -GetRandomDelay(spamMs)
            KeyWait key
            ZHeld := false
            SetTimer SpamZ, 0
        case "X":
            XHeld := true
            SetTimer SpamX, -GetRandomDelay(spamMs)
            KeyWait key
            XHeld := false
            SetTimer SpamX, 0
        case "C":
            CHeld := true
            SetTimer SpamC, -GetRandomDelay(spamMs)
            KeyWait key
            CHeld := false
            SetTimer SpamC, 0
        case "V":
            VHeld := true
            SetTimer SpamV, -GetRandomDelay(spamMs)
            KeyWait key
            VHeld := false
            SetTimer SpamV, 0
    }
}


SendBoundKey(slot) {
    global KeyBindings

    SendKeyPress(KeyBindings[slot])
}


SendKeyPress(key) {
    SendEvent "{" key " down}"
    Sleep 30
    SendEvent "{" key " up}"
}


SpamQ() {
    global MacrosEnabled, QMacroEnabled, QHeld, TargetProcess, SpamDelay

    if (MacrosEnabled && QMacroEnabled && QHeld && WinActive("ahk_exe " TargetProcess)) {
        SendBoundKey("Q")
        SetTimer SpamQ, -GetRandomDelay(SpamDelay)
    }
}


SpamW() {
    global MacrosEnabled, WMacroEnabled, WHeld, TargetProcess, SpamDelay

    if (MacrosEnabled && WMacroEnabled && WHeld && WinActive("ahk_exe " TargetProcess)) {
        SendBoundKey("W")
        SetTimer SpamW, -GetRandomDelay(SpamDelay)
    }
}


SpamE() {
    global MacrosEnabled, EMacroEnabled, EHeld, TargetProcess, SpamDelay

    if (MacrosEnabled && EMacroEnabled && EHeld && WinActive("ahk_exe " TargetProcess)) {
        SendBoundKey("E")
        SetTimer SpamE, -GetRandomDelay(SpamDelay)
    }
}


SpamR() {
    global MacrosEnabled, RMacroEnabled, RHeld, TargetProcess, SpamDelay

    if (MacrosEnabled && RMacroEnabled && RHeld && WinActive("ahk_exe " TargetProcess)) {
        SendBoundKey("R")
        SetTimer SpamR, -GetRandomDelay(SpamDelay)
    }
}


SpamZ() {
    global MacrosEnabled, ZMacroEnabled, ZHeld, TargetProcess, SpamDelay

    if (MacrosEnabled && ZMacroEnabled && ZHeld && WinActive("ahk_exe " TargetProcess)) {
        SendBoundKey("Z")
        SetTimer SpamZ, -GetRandomDelay(SpamDelay)
    }
}


SpamX() {
    global MacrosEnabled, XMacroEnabled, XHeld, TargetProcess, SpamDelay

    if (MacrosEnabled && XMacroEnabled && XHeld && WinActive("ahk_exe " TargetProcess)) {
        SendBoundKey("X")
        SetTimer SpamX, -GetRandomDelay(SpamDelay)
    }
}


SpamC() {
    global MacrosEnabled, CMacroEnabled, CHeld, TargetProcess, SpamDelay

    if (MacrosEnabled && CMacroEnabled && CHeld && WinActive("ahk_exe " TargetProcess)) {
        SendBoundKey("C")
        SetTimer SpamC, -GetRandomDelay(SpamDelay)
    }
}


SpamV() {
    global MacrosEnabled, VMacroEnabled, VHeld, TargetProcess, SpamDelay

    if (MacrosEnabled && VMacroEnabled && VHeld && WinActive("ahk_exe " TargetProcess)) {
        SendBoundKey("V")
        SetTimer SpamV, -GetRandomDelay(SpamDelay)
    }
}