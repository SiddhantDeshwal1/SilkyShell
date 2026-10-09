import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import Quickshell.Widgets

// ─────────────────────────────────────────────────────────────────────────────
// ControlCenter — Modular Liquid Glass Control Center for QuickShell.
// Modeled directly on macOS / iOS 18 Control Center aesthetics:
//   - Main view: 376px frosted oceanic liquid glass with compact refined padding
//   - 4 Extra-Large Circular Action Widgets (74x74: Lock, Settings, Notifications, Screenshot)
//   - Hyprlock integration for instant screen locking
//   - Precision 11-step slider level indicator ticks under Brightness & Sound sliders
//   - Full Wi-Fi Backend: Scanning, password authentication modal, disconnect, forget network
//   - Full Bluetooth Backend: Pairing, connect/disconnect, battery display, audio codec selector
//   - Sub-menus: Wi-Fi, Bluetooth, Sound & Output (identical to Media Island)
//   - Official Apple SF Pro Display typography (razor-sharp rendering)
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    // ── Apple SF Pro Rounded Typography ──────────────────────────────
    readonly property string sfFont: "SF Pro Rounded"
    readonly property string sfFontMedium: "SF Pro Rounded"
    readonly property string sfFontSemibold: "SF Pro Rounded"
    readonly property string sfFontBold: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"
    readonly property var springCurve: [0.25, 0.80, 0.35, 1.015, 0.55, 1.015, 0.70, 1.015, 0.80, 1.000, 1.00, 1.000]

    Timer {
        id: openRefreshTimer
        interval: 650
        repeat: false
        onTriggered: {
            if (root.open) {
                root.refreshStatus()
                root.refreshScreenTime()
            }
        }
    }

    property bool open: false
    onOpenChanged: {
        if (open) {
            openRefreshTimer.restart()
        } else {
            openRefreshTimer.stop()
        }
    }

    Component.onCompleted: {
        refreshStatus()
        refreshScreenTime()
    }

    property string currentView: "main" // "main" | "wifi" | "bluetooth" | "sound" | "screentime"
    property bool dndActive: false
    property bool darkModeActive: Theme.darkMode
    property bool nightLightActive: false

    // ── Screen Time State ─────────────────────────────────────────────
    property int    screenTimeTotalSec: 0
    property string screenTimeTotalFormatted: "0m"
    property var    screenTimeApps: []

    // Background Screen Time Daemon
    Process {
        id: screentimeDaemonProc
        command: ["python3", "/home/banana/.config/quickshell/scripts/screentime.py", "daemon"]
        running: true
    }

    FileView {
        id: stFileWatcher
        path: "/home/banana/.cache/quickshell/screentime.json"
        watchChanges: true
        onFileChanged: root.refreshScreenTime()
    }

    function refreshScreenTime() {
        try {
            const text = stFileWatcher.text()
            if (text && text.trim() !== "") {
                const obj = JSON.parse(text.trim())
                if (obj) {
                    root.screenTimeTotalSec = obj.totalSeconds || 0
                    root.screenTimeTotalFormatted = obj.totalFormatted || "0m"
                    root.screenTimeApps = obj.apps || []
                }
            }
        } catch(e) {}
    }

    // ── Wi-Fi State ───────────────────────────────────────────────────
    property bool wifiEnabled: true
    property bool wifiConnected: false
    property string wifiSsid: ""
    property int wifiSignal: 0
    property var wifiNetworks: []
    property var _wifiScanBuffer: []
    property bool wifiScanning: false

    // Wi-Fi Password Prompt State
    property bool wifiPasswordPromptOpen: false
    property string wifiSelectedSsid: ""
    property bool wifiSelectedSecured: false
    property string wifiPasswordInput: ""
    property bool wifiConnecting: false
    property string wifiStatusMsg: ""
    property bool wifiShowPass: false

    // ── Bluetooth State ───────────────────────────────────────────────
    property bool btPowered: false
    property bool btDiscovering: false
    property string btConnectedDevice: ""
    property var btDevices: []
    property bool btScanning: false
    property var btTransientStates: ({})
    property string btCardName: ""
    property string btActiveProfile: ""
    property var btAudioProfiles: []

    // ── Brightness State ──────────────────────────────────────────────
    property real brightnessLevel: 0.8

    // ── Audio / Pipewire State ────────────────────────────────────────
    property var sink: Pipewire.defaultAudioSink
    property var sinkAudio: sink ? sink.audio : null
    property real volumeLevel: sinkAudio ? sinkAudio.volume : 0.5
    property bool isMuted: sinkAudio ? sinkAudio.muted : false

    PwObjectTracker {
        id: pwTracker
        objects: Pipewire.nodes.values
    }

    function getAudioOutputSinks() {
        return Pipewire.nodes.values.filter(function(n) {
            return n.isSink && !n.isStream
        })
    }

    function getSinkIcon(s) {
        if (!s) return "󰕾"
        const name = (s.name || "").toLowerCase()
        const desc = (s.description || s.nickname || "").toLowerCase()
        if (name.includes("bluez") || name.includes("bluetooth") || desc.includes("bluetooth")) return "󰂯"
        if (name.includes("headphone") || desc.includes("headphone") || name.includes("headset") || desc.includes("headset") || desc.includes("earphone") || desc.includes("earbuds") || desc.includes("buds")) return "󰋋"
        if (name.includes("hdmi") || desc.includes("hdmi") || name.includes("displayport") || desc.includes("displayport") || desc.includes("monitor")) return "󰍹"
        if (name.includes("pci") || name.includes("internal") || name.includes("built-in") || desc.includes("built-in") || desc.includes("internal") || desc.includes("speaker") || desc.includes("speakers") || desc.includes("analog")) return "󰌢"
        return "󰓃"
    }

    // ── Window Anchors & Layer Setup ──────────────────────────────────
    anchors {
        top: true
        left: true
        right: true
    }

    WlrLayershell.margins.top: 28
    implicitHeight: Screen.height - 28

    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-control-center"
    WlrLayershell.keyboardFocus: root.wifiPasswordPromptOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    color: "transparent"
    visible: open || panelWrapper.opacity > 0

    IpcHandler {
        target: "controlcenter"
        function toggle() { root.toggle() }
        function open() { root.openPanel() }
        function close() { root.close() }
        function openWifi() { root.open = true; root.openWifiMenu() }
        function openBluetooth() { root.open = true; root.openBluetoothMenu() }
        function openSound() { root.open = true; root.openSoundMenu() }
        function openScreenTime() { root.open = true; root.openScreenTimeMenu() }
        function goBack() { root.goBack() }
        function toggleDnd() { root.dndActive = !root.dndActive }
        function toggleDarkMode() { Theme.toggleDarkMode() }
    }

    function toggle() {
        if (open) close()
        else openPanel()
    }

    function openPanel() {
        open = true
        currentView = "main"
        openRefreshTimer.restart()
    }

    function close() {
        if (currentView === "bluetooth") stopBluetoothScan()
        open = false
        currentView = "main"
        wifiPasswordPromptOpen = false
    }

    function setupMenuOrigin(menuCard, sourceWidget, fallbackX, fallbackY, fallbackScaleX, fallbackScaleY, fallbackRadius) {
        if (!menuCard) return
        var menuW = menuCard.width > 0 ? menuCard.width : 376
        var menuH = menuCard.height > 0 ? menuCard.height : 340
        if (sourceWidget && panelWrapper) {
            try {
                var pt = sourceWidget.mapToItem(panelWrapper, sourceWidget.width / 2, sourceWidget.height / 2)
                var finalCx = menuCard.x + menuW / 2
                var finalCy = menuCard.y + menuH / 2
                menuCard.startTransX = pt.x - finalCx
                menuCard.startTransY = pt.y - finalCy
                menuCard.startScaleX = sourceWidget.width / menuW
                menuCard.startScaleY = sourceWidget.height / menuH
                var srcRadius = (sourceWidget.cardRadius !== undefined) ? sourceWidget.cardRadius : 35
                menuCard.startRadius = Math.min(menuH / 2, srcRadius / Math.max(0.01, menuCard.startScaleY))
                return
            } catch (e) {}
        }
        menuCard.startTransX = fallbackX
        menuCard.startTransY = fallbackY
        menuCard.startScaleX = fallbackScaleX
        menuCard.startScaleY = fallbackScaleY
        menuCard.startRadius = fallbackRadius
    }

    function openWifiMenu() {
        if (currentView === "bluetooth") stopBluetoothScan()
        root.setupMenuOrigin(wifiMenuCard, wifiCard, -97, -135, 0.484, 0.206, 170)
        open = true
        currentView = "wifi"
        scanWifi(false)
        root.runShell("quickshell ipc call notifications close &")
    }

    function openBluetoothMenu() {
        root.setupMenuOrigin(btMenuCard, btCard, 97, -140, 0.484, 0.200, 175)
        open = true
        currentView = "bluetooth"
        refreshBluetooth()
        scanBluetooth()
        root.runShell("quickshell ipc call notifications close &")
    }

    function openSoundMenu() {
        if (currentView === "bluetooth") stopBluetoothScan()
        root.setupMenuOrigin(soundMenuCard, soundCard, 0, 155, 1.0, 0.224, 107)
        open = true
        currentView = "sound"
        root.runShell("quickshell ipc call notifications close &")
    }

    function openScreenTimeMenu() {
        if (currentView === "bluetooth") stopBluetoothScan()
        root.setupMenuOrigin(screenTimeMenuCard, stCard, 97, -73, 0.511, 0.184, 190)
        open = true
        currentView = "screentime"
        refreshScreenTime()
        root.runShell("quickshell ipc call notifications close &")
    }

    function goBack() {
        if (currentView === "bluetooth") stopBluetoothScan()
        currentView = "main"
        wifiPasswordPromptOpen = false
    }

    function formatAppIcon(iconName) {
        if (!iconName) return ""
        try {
            const p = Quickshell.iconPath(iconName)
            if (p) {
                const s = String(p).trim()
                if (s.startsWith("/") && !s.startsWith("//")) return "file://" + s
                return s
            }
        } catch(e) {}
        return ""
    }

    // ── System Process Runners ────────────────────────────────────────
    Process { id: cmdProc }
    function runShell(cmd) {
        cmdProc.command = ["sh", "-c", cmd]
        cmdProc.running = true
    }

    // 1. Wi-Fi Poll & Toggle
    Process {
        id: wifiPollProc
        command: ["sh", "-c", "nmcli -t -f WIFI g; nmcli -t -f active,ssid,signal dev wifi 2>/dev/null | grep '^yes' | head -n 1"]
        stdout: SplitParser {
            onRead: function(line) {
                const trimmed = line.trim()
                if (trimmed === "enabled") {
                    root.wifiEnabled = true
                } else if (trimmed === "disabled") {
                    root.wifiEnabled = false
                    root.wifiConnected = false
                    root.wifiSsid = ""
                } else if (trimmed.startsWith("yes:")) {
                    const parts = trimmed.split(":")
                    if (parts.length >= 3) {
                        root.wifiConnected = true
                        root.wifiSsid = parts[1] || "Connected"
                        root.wifiSignal = parseInt(parts[2]) || 70
                    }
                }
            }
        }
    }

    function toggleWifi() {
        if (wifiEnabled) {
            runShell("nmcli radio wifi off")
            wifiEnabled = false
            wifiConnected = false
            wifiSsid = ""
            wifiNetworks = []
            wifiPasswordPromptOpen = false
        } else {
            runShell("nmcli radio wifi on")
            wifiEnabled = true
            wifiPollTimer.restart()
            if (currentView === "wifi") scanWifi(false)
        }
    }

    // Minimum spinner duration timer
    Timer {
        id: wifiMinSpinTimer
        interval: 800
        repeat: false
        onTriggered: {
            if (!wifiScanProc.running) root.wifiScanning = false
        }
    }

    // Wi-Fi Fast Non-Blocking Scanner
    Process {
        id: wifiScanProc
        command: ["sh", "-c", "nmcli -t -f active,ssid,signal,security dev wifi list --rescan no 2>/dev/null"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                const trimmed = line.trim()
                if (!trimmed) return
                const parts = trimmed.split(":")
                if (parts.length < 4) return
                const isActive = parts[0] === "yes"
                const ssid = parts[1]
                if (!ssid) return
                const signal = parseInt(parts[2]) || 50
                const security = parts[3] || ""
                const isSecured = security !== "" && security !== "--"

                const existingIdx = root._wifiScanBuffer.findIndex(n => n.ssid === ssid)
                if (existingIdx >= 0) {
                    if (signal > root._wifiScanBuffer[existingIdx].signal || isActive) {
                        root._wifiScanBuffer[existingIdx] = { ssid, signal, isSecured, isActive }
                    }
                } else {
                    root._wifiScanBuffer.push({ ssid, signal, isSecured, isActive })
                }
            }
        }
        onExited: function() {
            root._wifiScanBuffer.sort((a, b) => (b.isActive ? 1 : 0) - (a.isActive ? 1 : 0) || b.signal - a.signal)
            root.wifiNetworks = root._wifiScanBuffer.slice()
            if (!wifiMinSpinTimer.running) {
                root.wifiScanning = false
            }
        }
    }

    function scanWifi(forceRescan) {
        if (!wifiEnabled) return
        root.wifiScanning = true
        wifiMinSpinTimer.restart()
        root._wifiScanBuffer = []
        if (forceRescan) {
            wifiScanProc.command = ["sh", "-c", "nmcli dev wifi rescan 2>/dev/null; sleep 0.4; nmcli -t -f active,ssid,signal,security dev wifi list --rescan no 2>/dev/null"]
        } else {
            wifiScanProc.command = ["sh", "-c", "nmcli -t -f active,ssid,signal,security dev wifi list --rescan no 2>/dev/null"]
        }
        wifiScanProc.running = true
    }

    function promptConnectWifi(ssid, isSecured) {
        if (!isSecured) {
            connectWifi(ssid)
            return
        }
        root.wifiSelectedSsid = ssid
        root.wifiSelectedSecured = isSecured
        root.wifiPasswordInput = ""
        root.wifiStatusMsg = ""
        root.wifiConnecting = false
        root.wifiShowPass = false
        root.wifiPasswordPromptOpen = true
    }

    function connectWifi(ssid) {
        root.runShell("nmcli dev wifi connect \"" + ssid + "\" &")
        scanTimer.restart()
        wifiPollTimer.restart()
    }

    Process {
        id: wifiAuthProc
        stdout: SplitParser {
            onRead: function(line) {
                const tr = line.trim()
                if (tr) root.wifiStatusMsg = tr
            }
        }
        onExited: function(exitCode) {
            root.wifiConnecting = false
            if (exitCode === 0) {
                root.wifiStatusMsg = "Connected successfully!"
                root.wifiPasswordPromptOpen = false
                root.wifiPasswordInput = ""
                root.scanWifi(true)
                wifiPollTimer.restart()
            } else {
                root.wifiStatusMsg = "Connection failed. Please check password."
            }
        }
    }

    function submitWifiPassword() {
        if (wifiConnecting) return
        if (wifiPasswordInput.trim() === "" && wifiSelectedSecured) {
            wifiStatusMsg = "Password cannot be empty"
            return
        }
        wifiConnecting = true
        wifiStatusMsg = "Connecting to " + wifiSelectedSsid + "..."
        wifiAuthProc.command = [
            "sh", "-c", 
            "nmcli dev wifi connect \"" + wifiSelectedSsid.replace(/"/g, '\\"') + "\" password \"" + wifiPasswordInput.replace(/"/g, '\\"') + "\" 2>&1"
        ]
        wifiAuthProc.running = true
    }

    function disconnectWifi() {
        runShell("nmcli dev disconnect $(nmcli -t -f DEVICE,TYPE dev 2>/dev/null | grep ':wifi$' | cut -d: -f1 | head -n 1) &")
        root.wifiConnected = false
        root.wifiSsid = ""
        scanWifi(false)
    }

    function forgetWifi(ssid) {
        runShell("nmcli connection delete \"" + ssid + "\" &")
        scanWifi(true)
    }

    // 2. Bluetooth State & Live Stream Backend (bluetooth-service.py)
    function parseBtJson(jsonStr) {
        if (!jsonStr || !jsonStr.startsWith("{")) return
        try {
            const data = JSON.parse(jsonStr)
            root.btPowered = !!data.powered
            root.btDiscovering = !!data.discovering
            root.btConnectedDevice = data.connectedDevice || ""

            if (data.devices) {
                const updated = data.devices.map(d => {
                    const tState = root.btTransientStates[d.mac]
                    if (tState) {
                        if (tState === "connecting" && d.isConnected) {
                            delete root.btTransientStates[d.mac]
                        } else if (tState === "disconnecting" && !d.isConnected) {
                            delete root.btTransientStates[d.mac]
                        } else if (tState === "pairing" && d.isPaired) {
                            delete root.btTransientStates[d.mac]
                        } else {
                            d.state = tState
                        }
                    }
                    return d
                })
                root.btDevices = updated
            }

            if (data.audioCard) {
                root.btCardName = data.audioCard.card_name || ""
                root.btActiveProfile = data.audioCard.active_profile || ""
                root.btAudioProfiles = data.audioCard.profiles || []
            } else {
                root.btCardName = ""
                root.btActiveProfile = ""
                root.btAudioProfiles = []
            }
        } catch (e) {}
    }

    // One-shot state reader
    Process {
        id: btStateProc
        command: ["/home/banana/.config/quickshell/scripts/bluetooth-service.py", "get"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) { root.parseBtJson(line.trim()) }
        }
    }

    // Continuous Live Stream & Discovery Daemon (runs while Bluetooth menu is open)
    Process {
        id: btStreamProc
        command: ["/home/banana/.config/quickshell/scripts/bluetooth-service.py", "stream"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                root.parseBtJson(line.trim())
                if (!btMinSpinTimer.running) root.btScanning = false
            }
        }
    }

    // 10-Second Auto-Timeout for Transient Actions
    Timer {
        id: btActionTimeoutTimer
        interval: 10000
        repeat: false
        onTriggered: {
            root.btTransientStates = ({})
            root.refreshBluetooth()
        }
    }

    function refreshBluetooth() {
        if (!btStateProc.running) btStateProc.running = true
    }

    function toggleBluetooth() {
        if (btPowered) {
            root.btPowered = false
            root.btConnectedDevice = ""
            root.btDevices = []
            root.btAudioProfiles = []
            stopBluetoothScan()
            runShell("/home/banana/.config/quickshell/scripts/bluetooth-service.py power-off &")
        } else {
            root.btPowered = true
            runShell("/home/banana/.config/quickshell/scripts/bluetooth-service.py power-on &")
            btPollTimer.restart()
            if (currentView === "bluetooth") {
                scanBluetooth()
            }
        }
    }

    Timer {
        id: btMinSpinTimer
        interval: 800
        repeat: false
        onTriggered: {
            root.btScanning = false
        }
    }

    function scanBluetooth() {
        if (!btPowered) return
        root.btScanning = true
        btMinSpinTimer.restart()
        if (!btStreamProc.running) {
            btStreamProc.running = true
        }
        refreshBluetooth()
    }

    function stopBluetoothScan() {
        root.btScanning = false
        if (btStreamProc.running) {
            btStreamProc.running = false
        }
    }

    function connectBluetooth(mac) {
        let t = Object.assign({}, root.btTransientStates)
        t[mac] = "connecting"
        root.btTransientStates = t
        root.btDevices = root.btDevices.map(d => d.mac === mac ? Object.assign({}, d, { state: "connecting" }) : d)
        btActionTimeoutTimer.restart()
        runShell("/home/banana/.config/quickshell/scripts/bluetooth-service.py connect " + mac + " &")
        btQuickPollTimer.restart()
    }

    function disconnectBluetooth(mac) {
        let t = Object.assign({}, root.btTransientStates)
        t[mac] = "disconnecting"
        root.btTransientStates = t
        root.btDevices = root.btDevices.map(d => d.mac === mac ? Object.assign({}, d, { state: "disconnecting" }) : d)
        btActionTimeoutTimer.restart()
        runShell("/home/banana/.config/quickshell/scripts/bluetooth-service.py disconnect " + mac + " &")
        btQuickPollTimer.restart()
    }

    function pairBluetooth(mac) {
        let t = Object.assign({}, root.btTransientStates)
        t[mac] = "pairing"
        root.btTransientStates = t
        root.btDevices = root.btDevices.map(d => d.mac === mac ? Object.assign({}, d, { state: "pairing" }) : d)
        btActionTimeoutTimer.restart()
        runShell("/home/banana/.config/quickshell/scripts/bluetooth-service.py pair " + mac + " &")
        btQuickPollTimer.restart()
    }

    function removeBluetooth(mac) {
        root.btDevices = root.btDevices.filter(d => d.mac !== mac)
        runShell("/home/banana/.config/quickshell/scripts/bluetooth-service.py remove " + mac + " &")
        btQuickPollTimer.restart()
    }

    function setBtProfile(profile) {
        if (root.btCardName === "") return
        root.btActiveProfile = profile
        runShell("/home/banana/.config/quickshell/scripts/bluetooth-service.py set-profile " + root.btCardName + " " + profile + " &")
    }

    // Dedicated Screen Lock Runner
    Process {
        id: lockProc
        command: ["sh", "-c", "hyprctl dispatch exec hyprlock || hyprlock &"]
    }

    // 3. Brightness Reader & Setter
    Process {
        id: brightSetProc
    }

    property int _maxBrightness: 0
    property int _curBrightnessRead: 0
    property int _rawBrightness: 0

    Process {
        id: brightStreamProc
        running: true
        command: ["sh", "-c",
            "for b in /sys/class/backlight/*; do " +
            "  if [ -r \"$b/brightness\" ] && [ -r \"$b/max_brightness\" ]; then " +
            "    cat \"$b/brightness\" \"$b/max_brightness\"; " +
            "    while inotifywait -qq -e modify \"$b/brightness\"; do " +
            "      cat \"$b/brightness\"; " +
            "    done; " +
            "    exit; " +
            "  fi; " +
            "done"
        ]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                if (typeof bSliderMouse !== 'undefined' && bSliderMouse.pressed) return
                const val = parseInt(line.trim())
                if (isNaN(val)) return
                if (root._maxBrightness <= 0) {
                    if (root._curBrightnessRead === 0) {
                        root._rawBrightness = val
                        root._curBrightnessRead = 1
                    } else {
                        root._maxBrightness = Math.max(1, val)
                        root.brightnessLevel = Math.max(0.05, Math.min(1.0, root._rawBrightness / root._maxBrightness))
                    }
                } else {
                    root.brightnessLevel = Math.max(0.05, Math.min(1.0, val / root._maxBrightness))
                }
            }
        }
    }

    Process {
        id: brightProc
        command: ["sh", "-c", "brightnessctl -m 2>/dev/null"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                const trimmed = line.trim()
                if (!trimmed) return
                const parts = trimmed.split(",")
                if (parts.length >= 4) {
                    const pctStr = parts[3].replace("%", "").trim()
                    const pct = parseInt(pctStr)
                    if (!isNaN(pct)) {
                        root.brightnessLevel = Math.max(0.05, Math.min(1.0, pct / 100.0))
                    }
                }
            }
        }
    }

    function setBrightness(level) {
        const clamped = Math.max(0.05, Math.min(1.0, level))
        root.brightnessLevel = clamped
        const val = Math.round(clamped * 100)
        brightSetProc.command = ["brightnessctl", "s", val + "%"]
        brightSetProc.running = true
    }

    function refreshStatus() {
        wifiPollProc.running = true
        btStateProc.running = true
        brightProc.running = true
    }

    // Polling Timers
    Timer { id: wifiPollTimer; interval: 6000; running: root.open; repeat: true; onTriggered: wifiPollProc.running = true }
    Timer { id: btPollTimer; interval: 6000; running: root.open && root.currentView !== "bluetooth"; repeat: true; onTriggered: refreshBluetooth() }   // exempt BT view — btStreamProc handles real-time updates there
    Timer { id: btQuickPollTimer; interval: 700; repeat: false; onTriggered: refreshBluetooth() }
    Timer { id: scanTimer; interval: 1500; repeat: false; onTriggered: scanWifi(false) }
    Timer { id: btScanTimer; interval: 1500; repeat: false; onTriggered: scanBluetooth() }

    // ── Click Outside to Dismiss ──────────────────────────────────────
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        hoverEnabled: false
        focus: root.open

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                if (root.wifiPasswordPromptOpen) {
                    root.cancelWifiPasswordPrompt()
                } else if (root.currentView !== "main") {
                    root.goBack()
                } else {
                    root.close()
                }
                event.accepted = true
            }
        }
        onClicked: function(mouse) {
            const pad = 10
            const inPanel = (mouse.x >= panelWrapper.x - pad && mouse.x <= panelWrapper.x + panelWrapper.width + pad &&
                             mouse.y >= panelWrapper.y - pad && mouse.y <= panelWrapper.y + panelWrapper.height + pad)
            if (!inPanel) {
                root.close()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // MAIN PANEL WRAPPER (376px Compact Width)
    // ══════════════════════════════════════════════════════════════════
    Item {
        id: panelWrapper
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 8
        anchors.rightMargin: 16
        width: 376
        implicitHeight: {
            if (root.currentView === "wifi") return wifiMenuCard.height
            if (root.currentView === "bluetooth") return btMenuCard.height
            if (root.currentView === "sound") return soundMenuCard.height
            if (root.currentView === "screentime") return screenTimeMenuCard.height
            return mainLayout.implicitHeight
        }
        height: implicitHeight

        transform: [
            Scale {
                origin.x: panelWrapper.width
                origin.y: 0
                xScale: root.open ? 1.0 : 0.95
                yScale: root.open ? 1.0 : 0.95
                Behavior on xScale { NumberAnimation { duration: root.open ? 240 : 800; easing.type: Easing.OutCubic } }
                Behavior on yScale { NumberAnimation { duration: root.open ? 240 : 800; easing.type: Easing.OutCubic } }
            },
            Translate {
                y: root.open ? 0 : -10
                Behavior on y { NumberAnimation { duration: root.open ? 240 : 800; easing.type: Easing.OutCubic } }
            }
        ]

        opacity: root.open ? 1.0 : 0.0
        visible: opacity > 0.001

        Behavior on opacity { NumberAnimation { duration: root.open ? 195 : 820; easing.type: Easing.OutQuad } }

        // Spring-animate height when already open (view switching).
        Behavior on height {
            enabled: root.open && panelWrapper.opacity > 0.9
            NumberAnimation {
                duration: 600
                easing.type: Easing.BezierSpline
                easing.bezierCurve: root.springCurve
            }
        }

        ColumnLayout {
            id: mainLayout
            width: 376
            spacing: 12

            // Dynamic Island-style entrance/exit via state machine
            property real contentScale: 1.0
            property real contentTransY: 0.0
            opacity: 1.0
            visible: opacity > 0.001

            transform: [
                Scale {
                    origin.x: mainLayout.width / 2
                    origin.y: 0
                    xScale: mainLayout.contentScale
                    yScale: mainLayout.contentScale
                },
                Translate { y: mainLayout.contentTransY }
            ]

            states: [
                State {
                    name: "visible"
                    when: root.currentView === "main"
                    PropertyChanges { target: mainLayout; opacity: 1.0; contentScale: 1.0; contentTransY: 0 }
                },
                State {
                    name: "hidden"
                    when: root.currentView !== "main"
                    PropertyChanges { target: mainLayout; opacity: 0.0; contentScale: 1.0; contentTransY: 0 }
                }
            ]

            transitions: [
                // Returning to main — smoothly cross-fade as submenu merges into widget
                Transition {
                    from: "hidden"; to: "visible"
                    SequentialAnimation {
                        PauseAnimation { duration: 160 }
                        NumberAnimation {
                            target: mainLayout; property: "opacity"
                            duration: 320; easing.type: Easing.OutQuad
                        }
                    }
                },
                // Leaving main — snap out fast as submenu expands
                Transition {
                    from: "visible"; to: "hidden"
                    NumberAnimation {
                        target: mainLayout; property: "opacity"
                        duration: 80; easing.type: Easing.OutQuad
                    }
                }
            ]

            // 1. TOP 2x2 MODULAR GRID (70px Height, Compact Padding)
            GridLayout {

                Layout.fillWidth: true
                columns: 2
                columnSpacing: 12
                rowSpacing: 12

                // 1.1 Wi-Fi Pill
                LiquidGlassCard {
                    id: wifiCard
                    Layout.fillWidth: true
                    Layout.preferredHeight: 70
                    cardRadius: 35
                    isHovered: wifiCardMouse.containsMouse || wifiBadgeMouse.containsMouse
                    isPressed: wifiCardMouse.pressed || wifiBadgeMouse.pressed

                    

                    transform: [
                        Scale {
                            id: wifiScale
                            origin.x: wifiCard.width / 2
                            origin.y: wifiCard.height / 2
                            xScale: 0.75
                            yScale: 0.75
                        },
                        Translate {
                            id: wifiTrans
                            y: -20
                        }
                    ]
                    opacity: 0.0

                    state: root.open ? "open" : "closed"
                    states: [
                        State {
                            name: "open"
                            PropertyChanges { target: wifiScale; xScale: 1.0; yScale: 1.0 }
                            PropertyChanges { target: wifiTrans; y: 0 }
                            PropertyChanges { target: wifiCard; opacity: 1.0 }
                        },
                        State {
                            name: "closed"
                            PropertyChanges { target: wifiScale; xScale: 0.75; yScale: 0.75 }
                            PropertyChanges { target: wifiTrans; y: -20 }
                            PropertyChanges { target: wifiCard; opacity: 0.0 }
                        }
                    ]
                    transitions: [
                        Transition {
                            from: "closed"; to: "open"
                            SequentialAnimation {
                                PropertyAction { target: wifiTrans; property: "y"; value: -20 }
                                PropertyAction { target: wifiScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: wifiScale; property: "yScale"; value: 0.75 }
                                PropertyAction { target: wifiCard; property: "opacity"; value: 1.0 }
                                ParallelAnimation {
                                    NumberAnimation { target: wifiTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: wifiScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: wifiScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                }
                            }
                        },
                        Transition {
                            from: "open"; to: "closed"
                            SequentialAnimation {
                                PauseAnimation { duration: 108 }
                                ParallelAnimation {
                                    NumberAnimation { target: wifiTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: wifiScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: wifiScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    SequentialAnimation {
                                        PauseAnimation { duration: 250 }
                                        NumberAnimation { target: wifiCard; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                    }
                                }
                                PropertyAction { target: wifiTrans; property: "y"; value: -20 }
                                PropertyAction { target: wifiScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: wifiScale; property: "yScale"; value: 0.75 }
                            }
                        }
                    ]

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.topMargin: 8
                        anchors.bottomMargin: 8
                        spacing: 10

                        // Badge: click to toggle
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 46
                            Layout.preferredHeight: 46
                            radius: 23
                            color: "#ffffff"
                            border.color: "#60ffffff"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                font.family: root.iconFont
                                font.pixelSize: 24
                                color: root.wifiEnabled ? "#007aff" : "#000000"
                                text: root.wifiEnabled ? (root.wifiConnected ? "󰖩" : "󰤨") : "󰤮"
                                renderType: Text.QtRendering
                            }

                            MouseArea {
                                id: wifiBadgeMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleWifi()
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2

                            Text {
                                text: "Wi-Fi"
                                font.family: root.sfFont
                                font.pixelSize: 16
                                color: "#ffffff"
                                renderType: Text.QtRendering
                            }

                            Text {
                                text: root.wifiEnabled
                                    ? (root.wifiConnected ? root.wifiSsid : "Available")
                                    : "Off"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: "#93c5fd"
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                renderType: Text.QtRendering
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            font.family: root.iconFont
                            font.pixelSize: 14
                            color: "#7dd3fc"
                            text: "󰅂"
                            renderType: Text.QtRendering
                        }
                    }

                    MouseArea {
                        id: wifiCardMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        z: -1
                        onClicked: root.openWifiMenu()
                    }
                }

                // 1.2 Bluetooth Pill
                LiquidGlassCard {
                    id: btCard
                    Layout.fillWidth: true
                    Layout.preferredHeight: 70
                    cardRadius: 35
                    isHovered: btCardMouse.containsMouse || btBadgeMouse.containsMouse
                    isPressed: btCardMouse.pressed || btBadgeMouse.pressed

                    

                    transform: [
                        Scale {
                            id: btScale
                            origin.x: btCard.width / 2
                            origin.y: btCard.height / 2
                            xScale: 0.75
                            yScale: 0.75
                        },
                        Translate {
                            id: btTrans
                            y: -20
                        }
                    ]
                    opacity: 0.0

                    state: root.open ? "open" : "closed"
                    states: [
                        State {
                            name: "open"
                            PropertyChanges { target: btScale; xScale: 1.0; yScale: 1.0 }
                            PropertyChanges { target: btTrans; y: 0 }
                            PropertyChanges { target: btCard; opacity: 1.0 }
                        },
                        State {
                            name: "closed"
                            PropertyChanges { target: btScale; xScale: 0.75; yScale: 0.75 }
                            PropertyChanges { target: btTrans; y: -20 }
                            PropertyChanges { target: btCard; opacity: 0.0 }
                        }
                    ]
                    transitions: [
                        Transition {
                            from: "closed"; to: "open"
                            SequentialAnimation {
                                PropertyAction { target: btTrans; property: "y"; value: -20 }
                                PropertyAction { target: btScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: btScale; property: "yScale"; value: 0.75 }
                                PropertyAction { target: btCard; property: "opacity"; value: 1.0 }
                                ParallelAnimation {
                                    NumberAnimation { target: btTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: btScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: btScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                }
                            }
                        },
                        Transition {
                            from: "open"; to: "closed"
                            SequentialAnimation {
                                PauseAnimation { duration: 108 }
                                ParallelAnimation {
                                    NumberAnimation { target: btTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: btScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: btScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    SequentialAnimation {
                                        PauseAnimation { duration: 250 }
                                        NumberAnimation { target: btCard; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                    }
                                }
                                PropertyAction { target: btTrans; property: "y"; value: -20 }
                                PropertyAction { target: btScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: btScale; property: "yScale"; value: 0.75 }
                            }
                        }
                    ]

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.topMargin: 8
                        anchors.bottomMargin: 8
                        spacing: 10

                        // Badge: click to toggle
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 46
                            Layout.preferredHeight: 46
                            radius: 23
                            color: "#ffffff"
                            border.color: "#60ffffff"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                font.family: root.iconFont
                                font.pixelSize: 24
                                color: root.btPowered ? "#007aff" : "#000000"
                                text: root.btPowered ? "󰂯" : "󰂲"
                                renderType: Text.QtRendering
                            }

                            MouseArea {
                                id: btBadgeMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleBluetooth()
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2

                            Text {
                                text: "Bluetooth"
                                font.family: root.sfFont
                                font.pixelSize: 16
                                color: "#ffffff"
                                renderType: Text.QtRendering
                            }

                            Text {
                                text: root.btPowered
                                    ? (root.btConnectedDevice !== "" ? root.btConnectedDevice : "On")
                                    : "Off"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: "#93c5fd"
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                renderType: Text.QtRendering
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            font.family: root.iconFont
                            font.pixelSize: 14
                            color: "#7dd3fc"
                            text: "󰅂"
                            renderType: Text.QtRendering
                        }
                    }

                    MouseArea {
                        id: btCardMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        z: -1
                        onClicked: root.openBluetoothMenu()
                    }
                }

                // 1.3 Dark Mode / Night Light
                LiquidGlassCard {
                    id: darkPill
                    Layout.fillWidth: true
                    Layout.preferredHeight: 70
                    cardRadius: 35
                    isHovered: darkMouse.containsMouse
                    isPressed: darkMouse.pressed
                    isActive: true
                    activeColor: root.darkModeActive ? "#90111a24" : Qt.rgba(0.08, 0.40, 0.92, 0.85)

                    

                    transform: [
                        Scale {
                            id: darkScale
                            origin.x: darkPill.width / 2
                            origin.y: darkPill.height / 2
                            xScale: 0.75
                            yScale: 0.75
                        },
                        Translate {
                            id: darkTrans
                            y: -20
                        }
                    ]
                    opacity: 0.0

                    state: root.open ? "open" : "closed"
                    states: [
                        State {
                            name: "open"
                            PropertyChanges { target: darkScale; xScale: 1.0; yScale: 1.0 }
                            PropertyChanges { target: darkTrans; y: 0 }
                            PropertyChanges { target: darkPill; opacity: 1.0 }
                        },
                        State {
                            name: "closed"
                            PropertyChanges { target: darkScale; xScale: 0.75; yScale: 0.75 }
                            PropertyChanges { target: darkTrans; y: -20 }
                            PropertyChanges { target: darkPill; opacity: 0.0 }
                        }
                    ]
                    transitions: [
                        Transition {
                            from: "closed"; to: "open"
                            SequentialAnimation {
                                PropertyAction { target: darkTrans; property: "y"; value: -20 }
                                PropertyAction { target: darkScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: darkScale; property: "yScale"; value: 0.75 }
                                PropertyAction { target: darkPill; property: "opacity"; value: 1.0 }
                                PauseAnimation { duration: 38 }
                                ParallelAnimation {
                                    NumberAnimation { target: darkTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: darkScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: darkScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                }
                            }
                        },
                        Transition {
                            from: "open"; to: "closed"
                            SequentialAnimation {
                                PauseAnimation { duration: 70 }
                                ParallelAnimation {
                                    NumberAnimation { target: darkTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: darkScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: darkScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    SequentialAnimation {
                                        PauseAnimation { duration: 250 }
                                        NumberAnimation { target: darkPill; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                    }
                                }
                                PropertyAction { target: darkTrans; property: "y"; value: -20 }
                                PropertyAction { target: darkScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: darkScale; property: "yScale"; value: 0.75 }
                            }
                        }
                    ]

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.topMargin: 8
                        anchors.bottomMargin: 8
                        spacing: 10

                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 46
                            Layout.preferredHeight: 46
                            radius: 23
                            color: "#ffffff"
                            border.color: "#60ffffff"
                            border.width: 1

                            Item {
                                anchors.centerIn: parent
                                width: 24
                                height: 24

                                Canvas {
                                    id: dmIconCanvas
                                    anchors.fill: parent
                                    renderTarget: Canvas.Image
                                    onPaint: {
                                        const ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        const cx = width / 2
                                        const cy = height / 2
                                        const R = 10.5
                                        const r = 5.2
                                        const col = root.darkModeActive ? "#000000" : "#007aff"

                                        // 1. Outer full ring
                                        ctx.strokeStyle = col
                                        ctx.lineWidth = 1.8
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, R, 0, Math.PI * 2)
                                        ctx.stroke()

                                        // 2. Vertical center split line
                                        ctx.beginPath()
                                        ctx.moveTo(cx, cy - R)
                                        ctx.lineTo(cx, cy + R)
                                        ctx.stroke()

                                        // 3. Right outer crescent (between r and R)
                                        ctx.fillStyle = col
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, R, -Math.PI / 2, Math.PI / 2, false)
                                        ctx.arc(cx, cy, r, Math.PI / 2, -Math.PI / 2, true)
                                        ctx.closePath()
                                        ctx.fill()

                                        // 4. Left inner semicircle (radius r)
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, r, Math.PI / 2, 3 * Math.PI / 2, false)
                                        ctx.closePath()
                                        ctx.fill()
                                    }

                                    Connections {
                                        target: root
                                        function onDarkModeActiveChanged() { dmIconCanvas.requestPaint() }
                                    }
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2

                            Text {
                                text: "Dark Mode"
                                font.family: root.sfFont
                                font.pixelSize: 16
                                color: "#ffffff"
                                renderType: Text.QtRendering
                            }

                            Text {
                                text: root.darkModeActive ? "On" : "Off"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: root.darkModeActive ? "#94a3b8" : "#93c5fd"
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                renderType: Text.QtRendering
                            }
                        }
                    }

                    MouseArea {
                        id: darkMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Theme.toggleDarkMode()
                    }
                }

                // 1.4 Focus / Do Not Disturb Pill
                LiquidGlassCard {
                    id: dndCard
                    Layout.fillWidth: true
                    Layout.preferredHeight: 70
                    cardRadius: 35
                    isHovered: dndMouse.containsMouse
                    isPressed: dndMouse.pressed
                    isActive: root.dndActive
                    activeColor: Qt.rgba(0.55, 0.20, 0.85, 0.85)

                    

                    transform: [
                        Scale {
                            id: dndScale
                            origin.x: dndCard.width / 2
                            origin.y: dndCard.height / 2
                            xScale: 0.75
                            yScale: 0.75
                        },
                        Translate {
                            id: dndTrans
                            y: -20
                        }
                    ]
                    opacity: 0.0

                    state: root.open ? "open" : "closed"
                    states: [
                        State {
                            name: "open"
                            PropertyChanges { target: dndScale; xScale: 1.0; yScale: 1.0 }
                            PropertyChanges { target: dndTrans; y: 0 }
                            PropertyChanges { target: dndCard; opacity: 1.0 }
                        },
                        State {
                            name: "closed"
                            PropertyChanges { target: dndScale; xScale: 0.75; yScale: 0.75 }
                            PropertyChanges { target: dndTrans; y: -20 }
                            PropertyChanges { target: dndCard; opacity: 0.0 }
                        }
                    ]
                    transitions: [
                        Transition {
                            from: "closed"; to: "open"
                            SequentialAnimation {
                                PropertyAction { target: dndTrans; property: "y"; value: -20 }
                                PropertyAction { target: dndScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: dndScale; property: "yScale"; value: 0.75 }
                                PropertyAction { target: dndCard; property: "opacity"; value: 1.0 }
                                PauseAnimation { duration: 38 }
                                ParallelAnimation {
                                    NumberAnimation { target: dndTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: dndScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: dndScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                }
                            }
                        },
                        Transition {
                            from: "open"; to: "closed"
                            SequentialAnimation {
                                PauseAnimation { duration: 70 }
                                ParallelAnimation {
                                    NumberAnimation { target: dndTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: dndScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: dndScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    SequentialAnimation {
                                        PauseAnimation { duration: 250 }
                                        NumberAnimation { target: dndCard; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                    }
                                }
                                PropertyAction { target: dndTrans; property: "y"; value: -20 }
                                PropertyAction { target: dndScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: dndScale; property: "yScale"; value: 0.75 }
                            }
                        }
                    ]

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.topMargin: 8
                        anchors.bottomMargin: 8
                        spacing: 10

                        Rectangle {
                            id: focusBadge
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 46
                            Layout.preferredHeight: 46
                            radius: 23
                            color: "#ffffff"
                            border.color: "#60ffffff"
                            border.width: 1

                            scale: root.dndActive ? 1.05 : 1.0
                            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }

                            Text {
                                anchors.centerIn: parent
                                font.family: root.iconFont
                                font.pixelSize: 24
                                color: root.dndActive ? "#9333ea" : "#000000"
                                text: "󰖔"
                                renderType: Text.QtRendering
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2

                            Text {
                                text: "Focus"
                                font.family: root.sfFont
                                font.pixelSize: 16
                                color: "#ffffff"
                                renderType: Text.QtRendering
                            }

                            Text {
                                text: root.dndActive ? "Do Not Disturb" : "Off"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: root.dndActive ? "#f5d0fe" : "#93c5fd"
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                renderType: Text.QtRendering
                            }
                        }
                    }

                    MouseArea {
                        id: dndMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.dndActive = !root.dndActive
                        }
                    }
                }
            }

            // ══════════════════════════════════════════════════════════
            // 2. CONNECTED DEVICES & SCREEN TIME MODULAR SECTION (156px Height)
            // ══════════════════════════════════════════════════════════
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                // 2.1 Left: 2x2 Connected Devices Battery Widget (182x156)
                ConnectedDevicesWidget {
                    id: devicesWidget
                    Layout.preferredWidth: 182
                    Layout.preferredHeight: 156

                    transform: [
                        Scale {
                            id: devScale
                            origin.x: devicesWidget.width / 2
                            origin.y: devicesWidget.height / 2
                            xScale: 0.75
                            yScale: 0.75
                        },
                        Translate {
                            id: devTrans
                            y: -20
                        }
                    ]
                    opacity: 0.0

                    state: root.open ? "open" : "closed"
                    states: [
                        State {
                            name: "open"
                            PropertyChanges { target: devScale; xScale: 1.0; yScale: 1.0 }
                            PropertyChanges { target: devTrans; y: 0 }
                            PropertyChanges { target: devicesWidget; opacity: 1.0 }
                        },
                        State {
                            name: "closed"
                            PropertyChanges { target: devScale; xScale: 0.75; yScale: 0.75 }
                            PropertyChanges { target: devTrans; y: -20 }
                            PropertyChanges { target: devicesWidget; opacity: 0.0 }
                        }
                    ]
                    transitions: [
                        Transition {
                            from: "closed"; to: "open"
                            SequentialAnimation {
                                PropertyAction { target: devTrans; property: "y"; value: -20 }
                                PropertyAction { target: devScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: devScale; property: "yScale"; value: 0.75 }
                                PropertyAction { target: devicesWidget; property: "opacity"; value: 1.0 }
                                PauseAnimation { duration: 70 }
                                ParallelAnimation {
                                    NumberAnimation { target: devTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: devScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: devScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                }
                            }
                        },
                        Transition {
                            from: "open"; to: "closed"
                            SequentialAnimation {
                                PauseAnimation { duration: 38 }
                                ParallelAnimation {
                                    NumberAnimation { target: devTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: devScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: devScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    SequentialAnimation {
                                        PauseAnimation { duration: 250 }
                                        NumberAnimation { target: devicesWidget; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                    }
                                }
                                PropertyAction { target: devTrans; property: "y"; value: -20 }
                                PropertyAction { target: devScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: devScale; property: "yScale"; value: 0.75 }
                            }
                        }
                    ]
                }

                // 2.2 Right Column: Screen Time Widget (Top) + Lock & Camera (Bottom)
                ColumnLayout {
                    Layout.preferredWidth: 182
                    Layout.preferredHeight: 156
                    spacing: 12

                    // 2.2.1 Screen On Time Capsule Widget (182x70)
                    ScreenTimeWidget {
                        id: stCard
                        Layout.preferredWidth: 182
                        Layout.preferredHeight: 70
                        onClicked: root.openScreenTimeMenu()

                        transform: [
                            Scale {
                                id: stScale
                                origin.x: stCard.width / 2
                                origin.y: stCard.height / 2
                                xScale: 0.75
                                yScale: 0.75
                            },
                            Translate {
                                id: stTrans
                                y: -20
                            }
                        ]
                        opacity: 0.0

                        state: root.open ? "open" : "closed"
                        states: [
                            State {
                                name: "open"
                                PropertyChanges { target: stScale; xScale: 1.0; yScale: 1.0 }
                                PropertyChanges { target: stTrans; y: 0 }
                                PropertyChanges { target: stCard; opacity: 1.0 }
                            },
                            State {
                                name: "closed"
                                PropertyChanges { target: stScale; xScale: 0.75; yScale: 0.75 }
                                PropertyChanges { target: stTrans; y: -20 }
                                PropertyChanges { target: stCard; opacity: 0.0 }
                            }
                        ]
                        transitions: [
                            Transition {
                                from: "closed"; to: "open"
                                SequentialAnimation {
                                    PropertyAction { target: stTrans; property: "y"; value: -20 }
                                    PropertyAction { target: stScale; property: "xScale"; value: 0.75 }
                                    PropertyAction { target: stScale; property: "yScale"; value: 0.75 }
                                    PropertyAction { target: stCard; property: "opacity"; value: 1.0 }
                                    PauseAnimation { duration: 70 }
                                    ParallelAnimation {
                                        NumberAnimation { target: stTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                        NumberAnimation { target: stScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                        NumberAnimation { target: stScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    }
                                }
                            },
                            Transition {
                                from: "open"; to: "closed"
                                SequentialAnimation {
                                    PauseAnimation { duration: 38 }
                                    ParallelAnimation {
                                        NumberAnimation { target: stTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                        NumberAnimation { target: stScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                        NumberAnimation { target: stScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                        SequentialAnimation {
                                            PauseAnimation { duration: 250 }
                                            NumberAnimation { target: stCard; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                        }
                                    }
                                    PropertyAction { target: stTrans; property: "y"; value: -20 }
                                    PropertyAction { target: stScale; property: "xScale"; value: 0.75 }
                                    PropertyAction { target: stScale; property: "yScale"; value: 0.75 }
                                }
                            }
                        ]
                    }

                    // 2.2.2 Lower Row: Reverted to Older 1x1 Circle Action Icons (74x74)
                    RowLayout {
                        Layout.preferredWidth: 182
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 18

                        // 1x1 Lock Screen Circular Button (74x74, radius 37)
                        LiquidGlassCard {
                            id: lockCard
                            Layout.preferredWidth: 74
                            Layout.preferredHeight: 74
                            cardRadius: 37
                            isHovered: lockBtnMouse.containsMouse
                            isPressed: lockBtnMouse.pressed

                            

                            transform: [
                        Scale {
                            id: lockScale
                            origin.x: lockCard.width / 2
                            origin.y: lockCard.height / 2
                            xScale: 0.75
                            yScale: 0.75
                        },
                        Translate {
                            id: lockTrans
                            y: -20
                        }
                    ]
                    opacity: 0.0

                    state: root.open ? "open" : "closed"
                    states: [
                        State {
                            name: "open"
                            PropertyChanges { target: lockScale; xScale: 1.0; yScale: 1.0 }
                            PropertyChanges { target: lockTrans; y: 0 }
                            PropertyChanges { target: lockCard; opacity: 1.0 }
                        },
                        State {
                            name: "closed"
                            PropertyChanges { target: lockScale; xScale: 0.75; yScale: 0.75 }
                            PropertyChanges { target: lockTrans; y: -20 }
                            PropertyChanges { target: lockCard; opacity: 0.0 }
                        }
                    ]
                    transitions: [
                        Transition {
                            from: "closed"; to: "open"
                            SequentialAnimation {
                                PropertyAction { target: lockTrans; property: "y"; value: -20 }
                                PropertyAction { target: lockScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: lockScale; property: "yScale"; value: 0.75 }
                                PropertyAction { target: lockCard; property: "opacity"; value: 1.0 }
                                PauseAnimation { duration: 70 }
                                ParallelAnimation {
                                    NumberAnimation { target: lockTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: lockScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: lockScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                }
                            }
                        },
                        Transition {
                            from: "open"; to: "closed"
                            SequentialAnimation {
                                PauseAnimation { duration: 38 }
                                ParallelAnimation {
                                    NumberAnimation { target: lockTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: lockScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: lockScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    SequentialAnimation {
                                        PauseAnimation { duration: 250 }
                                        NumberAnimation { target: lockCard; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                    }
                                }
                                PropertyAction { target: lockTrans; property: "y"; value: -20 }
                                PropertyAction { target: lockScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: lockScale; property: "yScale"; value: 0.75 }
                            }
                        }
                    ]

                    Text {
                                anchors.centerIn: parent
                                font.family: root.iconFont
                                font.pixelSize: 30
                                color: "#ffffff"
                                text: "󰌾"
                                renderType: Text.QtRendering
                            }

                            MouseArea {
                                id: lockBtnMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.close()
                                    lockProc.running = false
                                    lockProc.running = true
                                }
                            }
                        }

                        // 1x1 Camera / Screenshot Circular Button (74x74, radius 37)
                        LiquidGlassCard {
                            id: shotCard
                            Layout.preferredWidth: 74
                            Layout.preferredHeight: 74
                            cardRadius: 37
                            isHovered: shotBtnMouse.containsMouse
                            isPressed: shotBtnMouse.pressed

                            

                            transform: [
                        Scale {
                            id: shotScale
                            origin.x: shotCard.width / 2
                            origin.y: shotCard.height / 2
                            xScale: 0.75
                            yScale: 0.75
                        },
                        Translate {
                            id: shotTrans
                            y: -20
                        }
                    ]
                    opacity: 0.0

                    state: root.open ? "open" : "closed"
                    states: [
                        State {
                            name: "open"
                            PropertyChanges { target: shotScale; xScale: 1.0; yScale: 1.0 }
                            PropertyChanges { target: shotTrans; y: 0 }
                            PropertyChanges { target: shotCard; opacity: 1.0 }
                        },
                        State {
                            name: "closed"
                            PropertyChanges { target: shotScale; xScale: 0.75; yScale: 0.75 }
                            PropertyChanges { target: shotTrans; y: -20 }
                            PropertyChanges { target: shotCard; opacity: 0.0 }
                        }
                    ]
                    transitions: [
                        Transition {
                            from: "closed"; to: "open"
                            SequentialAnimation {
                                PropertyAction { target: shotTrans; property: "y"; value: -20 }
                                PropertyAction { target: shotScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: shotScale; property: "yScale"; value: 0.75 }
                                PropertyAction { target: shotCard; property: "opacity"; value: 1.0 }
                                PauseAnimation { duration: 70 }
                                ParallelAnimation {
                                    NumberAnimation { target: shotTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: shotScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: shotScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                }
                            }
                        },
                        Transition {
                            from: "open"; to: "closed"
                            SequentialAnimation {
                                PauseAnimation { duration: 38 }
                                ParallelAnimation {
                                    NumberAnimation { target: shotTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: shotScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: shotScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    SequentialAnimation {
                                        PauseAnimation { duration: 250 }
                                        NumberAnimation { target: shotCard; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                    }
                                }
                                PropertyAction { target: shotTrans; property: "y"; value: -20 }
                                PropertyAction { target: shotScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: shotScale; property: "yScale"; value: 0.75 }
                            }
                        }
                    ]

                    Text {
                                anchors.centerIn: parent
                                font.family: root.iconFont
                                font.pixelSize: 30
                                color: "#a78bfa"
                                text: "󰆐"
                                renderType: Text.QtRendering
                            }

                            MouseArea {
                                id: shotBtnMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.close()
                                    root.runShell("~/.config/quickshell/scripts/screenshot.sh --area &")
                                }
                            }
                        }
                    }
                }
            }

            // ══════════════════════════════════════════════════════════
            // 3. SLIDERS WITH 11 PRECISION LEVEL TICK MARKERS (82px Height)
            // ══════════════════════════════════════════════════════════

            // 3.1 Display Brightness Card
            LiquidGlassCard {
                id: dispCard
                Layout.preferredWidth: 376
                Layout.preferredHeight: 74
                cardRadius: 24
                isHovered: dispCardMouse.containsMouse || bSliderMouse.containsMouse

                

                transform: [
                        Scale {
                            id: dispScale
                            origin.x: dispCard.width / 2
                            origin.y: dispCard.height / 2
                            xScale: 0.75
                            yScale: 0.75
                        },
                        Translate {
                            id: dispTrans
                            y: -20
                        }
                    ]
                    opacity: 0.0

                    state: root.open ? "open" : "closed"
                    states: [
                        State {
                            name: "open"
                            PropertyChanges { target: dispScale; xScale: 1.0; yScale: 1.0 }
                            PropertyChanges { target: dispTrans; y: 0 }
                            PropertyChanges { target: dispCard; opacity: 1.0 }
                        },
                        State {
                            name: "closed"
                            PropertyChanges { target: dispScale; xScale: 0.75; yScale: 0.75 }
                            PropertyChanges { target: dispTrans; y: -20 }
                            PropertyChanges { target: dispCard; opacity: 0.0 }
                        }
                    ]
                    transitions: [
                        Transition {
                            from: "closed"; to: "open"
                            SequentialAnimation {
                                PropertyAction { target: dispTrans; property: "y"; value: -20 }
                                PropertyAction { target: dispScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: dispScale; property: "yScale"; value: 0.75 }
                                PropertyAction { target: dispCard; property: "opacity"; value: 1.0 }
                                PauseAnimation { duration: 108 }
                                ParallelAnimation {
                                    NumberAnimation { target: dispTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: dispScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: dispScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                }
                            }
                        },
                        Transition {
                            from: "open"; to: "closed"
                            SequentialAnimation {
                                ParallelAnimation {
                                    NumberAnimation { target: dispTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: dispScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: dispScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    SequentialAnimation {
                                        PauseAnimation { duration: 250 }
                                        NumberAnimation { target: dispCard; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                    }
                                }
                                PropertyAction { target: dispTrans; property: "y"; value: -20 }
                                PropertyAction { target: dispScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: dispScale; property: "yScale"; value: 0.75 }
                            }
                        }
                    ]

                    MouseArea {
                    id: dispCardMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.ArrowCursor
                    z: -1
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: 9
                    anchors.bottomMargin: 8
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 2

                    Text {
                        text: "Display"
                        font.family: root.sfFont
                        font.pixelSize: 16
                        color: "#ffffff"
                        renderType: Text.QtRendering
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            font.family: root.iconFont
                            font.pixelSize: 19
                            color: "#ffffff"
                            text: "󰃞"
                            renderType: Text.QtRendering
                        }

                        // Slider Track + 11-Step Level Tick Markers
                        Item {
                            id: bSlider
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            implicitHeight: 28

                            Rectangle {
                                id: bTrack
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: 8
                                radius: 4
                                color: "#2effffff"
                                border.color: "#40ffffff"
                                border.width: 1

                                Rectangle {
                                    height: parent.height
                                    radius: parent.radius
                                    color: "#ffffff"
                                    width: bTrack.width * root.brightnessLevel
                                }

                                Rectangle {
                                    id: bKnob
                                    width: 16
                                    height: 16
                                    radius: 8
                                    color: "#ffffff"
                                    border.color: "#e2e8f0"
                                    border.width: 1.5
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: Math.max(0, Math.min(bTrack.width - 16, bTrack.width * root.brightnessLevel - 8))

                                    opacity: bSliderMouse.containsMouse || bSliderMouse.pressed ? 1.0 : 0.0
                                    scale: bSliderMouse.containsMouse || bSliderMouse.pressed ? 1.0 : 0.5

                                    Behavior on opacity { NumberAnimation { duration: 150 } }
                                    Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }
                                }
                            }

                            // 11 Precision Level Indicator Ticks Under Slider (No min/max ticks)
                            Item {
                                id: bTickContainer
                                anchors.left: bTrack.left
                                anchors.right: bTrack.right
                                anchors.top: bTrack.bottom
                                anchors.topMargin: 2
                                height: 6

                                Repeater {
                                    model: 11
                                    Rectangle {
                                        property real progress: index / 10.0
                                        x: Math.round(progress * (bTickContainer.width - width))
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: index === 5 ? 2 : 1.5
                                        height: index === 5 ? 5 : 3
                                        radius: 1
                                        color: progress <= root.brightnessLevel ? "#ffffff" : "#45ffffff"
                                        opacity: progress <= root.brightnessLevel ? 0.95 : 0.4
                                        visible: index > 0 && index < 10
                                        Behavior on color { ColorAnimation { duration: 100 } }
                                    }
                                }
                            }

                            MouseArea {
                                id: bSliderMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                preventStealing: true
                                function updateVal(mouseX) {
                                    const v = Math.max(0.05, Math.min(1.0, mouseX / bTrack.width))
                                    root.setBrightness(v)
                                }
                                onPressed: function(m) { updateVal(m.x) }
                                onPositionChanged: function(m) { if (pressed) updateVal(m.x) }
                                onWheel: function(w) {
                                    const delta = w.angleDelta.y > 0 ? 0.05 : -0.05
                                    root.setBrightness(Math.max(0.05, Math.min(1.0, root.brightnessLevel + delta)))
                                }
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            font.family: root.iconFont
                            font.pixelSize: 19
                            color: "#ffffff"
                            text: "󰃠"
                            renderType: Text.QtRendering
                        }
                    }
                }
            }

            // 3.2 Sound Master Volume Card
            LiquidGlassCard {
                id: soundCard
                Layout.preferredWidth: 376
                Layout.preferredHeight: 74
                cardRadius: 24
                isHovered: soundCardMouse.containsMouse || vSliderMouse.containsMouse || sinkMouse.containsMouse

                

                transform: [
                        Scale {
                            id: soundScale
                            origin.x: soundCard.width / 2
                            origin.y: soundCard.height / 2
                            xScale: 0.75
                            yScale: 0.75
                        },
                        Translate {
                            id: soundTrans
                            y: -20
                        }
                    ]
                    opacity: 0.0

                    state: root.open ? "open" : "closed"
                    states: [
                        State {
                            name: "open"
                            PropertyChanges { target: soundScale; xScale: 1.0; yScale: 1.0 }
                            PropertyChanges { target: soundTrans; y: 0 }
                            PropertyChanges { target: soundCard; opacity: 1.0 }
                        },
                        State {
                            name: "closed"
                            PropertyChanges { target: soundScale; xScale: 0.75; yScale: 0.75 }
                            PropertyChanges { target: soundTrans; y: -20 }
                            PropertyChanges { target: soundCard; opacity: 0.0 }
                        }
                    ]
                    transitions: [
                        Transition {
                            from: "closed"; to: "open"
                            SequentialAnimation {
                                PropertyAction { target: soundTrans; property: "y"; value: -20 }
                                PropertyAction { target: soundScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: soundScale; property: "yScale"; value: 0.75 }
                                PropertyAction { target: soundCard; property: "opacity"; value: 1.0 }
                                PauseAnimation { duration: 108 }
                                ParallelAnimation {
                                    NumberAnimation { target: soundTrans; property: "y"; to: 0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: soundScale; property: "xScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: soundScale; property: "yScale"; to: 1.0; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                }
                            }
                        },
                        Transition {
                            from: "open"; to: "closed"
                            SequentialAnimation {
                                ParallelAnimation {
                                    NumberAnimation { target: soundTrans; property: "y"; to: -20; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: soundScale; property: "xScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    NumberAnimation { target: soundScale; property: "yScale"; to: 0.75; duration: 540; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    SequentialAnimation {
                                        PauseAnimation { duration: 250 }
                                        NumberAnimation { target: soundCard; property: "opacity"; to: 0.0; duration: 290; easing.type: Easing.OutQuad }
                                    }
                                }
                                PropertyAction { target: soundTrans; property: "y"; value: -20 }
                                PropertyAction { target: soundScale; property: "xScale"; value: 0.75 }
                                PropertyAction { target: soundScale; property: "yScale"; value: 0.75 }
                            }
                        }
                    ]

                    MouseArea {
                    id: soundCardMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openSoundMenu()
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: 9
                    anchors.bottomMargin: 8
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 2

                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: root.isMuted ? "Sound (Muted)" : "Sound"
                            font.family: root.sfFont
                            font.pixelSize: 16
                            color: root.isMuted ? "#f43f5e" : "#ffffff"
                            renderType: Text.QtRendering
                            Layout.fillWidth: true
                        }

                        Text {
                            font.family: root.iconFont
                            font.pixelSize: 16
                            color: "#7dd3fc"
                            text: "󰅂"
                            renderType: Text.QtRendering
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        // Mute / Unmute icon button
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            font.family: root.iconFont
                            font.pixelSize: 22
                            color: root.isMuted ? "#f43f5e" : "#ffffff"
                            text: {
                                if (root.isMuted || root.volumeLevel <= 0.001) return "󰝟"
                                if (root.volumeLevel < 0.33) return "󰕿"
                                if (root.volumeLevel < 0.67) return "󰖀"
                                return "󰕾"
                            }
                            renderType: Text.QtRendering

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (root.sinkAudio) root.sinkAudio.muted = !root.sinkAudio.muted
                                }
                            }
                        }

                        // Slider Track + 11-Step Level Tick Markers
                        Item {
                            id: vSlider
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            implicitHeight: 28

                            Rectangle {
                                id: vTrack
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: 8
                                radius: 4
                                color: "#2effffff"
                                border.color: "#40ffffff"
                                border.width: 1

                                Rectangle {
                                    height: parent.height
                                    radius: parent.radius
                                    color: "#ffffff"
                                    width: vTrack.width * Math.min(1.0, root.volumeLevel)
                                }

                                Rectangle {
                                    id: vKnob
                                    width: 16
                                    height: 16
                                    radius: 8
                                    color: "#ffffff"
                                    border.color: root.isMuted ? "#94a3b8" : "#e2e8f0"
                                    border.width: 1.5
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: Math.max(0, Math.min(vTrack.width - 16, vTrack.width * Math.min(1.0, root.volumeLevel) - 8))

                                    opacity: vSliderMouse.containsMouse || vSliderMouse.pressed ? 1.0 : 0.0
                                    scale: vSliderMouse.containsMouse || vSliderMouse.pressed ? 1.0 : 0.5

                                    Behavior on opacity { NumberAnimation { duration: 150 } }
                                    Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }
                                }
                            }

                            // 11 Precision Level Indicator Ticks Under Slider (No min/max ticks)
                            Item {
                                id: vTickContainer
                                anchors.left: vTrack.left
                                anchors.right: vTrack.right
                                anchors.top: vTrack.bottom
                                anchors.topMargin: 2
                                height: 6

                                Repeater {
                                    model: 11
                                    Rectangle {
                                        property real progress: index / 10.0
                                        x: Math.round(progress * (vTickContainer.width - width))
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: index === 5 ? 2 : 1.5
                                        height: index === 5 ? 5 : 3
                                        radius: 1
                                        color: progress <= Math.min(1.0, root.volumeLevel) ? "#ffffff" : "#45ffffff"
                                        opacity: progress <= Math.min(1.0, root.volumeLevel) ? 0.95 : 0.4
                                        visible: index > 0 && index < 10
                                        Behavior on color { ColorAnimation { duration: 100 } }
                                    }
                                }
                            }

                            MouseArea {
                                id: vSliderMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                preventStealing: true
                                function updateVol(mouseX) {
                                    if (!root.sinkAudio) return
                                    const v = Math.max(0, Math.min(1.0, mouseX / vTrack.width))
                                    root.sinkAudio.volume = v
                                    if (root.sinkAudio.muted) root.sinkAudio.muted = false
                                }
                                onPressed: function(m) { updateVol(m.x) }
                                onPositionChanged: function(m) { if (pressed) updateVol(m.x) }
                                onWheel: function(w) {
                                    if (!root.sinkAudio) return
                                    const delta = w.angleDelta.y > 0 ? 0.05 : -0.05
                                    root.sinkAudio.volume = Math.max(0, Math.min(1.0, root.volumeLevel + delta))
                                }
                            }
                        }

                        // Output Sink Selector Badge (Right)
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 32
                            Layout.preferredHeight: 32
                            radius: 16
                            color: sinkMouse.containsMouse ? "#45ffffff" : "#20ffffff"
                            border.color: sinkMouse.containsMouse ? "#90ffffff" : "#40ffffff"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                font.family: root.iconFont
                                font.pixelSize: 18
                                color: "#ffffff"
                                text: root.getSinkIcon(root.sink)
                                renderType: Text.QtRendering
                            }

                            MouseArea {
                                id: sinkMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.openSoundMenu()
                            }
                        }
                    }
                }
            }
        }

        // ══════════════════════════════════════════════════════════════
        // VIEW 2: macOS STYLE WI-FI SUB-MENU (Full Backend + Password Modal)
        // ══════════════════════════════════════════════════════════════
        LiquidGlassCard {
            id: wifiMenuCard
            width: 376
            height: wifiCol.implicitHeight + 28
            cardRadius: dynamicRadius
            clip: true

            // Pop out and merge back into originating widget
            property real startTransX: -97
            property real startTransY: -135
            property real startScaleX: 0.484
            property real startScaleY: 0.206
            property real startRadius: 170

            property real contentScaleX: startScaleX
            property real contentScaleY: startScaleY
            property real contentTransX: startTransX
            property real contentTransY: startTransY
            property real dynamicRadius: startRadius
            property real contentOpacity: 0.0

            opacity: 0.0
            visible: opacity > 0.001

            Component.onCompleted: root.setupMenuOrigin(wifiMenuCard, wifiCard, -97, -135, 0.484, 0.206, 170)

            transform: [
                Scale {
                    origin.x: wifiMenuCard.width / 2
                    origin.y: wifiMenuCard.height / 2
                    xScale: wifiMenuCard.contentScaleX
                    yScale: wifiMenuCard.contentScaleY
                },
                Translate {
                    x: wifiMenuCard.contentTransX
                    y: wifiMenuCard.contentTransY
                }
            ]

            states: [
                State {
                    name: "open"
                    when: root.currentView === "wifi"
                    PropertyChanges {
                        target: wifiMenuCard
                        opacity: 1.0
                        contentScaleX: 1.0
                        contentScaleY: 1.0
                        contentTransX: 0
                        contentTransY: 0
                        dynamicRadius: 28
                        contentOpacity: 1.0
                    }
                },
                State {
                    name: "closed"
                    when: root.currentView !== "wifi"
                    PropertyChanges {
                        target: wifiMenuCard
                        opacity: 0.0
                        contentScaleX: wifiMenuCard.startScaleX
                        contentScaleY: wifiMenuCard.startScaleY
                        contentTransX: wifiMenuCard.startTransX
                        contentTransY: wifiMenuCard.startTransY
                        dynamicRadius: wifiMenuCard.startRadius
                        contentOpacity: 0.0
                    }
                }
            ]

            transitions: [
                Transition {
                    from: "closed"; to: "open"
                    ParallelAnimation {
                        NumberAnimation {
                            target: wifiMenuCard; property: "opacity"
                            duration: 110; easing.type: Easing.OutQuad
                        }
                        SequentialAnimation {
                            PauseAnimation { duration: 60 }
                            NumberAnimation {
                                target: wifiMenuCard; property: "contentOpacity"
                                duration: 240; easing.type: Easing.OutQuad
                            }
                        }
                        NumberAnimation {
                            target: wifiMenuCard
                            properties: "contentScaleX,contentScaleY,contentTransX,contentTransY,dynamicRadius"
                            duration: 540
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.springCurve
                        }
                    }
                },
                Transition {
                    from: "open"; to: "closed"
                    ParallelAnimation {
                        NumberAnimation {
                            target: wifiMenuCard; property: "contentOpacity"
                            to: 0.0
                            duration: 110; easing.type: Easing.OutQuad
                        }
                        SequentialAnimation {
                            PauseAnimation { duration: 320 }
                            NumberAnimation {
                                target: wifiMenuCard; property: "opacity"
                                to: 0.0
                                duration: 180; easing.type: Easing.OutQuad
                            }
                        }
                        NumberAnimation {
                            target: wifiMenuCard
                            properties: "contentScaleX,contentScaleY,contentTransX,contentTransY,dynamicRadius"
                            duration: 500
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.springCurve
                        }
                    }
                }
            ]

            ColumnLayout {
                id: wifiCol
                opacity: wifiMenuCard.contentOpacity
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                // Header: < Back | Wi-Fi | Wide macOS Toggle Switch
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Rectangle {
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        radius: 17
                        color: backWifiMouse.containsMouse ? "#30ffffff" : "transparent"

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: "#ffffff"
                            text: "󰁍"
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: backWifiMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.goBack()
                        }
                    }

                    Text {
                        text: "Wi-Fi"
                        font.family: root.sfFont
                        font.pixelSize: 20
                        color: "#ffffff"
                        renderType: Text.QtRendering
                    }

                    Item { Layout.fillWidth: true }

                    // Wide macOS Switch Pill [58px]
                    Rectangle {
                        Layout.preferredWidth: 58
                        Layout.preferredHeight: 28
                        radius: 14
                        color: root.wifiEnabled ? "#007aff" : "#45ffffff"

                        Behavior on color { ColorAnimation { duration: 160 } }

                        Rectangle {
                            width: 28
                            height: 22
                            radius: 11
                            color: "#ffffff"
                            anchors.verticalCenter: parent.verticalCenter
                            x: root.wifiEnabled ? 27 : 3

                            Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.25 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleWifi()
                        }
                    }
                }

                // Inline Wi-Fi Password Prompt Card
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: passCol.implicitHeight + 20
                    radius: 14
                    color: "#a00c1e30"
                    border.color: "#6060a5fa"
                    border.width: 1
                    visible: root.wifiPasswordPromptOpen

                    ColumnLayout {
                        id: passCol
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                font.family: root.iconFont
                                font.pixelSize: 18
                                color: "#60a5fa"
                                text: "󰌾"
                                renderType: Text.QtRendering
                            }

                            Text {
                                text: "Password for " + root.wifiSelectedSsid
                                font.family: root.sfFont
                                font.pixelSize: 15
                                color: "#ffffff"
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                renderType: Text.QtRendering
                            }
                        }

                        // Password text field with show/hide toggle
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 38
                            radius: 8
                            color: "#40ffffff"
                            border.color: passField.activeFocus ? "#007aff" : "#60ffffff"
                            border.width: 1

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 6

                                TextInput {
                                    id: passField
                                    Layout.fillWidth: true
                                    font.family: root.sfFont
                                    font.pixelSize: 15
                                    color: "#ffffff"
                                    echoMode: root.wifiShowPass ? TextInput.Normal : TextInput.Password
                                    text: root.wifiPasswordInput
                                    onTextChanged: root.wifiPasswordInput = text
                                    onAccepted: root.submitWifiPassword()
                                    renderType: Text.QtRendering
                                    clip: true

                                    Text {
                                        text: "Enter password..."
                                        font.family: root.sfFont
                                        font.pixelSize: 15
                                        color: "#94a3b8"
                                        visible: passField.text === "" && !passField.activeFocus
                                    }
                                }

                                Text {
                                    font.family: root.iconFont
                                    font.pixelSize: 17
                                    color: "#93c5fd"
                                    text: root.wifiShowPass ? "󰈈" : "󰈉"
                                    renderType: Text.QtRendering

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.wifiShowPass = !root.wifiShowPass
                                    }
                                }
                            }
                        }

                        // Status message
                        Text {
                            visible: root.wifiStatusMsg !== ""
                            text: root.wifiStatusMsg
                            font.family: root.sfFontMedium
                            font.pixelSize: 13
                            color: root.wifiStatusMsg.includes("failed") || root.wifiStatusMsg.includes("empty") ? "#f87171" : "#93c5fd"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            renderType: Text.QtRendering
                        }

                        // Connect & Cancel buttons
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 32
                                radius: 8
                                color: cancelMouse.containsMouse ? "#45ffffff" : "#25ffffff"

                                Text {
                                    anchors.centerIn: parent
                                    text: "Cancel"
                                    font.family: root.sfFontMedium
                                    font.pixelSize: 14
                                    color: "#ffffff"
                                    renderType: Text.QtRendering
                                }

                                MouseArea {
                                    id: cancelMouse
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.wifiPasswordPromptOpen = false
                                        root.wifiStatusMsg = ""
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 32
                                radius: 8
                                color: root.wifiConnecting ? "#40007aff" : "#007aff"

                                RowLayout {
                                    anchors.centerIn: parent
                                    spacing: 6

                                    MacSpinner {
                                        visible: root.wifiConnecting
                                        size: 16
                                        running: root.wifiConnecting
                                        spokeColor: "#ffffff"
                                    }

                                    Text {
                                        text: root.wifiConnecting ? "Connecting..." : "Connect"
                                        font.family: root.sfFont
                                        font.pixelSize: 14
                                        color: "#ffffff"
                                        renderType: Text.QtRendering
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.submitWifiPassword()
                                }
                            }
                        }
                    }
                }

                // Divider
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: "#20ffffff"
                }

                // Section Header Row: "Known Networks" + Reload Button (MacSpinner when scanning)
                RowLayout {
                    Layout.fillWidth: true

                    Text {
                        text: root.wifiEnabled ? (root.wifiConnected ? "Known Networks" : "Available Networks") : "Wi-Fi is Off"
                        font.family: root.sfFontSemibold
                        font.pixelSize: 15
                        color: "#93c5fd"
                        renderType: Text.QtRendering
                        Layout.fillWidth: true
                    }

                    MacSpinner {
                        visible: root.wifiScanning
                        size: 18
                        running: root.wifiScanning
                        spokeColor: "#60a5fa"
                    }

                    Rectangle {
                        visible: root.wifiEnabled && !root.wifiScanning
                        implicitWidth: 26
                        implicitHeight: 26
                        radius: 13
                        color: rescanMouse.containsMouse ? "#30ffffff" : "transparent"

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 16
                            color: "#93c5fd"
                            text: "󰑐"
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: rescanMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.scanWifi(true)
                        }
                    }
                }

                // Scanned Networks List
                Flickable {
                    Layout.fillWidth: true
                    implicitHeight: Math.min(270, netCol.implicitHeight)
                    contentHeight: netCol.implicitHeight
                    clip: true
                    visible: root.wifiEnabled

                    onContentYChanged: {
                        if (contentY < -20 && !dragging && !root.wifiScanning) {
                            root.scanWifi(true)
                        }
                    }

                    ColumnLayout {
                        id: netCol
                        width: parent.width
                        spacing: 4

                        Repeater {
                            model: root.wifiNetworks.slice(0, 8)

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 42
                                radius: 10
                                color: modelData.isActive ? "#25007aff" : (netMouse.containsMouse ? "#20ffffff" : "transparent")
                                border.color: modelData.isActive ? "#60007aff" : "transparent"
                                border.width: 1

                                Behavior on color { ColorAnimation { duration: 100 } }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 10

                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        Layout.preferredWidth: 28
                                        Layout.preferredHeight: 28
                                        radius: 14
                                        color: modelData.isActive ? "#007aff" : "#20ffffff"

                                        Text {
                                            anchors.centerIn: parent
                                            font.family: root.iconFont
                                            font.pixelSize: 16
                                            color: "#ffffff"
                                            text: modelData.signal > 75 ? "󰤨" : (modelData.signal > 45 ? "󰤥" : (modelData.signal > 20 ? "󰤢" : "󰤟"))
                                            renderType: Text.QtRendering
                                        }
                                    }

                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        Layout.fillWidth: true
                                        text: modelData.ssid
                                        font.family: root.sfFont
                                        font.pixelSize: 17
                                        color: "#ffffff"
                                        elide: Text.ElideRight
                                        renderType: Text.QtRendering
                                    }

                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        font.family: root.iconFont
                                        font.pixelSize: 15
                                        color: "#94a3b8"
                                        text: "󰌾"
                                        visible: modelData.isSecured && !modelData.isActive
                                        renderType: Text.QtRendering
                                    }
                                }

                                MouseArea {
                                    id: netMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (modelData.isActive) {
                                            root.disconnectWifi()
                                        } else {
                                            root.promptConnectWifi(modelData.ssid, modelData.isSecured)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Divider
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: "#20ffffff"
                }

                // Footer: Wi-Fi Settings...
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    radius: 8
                    color: setWifiMouse.containsMouse ? "#20ffffff" : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8

                        Text {
                            text: "Wi-Fi Settings..."
                            font.family: root.sfFontSemibold
                            font.pixelSize: 15
                            color: "#7dd3fc"
                            Layout.fillWidth: true
                            renderType: Text.QtRendering
                        }

                        Text {
                            font.family: root.iconFont
                            font.pixelSize: 16
                            color: "#7dd3fc"
                            text: "󰅂"
                            renderType: Text.QtRendering
                        }
                    }

                    MouseArea {
                        id: setWifiMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.close()
                            root.runShell("nm-connection-editor 2>/dev/null || systemsettings kcm_networkmanagement &")
                        }
                    }
                }
            }
        }

        // ══════════════════════════════════════════════════════════════
        // VIEW 3: macOS STYLE BLUETOOTH SUB-MENU (Device & Codec Backend)
        // ══════════════════════════════════════════════════════════════
        LiquidGlassCard {
            id: btMenuCard
            width: 376
            height: btCol.implicitHeight + 28
            cardRadius: dynamicRadius
            clip: true

            // Pop out and merge back into originating widget
            property real startTransX: 97
            property real startTransY: -140
            property real startScaleX: 0.484
            property real startScaleY: 0.200
            property real startRadius: 175

            property real contentScaleX: startScaleX
            property real contentScaleY: startScaleY
            property real contentTransX: startTransX
            property real contentTransY: startTransY
            property real dynamicRadius: startRadius
            property real contentOpacity: 0.0

            opacity: 0.0
            visible: opacity > 0.001

            Component.onCompleted: root.setupMenuOrigin(btMenuCard, btCard, 97, -140, 0.484, 0.200, 175)

            transform: [
                Scale {
                    origin.x: btMenuCard.width / 2
                    origin.y: btMenuCard.height / 2
                    xScale: btMenuCard.contentScaleX
                    yScale: btMenuCard.contentScaleY
                },
                Translate {
                    x: btMenuCard.contentTransX
                    y: btMenuCard.contentTransY
                }
            ]

            states: [
                State {
                    name: "open"
                    when: root.currentView === "bluetooth"
                    PropertyChanges {
                        target: btMenuCard
                        opacity: 1.0
                        contentScaleX: 1.0
                        contentScaleY: 1.0
                        contentTransX: 0
                        contentTransY: 0
                        dynamicRadius: 28
                        contentOpacity: 1.0
                    }
                },
                State {
                    name: "closed"
                    when: root.currentView !== "bluetooth"
                    PropertyChanges {
                        target: btMenuCard
                        opacity: 0.0
                        contentScaleX: btMenuCard.startScaleX
                        contentScaleY: btMenuCard.startScaleY
                        contentTransX: btMenuCard.startTransX
                        contentTransY: btMenuCard.startTransY
                        dynamicRadius: btMenuCard.startRadius
                        contentOpacity: 0.0
                    }
                }
            ]

            transitions: [
                Transition {
                    from: "closed"; to: "open"
                    ParallelAnimation {
                        NumberAnimation {
                            target: btMenuCard; property: "opacity"
                            duration: 110; easing.type: Easing.OutQuad
                        }
                        SequentialAnimation {
                            PauseAnimation { duration: 60 }
                            NumberAnimation {
                                target: btMenuCard; property: "contentOpacity"
                                duration: 240; easing.type: Easing.OutQuad
                            }
                        }
                        NumberAnimation {
                            target: btMenuCard
                            properties: "contentScaleX,contentScaleY,contentTransX,contentTransY,dynamicRadius"
                            duration: 540
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.springCurve
                        }
                    }
                },
                Transition {
                    from: "open"; to: "closed"
                    ParallelAnimation {
                        NumberAnimation {
                            target: btMenuCard; property: "contentOpacity"
                            to: 0.0
                            duration: 110; easing.type: Easing.OutQuad
                        }
                        SequentialAnimation {
                            PauseAnimation { duration: 320 }
                            NumberAnimation {
                                target: btMenuCard; property: "opacity"
                                to: 0.0
                                duration: 180; easing.type: Easing.OutQuad
                            }
                        }
                        NumberAnimation {
                            target: btMenuCard
                            properties: "contentScaleX,contentScaleY,contentTransX,contentTransY,dynamicRadius"
                            duration: 500
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.springCurve
                        }
                    }
                }
            ]

            ColumnLayout {
                id: btCol
                opacity: btMenuCard.contentOpacity
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                // Header: < Back | Bluetooth | Wide macOS Toggle Switch
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Rectangle {
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        radius: 17
                        color: backBtMouse.containsMouse ? "#30ffffff" : "transparent"

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: "#ffffff"
                            text: "󰁍"
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: backBtMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.goBack()
                        }
                    }

                    Text {
                        text: "Bluetooth"
                        font.family: root.sfFont
                        font.pixelSize: 20
                        color: "#ffffff"
                        renderType: Text.QtRendering
                        Layout.fillWidth: true
                    }

                    // Wide macOS Toggle Switch
                    Rectangle {
                        implicitWidth: 58
                        implicitHeight: 28
                        radius: 14
                        color: root.btPowered ? "#007aff" : "#3a3a3c"

                        Behavior on color { ColorAnimation { duration: 180 } }

                        Rectangle {
                            width: 28
                            height: 22
                            radius: 11
                            color: "#ffffff"
                            anchors.verticalCenter: parent.verticalCenter
                            x: root.btPowered ? 27 : 3

                            Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleBluetooth()
                        }
                    }
                }

                // Hairline Separator
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: "#20ffffff"
                }

                // Audio Codec Selection Bar (When bluetooth audio card is active)
                Rectangle {
                    visible: root.btPowered && root.btCardName !== "" && root.btAudioProfiles.length > 0
                    Layout.fillWidth: true
                    implicitHeight: codecCol.implicitHeight + 16
                    radius: 12
                    color: "#900c1e30"
                    border.color: "#3060a5fa"
                    border.width: 1

                    ColumnLayout {
                        id: codecCol
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                font.family: root.iconFont
                                font.pixelSize: 15
                                color: "#60a5fa"
                                text: "󰓃"
                                renderType: Text.QtRendering
                            }

                            Text {
                                text: "Audio Codec / Profile"
                                font.family: root.sfFontSemibold
                                font.pixelSize: 13
                                color: "#93c5fd"
                                Layout.fillWidth: true
                                renderType: Text.QtRendering
                            }
                        }

                        // Profile Selection Flow / Pills
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6

                            Repeater {
                                model: root.btAudioProfiles

                                Rectangle {
                                    implicitWidth: profText.implicitWidth + 18
                                    implicitHeight: 26
                                    radius: 7
                                    property bool isCurrent: root.btActiveProfile === modelData.id
                                    color: isCurrent ? "#007aff" : (cMouse.containsMouse ? "#30ffffff" : "#18ffffff")
                                    border.color: isCurrent ? "#8060a5fa" : "transparent"
                                    border.width: 1

                                    Behavior on color { ColorAnimation { duration: 120 } }

                                    Text {
                                        id: profText
                                        anchors.centerIn: parent
                                        text: modelData.name
                                        font.family: root.sfFontMedium
                                        font.pixelSize: 12
                                        color: isCurrent ? "#ffffff" : "#e2e8f0"
                                        renderType: Text.QtRendering
                                    }

                                    MouseArea {
                                        id: cMouse
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setBtProfile(modelData.id)
                                    }
                                }
                            }
                        }
                    }
                }

                // Section Header: "Devices" + in-place radial spinner while scanning
                RowLayout {
                    Layout.fillWidth: true

                    Text {
                        text: root.btPowered ? "Devices" : "Bluetooth is Off"
                        font.family: root.sfFontMedium
                        font.pixelSize: 15
                        color: "#93c5fd"
                        renderType: Text.QtRendering
                        Layout.fillWidth: true
                    }

                    MacSpinner {
                        size: 18
                        running: root.btScanning || root.btDiscovering
                        visible: root.btScanning || root.btDiscovering
                        spokeColor: "#60a5fa"
                    }

                    Rectangle {
                        visible: root.btPowered && !root.btScanning && !root.btDiscovering
                        implicitWidth: 26
                        implicitHeight: 26
                        radius: 13
                        color: btReloadMouse.containsMouse ? "#30ffffff" : "transparent"

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 16
                            color: "#93c5fd"
                            text: "󰑐"
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: btReloadMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.scanBluetooth()
                            }
                        }
                    }
                }

                // Devices List with Full Actions (Connect / Disconnect / Forget)
                Flickable {
                    Layout.fillWidth: true
                    implicitHeight: Math.min(270, devCol.implicitHeight)
                    contentHeight: devCol.implicitHeight
                    clip: true
                    visible: root.btPowered

                    onContentYChanged: {
                        if (contentY < -20 && !dragging && !root.btScanning) {
                            root.scanBluetooth()
                        }
                    }

                    ColumnLayout {
                        id: devCol
                        width: parent.width
                        spacing: 4

                        Repeater {
                            model: root.btDevices

                            Rectangle {
                                id: devCard
                                Layout.fillWidth: true
                                implicitHeight: 46
                                radius: 10
                                property bool isHovered: devMouse.containsMouse || (forgetMouse.containsMouse && (modelData.isPaired || modelData.isConnected))
                                color: modelData.isConnected ? "#25007aff" : (devCard.isHovered ? "#20ffffff" : "transparent")
                                border.color: modelData.isConnected ? "#60007aff" : "transparent"
                                border.width: 1

                                Behavior on color { ColorAnimation { duration: 100 } }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 10

                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        Layout.preferredWidth: 28
                                        Layout.preferredHeight: 28
                                        radius: 14
                                        color: modelData.isConnected ? "#007aff" : (modelData.state === "pairing" || modelData.state === "connecting" ? "#35007aff" : "#20ffffff")

                                        Behavior on color { ColorAnimation { duration: 150 } }

                                        Text {
                                            anchors.centerIn: parent
                                            font.family: root.iconFont
                                            font.pixelSize: 16
                                            color: "#ffffff"
                                            text: {
                                                if (modelData.iconType === "headphones") return "󰋋"
                                                if (modelData.iconType === "mouse") return "󰍽"
                                                if (modelData.iconType === "keyboard") return "󰌌"
                                                if (modelData.iconType === "phone") return "󰄜"
                                                if (modelData.iconType === "watch") return "󰃭"
                                                return "󰂯"
                                            }
                                            renderType: Text.QtRendering
                                        }
                                    }

                                    // Left-Aligned Text Column
                                    ColumnLayout {
                                        Layout.alignment: Qt.AlignVCenter
                                        Layout.fillWidth: true
                                        spacing: 1

                                        Text {
                                            Layout.fillWidth: true
                                            horizontalAlignment: Text.AlignLeft
                                            text: modelData.name
                                            font.family: root.sfFont
                                            font.pixelSize: 15
                                            color: "#ffffff"
                                            elide: Text.ElideRight
                                            renderType: Text.QtRendering
                                        }

                                        RowLayout {
                                            spacing: 6
                                            Text {
                                                text: {
                                                    if (modelData.state === "connecting") return "Connecting..."
                                                    if (modelData.state === "pairing") return "Pairing..."
                                                    if (modelData.state === "disconnecting") return "Disconnecting..."
                                                    if (modelData.isConnected) return "Connected"
                                                    if (modelData.isPaired) return "Paired"
                                                    return "Available"
                                                }
                                                font.family: root.sfFont
                                                font.pixelSize: 12
                                                color: {
                                                    if (modelData.state === "pairing") return "#fbbf24"
                                                    if (modelData.state === "connecting" || modelData.isConnected) return "#93c5fd"
                                                    if (modelData.isPaired) return "#94a3b8"
                                                    return "#64748b"
                                                }
                                                renderType: Text.QtRendering
                                            }

                                            Text {
                                                visible: modelData.battery !== ""
                                                text: "• " + modelData.battery + "%"
                                                font.family: root.sfFont
                                                font.pixelSize: 12
                                                color: "#4ade80"
                                                renderType: Text.QtRendering
                                            }
                                        }
                                    }

                                    // Transient Spinner when connecting/pairing
                                    MacSpinner {
                                        Layout.alignment: Qt.AlignVCenter
                                        size: 14
                                        running: modelData.state === "connecting" || modelData.state === "pairing" || modelData.state === "disconnecting"
                                        visible: running
                                        spokeColor: "#60a5fa"
                                    }

                                    // Forget / Remove Action Button on Hover
                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: modelData.isPaired || modelData.isConnected
                                        opacity: devCard.isHovered ? 1.0 : 0.0
                                        implicitWidth: 24
                                        implicitHeight: 24
                                        radius: 12
                                        color: forgetMouse.containsMouse ? "#40ef4444" : "#18ffffff"

                                        Behavior on opacity { NumberAnimation { duration: 120 } }
                                        Behavior on color { ColorAnimation { duration: 100 } }

                                        Text {
                                            anchors.centerIn: parent
                                            font.family: root.iconFont
                                            font.pixelSize: 12
                                            color: forgetMouse.containsMouse ? "#f87171" : "#94a3b8"
                                            text: "󰆴"
                                            renderType: Text.QtRendering
                                        }

                                        MouseArea {
                                            id: forgetMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.removeBluetooth(modelData.mac)
                                            }
                                        }
                                    }
                                }

                                MouseArea {
                                    id: devMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    z: -1
                                    onClicked: {
                                        if (modelData.isConnected) {
                                            root.disconnectBluetooth(modelData.mac)
                                        } else if (modelData.isPaired) {
                                            root.connectBluetooth(modelData.mac)
                                        } else {
                                            root.pairBluetooth(modelData.mac)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Divider
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: "#20ffffff"
                }

                // Footer: Bluetooth Settings...
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    radius: 8
                    color: setBtMouse.containsMouse ? "#20ffffff" : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8

                        Text {
                            text: "Bluetooth Settings..."
                            font.family: root.sfFontSemibold
                            font.pixelSize: 15
                            color: "#7dd3fc"
                            Layout.fillWidth: true
                            renderType: Text.QtRendering
                        }

                        Text {
                            font.family: root.iconFont
                            font.pixelSize: 16
                            color: "#7dd3fc"
                            text: "󰅂"
                            renderType: Text.QtRendering
                        }
                    }

                    MouseArea {
                        id: setBtMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.close()
                            root.runShell("blueman-manager 2>/dev/null || systemsettings kcm_bluetooth &")
                        }
                    }
                }
            }
        }

        // ══════════════════════════════════════════════════════════════
        // VIEW 4: macOS SOUND & OUTPUT SUB-MENU (Same As Media Island)
        // ══════════════════════════════════════════════════════════════
        LiquidGlassCard {
            id: soundMenuCard
            width: 376
            height: soundCol.implicitHeight + 28
            cardRadius: dynamicRadius
            clip: true

            // Pop out and merge back into originating widget
            property real startTransX: 0
            property real startTransY: 155
            property real startScaleX: 1.0
            property real startScaleY: 0.224
            property real startRadius: 107

            property real contentScaleX: startScaleX
            property real contentScaleY: startScaleY
            property real contentTransX: startTransX
            property real contentTransY: startTransY
            property real dynamicRadius: startRadius
            property real contentOpacity: 0.0

            opacity: 0.0
            visible: opacity > 0.001

            Component.onCompleted: root.setupMenuOrigin(soundMenuCard, soundCard, 0, 155, 1.0, 0.224, 107)

            transform: [
                Scale {
                    origin.x: soundMenuCard.width / 2
                    origin.y: soundMenuCard.height / 2
                    xScale: soundMenuCard.contentScaleX
                    yScale: soundMenuCard.contentScaleY
                },
                Translate {
                    x: soundMenuCard.contentTransX
                    y: soundMenuCard.contentTransY
                }
            ]

            states: [
                State {
                    name: "open"
                    when: root.currentView === "sound"
                    PropertyChanges {
                        target: soundMenuCard
                        opacity: 1.0
                        contentScaleX: 1.0
                        contentScaleY: 1.0
                        contentTransX: 0
                        contentTransY: 0
                        dynamicRadius: 28
                        contentOpacity: 1.0
                    }
                },
                State {
                    name: "closed"
                    when: root.currentView !== "sound"
                    PropertyChanges {
                        target: soundMenuCard
                        opacity: 0.0
                        contentScaleX: soundMenuCard.startScaleX
                        contentScaleY: soundMenuCard.startScaleY
                        contentTransX: soundMenuCard.startTransX
                        contentTransY: soundMenuCard.startTransY
                        dynamicRadius: soundMenuCard.startRadius
                        contentOpacity: 0.0
                    }
                }
            ]

            transitions: [
                Transition {
                    from: "closed"; to: "open"
                    ParallelAnimation {
                        NumberAnimation {
                            target: soundMenuCard; property: "opacity"
                            duration: 110; easing.type: Easing.OutQuad
                        }
                        SequentialAnimation {
                            PauseAnimation { duration: 60 }
                            NumberAnimation {
                                target: soundMenuCard; property: "contentOpacity"
                                duration: 240; easing.type: Easing.OutQuad
                            }
                        }
                        NumberAnimation {
                            target: soundMenuCard
                            properties: "contentScaleX,contentScaleY,contentTransX,contentTransY,dynamicRadius"
                            duration: 540
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.springCurve
                        }
                    }
                },
                Transition {
                    from: "open"; to: "closed"
                    ParallelAnimation {
                        NumberAnimation {
                            target: soundMenuCard; property: "contentOpacity"
                            to: 0.0
                            duration: 110; easing.type: Easing.OutQuad
                        }
                        SequentialAnimation {
                            PauseAnimation { duration: 320 }
                            NumberAnimation {
                                target: soundMenuCard; property: "opacity"
                                to: 0.0
                                duration: 180; easing.type: Easing.OutQuad
                            }
                        }
                        NumberAnimation {
                            target: soundMenuCard
                            properties: "contentScaleX,contentScaleY,contentTransX,contentTransY,dynamicRadius"
                            duration: 500
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.springCurve
                        }
                    }
                }
            ]

            ColumnLayout {
                id: soundCol
                opacity: soundMenuCard.contentOpacity
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                // Header: < Back | SOUND AND OUTPUT | % readout
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        implicitWidth: 34
                        implicitHeight: 34
                        radius: 17
                        color: backSoundMouse.containsMouse ? "#33ffffff" : "#1affffff"

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: "#ffffff"
                            text: "󰁍"
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: backSoundMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.goBack()
                        }
                    }

                    Text {
                        text: "SOUND AND OUTPUT"
                        font.family: root.sfFont
                        font.pixelSize: 15
                        font.bold: true
                        color: "#ffffff"
                        renderType: Text.QtRendering
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 14
                        font.bold: true
                        color: root.isMuted ? "#f38ba8" : "#93c5fd"
                        renderType: Text.QtRendering
                        text: root.isMuted ? "MUTED" : Math.round(root.volumeLevel * 100) + "%"
                    }
                }

                // Small gap below header
                Item { Layout.preferredHeight: 6 }

                // Master Volume Slider Track
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        implicitWidth: 34
                        implicitHeight: 34
                        radius: 17
                        color: subMuteMouse.containsMouse ? "#33ffffff" : "#1affffff"

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 23
                            color: root.isMuted ? "#f38ba8" : "#ffffff"
                            text: {
                                if (root.isMuted || root.volumeLevel <= 0.001) return "󰝟"
                                if (root.volumeLevel < 0.33) return "󰕿"
                                if (root.volumeLevel < 0.67) return "󰖀"
                                return "󰕾"
                            }
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: subMuteMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.sinkAudio) root.sinkAudio.muted = !root.sinkAudio.muted
                            }
                            onWheel: function(wheel) {
                                const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                                subVolSliderMouse.adjustVol(delta)
                            }
                        }
                    }

                    // Slider Bar with drag handle
                    Item {
                        id: subVolSliderItem
                        Layout.fillWidth: true
                        implicitHeight: 32

                        property bool sliderPressed: subVolSliderMouse.pressed
                        property real fillFraction: Math.max(0, Math.min(1.0, root.volumeLevel))

                        // Track background
                        Rectangle {
                            id: subMenuVolTrack
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 8
                            radius: 4
                            color: "#33ffffff"

                            // Fill
                            Rectangle {
                                id: subMenuVolFill
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: parent.width * subVolSliderItem.fillFraction
                                radius: 4
                                color: root.isMuted ? "#f38ba8" : "#93c5fd"
                            }

                            // Handle Knob
                            Rectangle {
                                id: subVolHandle
                                width: 16; height: 16
                                radius: 8
                                color: "#ffffff"
                                anchors.verticalCenter: parent.verticalCenter
                                x: Math.max(0, Math.min(parent.width - width, parent.width * subVolSliderItem.fillFraction - width / 2))
                                scale: subVolSliderItem.sliderPressed ? 1.25 : 1.0
                                Behavior on scale { NumberAnimation { duration: 120 } }
                            }
                        }

                        MouseArea {
                            id: subVolSliderMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            preventStealing: true

                            function adjustVol(delta) {
                                if (!root.sinkAudio) return
                                const current = root.sinkAudio.volume
                                const target = Math.max(0, Math.min(1.0, current + delta))
                                root.sinkAudio.volume = target
                                if (root.sinkAudio.muted) root.sinkAudio.muted = false
                            }

                            function updateVol(mx) {
                                if (!root.sinkAudio) return
                                const frac = Math.max(0, Math.min(1.0, mx / width))
                                root.sinkAudio.volume = frac
                                if (root.sinkAudio.muted) root.sinkAudio.muted = false
                            }

                            onPressed: function(mouse) { updateVol(mouse.x) }
                            onPositionChanged: function(mouse) { if (pressed) updateVol(mouse.x) }
                            onWheel: function(wheel) {
                                const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                                adjustVol(delta)
                            }
                        }
                    }
                }

                // Small gap below slider
                Item { Layout.preferredHeight: 6 }

                // Output Sinks List (15px SF Pro Rounded text & 30px icons matching MediaMenu)
                Item {
                    Layout.fillWidth: true
                    implicitHeight: Math.min(220, sinkCol.implicitHeight)
                    clip: true

                    Flickable {
                        anchors.fill: parent
                        contentHeight: sinkCol.implicitHeight
                        clip: true

                        ColumnLayout {
                            id: sinkCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            spacing: 5

                            Repeater {
                                model: root.getAudioOutputSinks()

                                delegate: Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 42
                                    radius: 10

                                    property bool isDefault: {
                                        const def = Pipewire.defaultAudioSink
                                        return def !== null && def !== undefined && def.id === modelData.id
                                    }

                                    color: isDefault ? "#33007aff" : (sinkMouse.containsMouse ? "#20ffffff" : "#10ffffff")
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    border.color: isDefault ? "#8060a5fa" : "transparent"
                                    border.width: 1
                                    clip: true

                                    scale: sinkMouse.pressed ? 0.96 : 1.0
                                    Behavior on scale {
                                        NumberAnimation { duration: sinkMouse.pressed ? 80 : 200; easing.type: sinkMouse.pressed ? Easing.InCubic : Easing.OutBack; easing.overshoot: 1.2 }
                                    }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 10
                                        spacing: 10

                                        // Device Icon badge (30x30)
                                        Rectangle {
                                            Layout.preferredWidth: 30
                                            Layout.preferredHeight: 30
                                            radius: 15
                                            color: isDefault ? "#007aff" : "#20ffffff"

                                            Text {
                                                anchors.centerIn: parent
                                                font.family: root.iconFont
                                                font.pixelSize: 17
                                                color: "#ffffff"
                                                renderType: Text.QtRendering
                                                text: root.getSinkIcon(modelData)
                                            }
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            font.family: root.sfFont
                                            font.pixelSize: 15
                                            color: "#ffffff"
                                            renderType: Text.QtRendering
                                            text: modelData.description || modelData.nickname || modelData.name || "Unknown Device"
                                            elide: Text.ElideRight
                                        }
                                    }

                                    MouseArea {
                                        id: sinkMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData) {
                                                Pipewire.preferredDefaultAudioSink = modelData
                                                root.runShell("wpctl set-default " + modelData.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ══════════════════════════════════════════════════════════════
        // VIEW 5: macOS STYLE SCREEN TIME SUB-MENU (App Breakdown)
        // ══════════════════════════════════════════════════════════════
        LiquidGlassCard {
            id: screenTimeMenuCard
            width: 356
            height: screenTimeCol.implicitHeight + 28
            cardRadius: dynamicRadius
            clip: true

            // Dynamic Island-style entrance/exit centered in panel
            x: (parent.width - width) / 2

            // Pop out and merge back into originating widget
            property real startTransX: 97
            property real startTransY: -73
            property real startScaleX: 0.511
            property real startScaleY: 0.184
            property real startRadius: 190

            property real contentScaleX: startScaleX
            property real contentScaleY: startScaleY
            property real contentTransX: startTransX
            property real contentTransY: startTransY
            property real dynamicRadius: startRadius
            property real contentOpacity: 0.0

            opacity: 0.0
            visible: opacity > 0.001

            Component.onCompleted: root.setupMenuOrigin(screenTimeMenuCard, stCard, 97, -73, 0.511, 0.184, 190)

            transform: [
                Scale {
                    origin.x: screenTimeMenuCard.width / 2
                    origin.y: screenTimeMenuCard.height / 2
                    xScale: screenTimeMenuCard.contentScaleX
                    yScale: screenTimeMenuCard.contentScaleY
                },
                Translate {
                    x: screenTimeMenuCard.contentTransX
                    y: screenTimeMenuCard.contentTransY
                }
            ]

            states: [
                State {
                    name: "open"
                    when: root.currentView === "screentime"
                    PropertyChanges {
                        target: screenTimeMenuCard
                        opacity: 1.0
                        contentScaleX: 1.0
                        contentScaleY: 1.0
                        contentTransX: 0
                        contentTransY: 0
                        dynamicRadius: 28
                        contentOpacity: 1.0
                    }
                },
                State {
                    name: "closed"
                    when: root.currentView !== "screentime"
                    PropertyChanges {
                        target: screenTimeMenuCard
                        opacity: 0.0
                        contentScaleX: screenTimeMenuCard.startScaleX
                        contentScaleY: screenTimeMenuCard.startScaleY
                        contentTransX: screenTimeMenuCard.startTransX
                        contentTransY: screenTimeMenuCard.startTransY
                        dynamicRadius: screenTimeMenuCard.startRadius
                        contentOpacity: 0.0
                    }
                }
            ]

            transitions: [
                Transition {
                    from: "closed"; to: "open"
                    ParallelAnimation {
                        NumberAnimation {
                            target: screenTimeMenuCard; property: "opacity"
                            duration: 110; easing.type: Easing.OutQuad
                        }
                        SequentialAnimation {
                            PauseAnimation { duration: 60 }
                            NumberAnimation {
                                target: screenTimeMenuCard; property: "contentOpacity"
                                duration: 240; easing.type: Easing.OutQuad
                            }
                        }
                        NumberAnimation {
                            target: screenTimeMenuCard
                            properties: "contentScaleX,contentScaleY,contentTransX,contentTransY,dynamicRadius"
                            duration: 540
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.springCurve
                        }
                    }
                },
                Transition {
                    from: "open"; to: "closed"
                    ParallelAnimation {
                        NumberAnimation {
                            target: screenTimeMenuCard; property: "contentOpacity"
                            to: 0.0
                            duration: 110; easing.type: Easing.OutQuad
                        }
                        SequentialAnimation {
                            PauseAnimation { duration: 320 }
                            NumberAnimation {
                                target: screenTimeMenuCard; property: "opacity"
                                to: 0.0
                                duration: 180; easing.type: Easing.OutQuad
                            }
                        }
                        NumberAnimation {
                            target: screenTimeMenuCard
                            properties: "contentScaleX,contentScaleY,contentTransX,contentTransY,dynamicRadius"
                            duration: 500
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.springCurve
                        }
                    }
                }
            ]

            ColumnLayout {
                id: screenTimeCol
                opacity: screenTimeMenuCard.contentOpacity
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                // Header: < Back | Screen Time
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Rectangle {
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        radius: 17
                        color: backStMouse.containsMouse ? "#30ffffff" : "transparent"

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: "#ffffff"
                            text: "󰁍"
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: backStMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.goBack()
                        }
                    }

                    Text {
                        text: "Screen Time"
                        font.family: root.sfFont
                        font.pixelSize: 20
                        color: "#ffffff"
                        renderType: Text.QtRendering
                    }

                    Item { Layout.fillWidth: true }
                }

                // Hero Screen Time Display (Big prominent duration)
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    spacing: 1

                    Text {
                        text: root.screenTimeTotalFormatted
                        font.family: root.sfFontBold
                        font.pixelSize: 32
                        color: "#ffffff"
                        renderType: Text.QtRendering
                    }

                    Text {
                        text: "Total active screen time today"
                        font.family: root.sfFont
                        font.pixelSize: 13
                        color: "#94a3b8"
                        renderType: Text.QtRendering
                    }
                }

                // Hero Multi-Colored Segmented Capsule Bar (100% Curvy Ends via Canvas Clipping)
                Canvas {
                    id: heroBarCanvas
                    Layout.fillWidth: true
                    Layout.preferredHeight: 14
                    renderTarget: Canvas.Image

                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        const r = height / 2

                        // Capsule clipping path
                        ctx.save()
                        ctx.beginPath()
                        ctx.moveTo(r, 0)
                        ctx.lineTo(width - r, 0)
                        ctx.arc(width - r, r, r, -Math.PI / 2, Math.PI / 2, false)
                        ctx.lineTo(r, height)
                        ctx.arc(r, r, r, Math.PI / 2, -Math.PI / 2, false)
                        ctx.closePath()
                        ctx.clip()

                        // Background track
                        ctx.fillStyle = "#25ffffff"
                        ctx.fillRect(0, 0, width, height)

                        // Draw Colored App Segments
                        let curX = 0
                        if (root.screenTimeApps && root.screenTimeApps.length > 0 && root.screenTimeTotalSec > 0) {
                            for (let i = 0; i < root.screenTimeApps.length; i++) {
                                const app = root.screenTimeApps[i]
                                const w = Math.max(2, (app.seconds / root.screenTimeTotalSec) * width)
                                ctx.fillStyle = app.color || "#3b82f6"
                                ctx.fillRect(curX, 0, w, height)
                                curX += w
                            }
                        } else {
                            ctx.fillStyle = "#475569"
                            ctx.fillRect(0, 0, width, height)
                        }
                        ctx.restore()

                        // Border
                        ctx.beginPath()
                        ctx.moveTo(r, 0.5)
                        ctx.lineTo(width - r, 0.5)
                        ctx.arc(width - r, r, r - 0.5, -Math.PI / 2, Math.PI / 2, false)
                        ctx.lineTo(r, height - 0.5)
                        ctx.arc(r, r, r - 0.5, Math.PI / 2, -Math.PI / 2, false)
                        ctx.closePath()
                        ctx.strokeStyle = "#35ffffff"
                        ctx.lineWidth = 1
                        ctx.stroke()
                    }

                    Connections {
                        target: root
                        function onScreenTimeAppsChanged() { heroBarCanvas.requestPaint() }
                        function onScreenTimeTotalSecChanged() { heroBarCanvas.requestPaint() }
                    }
                }

                // Section Label
                Text {
                    text: "Most Used Apps"
                    font.family: root.sfFont
                    font.pixelSize: 13
                    color: "#94a3b8"
                    renderType: Text.QtRendering
                    Layout.topMargin: 4
                }

                // App List (Sorted by highest active time first)
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Repeater {
                        model: root.screenTimeApps

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 52
                            radius: 14
                            color: appRowMouse.containsMouse ? "#28ffffff" : "#14ffffff"
                            border.color: appRowMouse.containsMouse ? "#50ffffff" : "#20ffffff"
                            border.width: 1

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 12

                                // App Icon or Initial Letter Badge
                                Rectangle {
                                    Layout.preferredWidth: 32
                                    Layout.preferredHeight: 32
                                    radius: 8
                                    color: modelData.color || "#3b82f6"

                                    Image {
                                        id: appIconImg
                                        anchors.centerIn: parent
                                        width: 22
                                        height: 22
                                        source: root.formatAppIcon(modelData.icon || modelData.id)
                                        fillMode: Image.PreserveAspectFit
                                        smooth: true
                                        mipmap: true
                                        visible: status === Image.Ready
                                    }

                                    // Fallback letter if icon not found
                                    Text {
                                        anchors.centerIn: parent
                                        text: (modelData.name || "A").charAt(0).toUpperCase()
                                        font.family: root.sfFontBold
                                        font.pixelSize: 16
                                        color: "#ffffff"
                                        renderType: Text.QtRendering
                                        visible: !appIconImg.visible
                                    }
                                }

                                // App Name & Percentage
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1

                                    Text {
                                        text: modelData.name || modelData.id
                                        font.family: root.sfFont
                                        font.pixelSize: 15
                                        color: "#ffffff"
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                        renderType: Text.QtRendering
                                    }

                                    Text {
                                        text: (modelData.percent || 0) + "% of screen time"
                                        font.family: root.sfFont
                                        font.pixelSize: 12
                                        color: "#94a3b8"
                                        Layout.fillWidth: true
                                        renderType: Text.QtRendering
                                    }
                                }

                                // Active Time Spent (Pinned to extreme right)
                                Text {
                                    text: modelData.formatted || "0m"
                                    font.family: root.sfFontSemibold
                                    font.pixelSize: 14
                                    color: "#e2e8f0"
                                    horizontalAlignment: Text.AlignRight
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    renderType: Text.QtRendering
                                }
                            }

                            MouseArea {
                                id: appRowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                            }
                        }
                    }

                    // Empty state if no apps
                    Item {
                        visible: root.screenTimeApps.length === 0
                        Layout.fillWidth: true
                        Layout.preferredHeight: 60

                        Text {
                            anchors.centerIn: parent
                            text: "No active screen time recorded yet today."
                            font.family: root.sfFont
                            font.pixelSize: 13
                            color: "#94a3b8"
                        }
                    }
                }
            }
        }
    }
}
