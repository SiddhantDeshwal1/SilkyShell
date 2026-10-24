pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // ── Active State ──────────────────────────────────────────────────
    // activeView: "none" | "call" | "talking" | "notification" | "timer" | "alarm" | "missed_call" | "device_status"
    property string activeView: "none"
    property bool expanded: false
    property bool isManualMenu: false
    property bool wasTalkingBeforeNotif: false

    // ── Focus Mode (DND) Integration ──────────────────────────────────
    property bool focusMode: false

    // ── Phone & Ambient State ─────────────────────────────────────────
    property string phoneName: "Galaxy A35 5G"
    property int phoneBattery: 61
    property bool phoneCharging: false
    property int notificationsCount: 17
    property int missedCallsCount: 0
    property string lastMissedCaller: ""

    // ── Call State ────────────────────────────────────────────────────
    property string callerName: "Saurabh"
    property string callerNumber: ""
    property int callDuration: 0           // Live duration in seconds
    property bool callTimerRunning: false

    // ── Notification State ────────────────────────────────────────────
    property string notifId: ""
    property string notifApp: ""
    property string notifTitle: ""
    property string notifBody: ""
    property string notifIcon: ""

    // ── Timer & Alarm State ───────────────────────────────────────────
    property int timerSeconds: 154
    property string timerTitle: "Timer"
    property bool timerCountdownActive: false
    property string alarmTitle: "Alarm"

    // ── Layout Coordination (Bar Pill Coordinates) ───────────────────
    property real barPillX: 980
    property real barPillWidth: 140
    property real pillCenterX: barPillX + (barPillWidth / 2)

    // Helper: format seconds to "m:ss" (exact formatClock from React code)
    function formatClock(totalSeconds) {
        const m = Math.floor(totalSeconds / 60)
        const s = totalSeconds % 60
        return m + ":" + (s < 10 ? "0" : "") + s
    }

    // Live talk timer ticker
    property var _talkTimer: Timer {
        interval: 1000
        repeat: true
        running: root.callTimerRunning
        onTriggered: {
            root.callDuration += 1
        }
    }

    // Countdown timer for mobile timer
    property var _countdownTimer: Timer {
        interval: 1000
        repeat: true
        running: root.timerCountdownActive && root.activeView === "timer" && root.timerSeconds > 0
        onTriggered: {
            if (root.timerSeconds > 0) {
                root.timerSeconds -= 1
            } else {
                root.timerCountdownActive = false
            }
        }
    }

    // Auto-dismiss timer for popup notifications
    property var _autoDismissTimer: Timer {
        interval: 6500
        repeat: false
        running: false
        onTriggered: {
            if (root.activeView === "notification") {
                root.dismissNotification()
            }
        }
    }

    // ── Actions ───────────────────────────────────────────────────────
    function attendCall() {
        sendBackendCommand("attend")
        root.callTimerRunning = true
        root.callDuration = 0
        root.activeView = "talking"
        // Collapse to bar pill showing live talk timer (per prompt specification)
        root.expanded = false
    }

    function rejectCall() {
        sendBackendCommand("reject")
        root.callTimerRunning = false
        root.callDuration = 0
        root.activeView = "none"
        root.expanded = false
    }

    function endCall() {
        sendBackendCommand("reject")
        root.callTimerRunning = false
        root.callDuration = 0
        root.activeView = "none"
        root.expanded = false
    }

    function dismissNotification() {
        _autoDismissTimer.stop()
        if (root.notifId !== "") {
            sendBackendCommand("dismiss " + root.notifId)
        }
        if (root.callTimerRunning) {
            root.activeView = "talking"
            root.expanded = false
        } else {
            root.activeView = "none"
            root.expanded = false
        }
    }

    function dismissTimer() {
        root.timerCountdownActive = false
        if (root.callTimerRunning) {
            root.activeView = "talking"
            root.expanded = false
        } else {
            root.activeView = "none"
            root.expanded = false
        }
    }

    function dismissAlarm() {
        if (root.callTimerRunning) {
            root.activeView = "talking"
            root.expanded = false
        } else {
            root.activeView = "none"
            root.expanded = false
        }
    }

    function clearMissedCalls() {
        root.missedCallsCount = 0
        root.lastMissedCaller = ""
        if (root.activeView === "missed_call") {
            root.activeView = "none"
            root.expanded = false
        }
    }

    function dismissMissedCall() {
        if (root.activeView === "missed_call") {
            root.activeView = "none"
            root.expanded = false
        }
    }

    function dismissDeviceStatus() {
        if (root.activeView === "device_status") {
            root.activeView = "none"
            root.expanded = false
        }
    }

    function toggleExpand() {
        if (root.activeView === "none") {
            root.activeView = "device_status"
            root.expanded = true
            root.isManualMenu = true
            return
        }
        root.expanded = !root.expanded
        if (root.expanded) {
            root.isManualMenu = true
        } else {
            root.isManualMenu = false
            if (root.activeView === "device_status" || root.activeView === "missed_call") {
                root.activeView = "none"
            }
        }
    }

    function closeIsland() {
        root.expanded = false
        root.isManualMenu = false
        if (root.activeView === "device_status" || root.activeView === "missed_call") {
            root.activeView = "none"
        }
    }

    property var _actionCmdProc: Process {
        id: actionCmdProc
    }

    function sendBackendCommand(cmd) {
        if (backendProc.running) {
            try {
                backendProc.write(cmd + "\n")
            } catch (e) {
                console.warn("[DynamicIsland] Failed to write to backend stdin:", e)
            }
        }
        actionCmdProc.command = ["python3", Paths.script("kdeconnect-service.py"), "send", cmd]
        actionCmdProc.running = true
    }

    // ── Backend Process (KDE Connect Daemon) ──────────────────────────
    property var _backendProc: Process {
        id: backendProc
        command: ["python3", Paths.script("kdeconnect-service.py")]
        running: false
        stdinEnabled: true

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                const trimmed = line.trim()
                if (!trimmed || !trimmed.startsWith("{")) return
                console.info("[DynamicIsland] Received JSON:", trimmed)
                try {
                    const data = JSON.parse(trimmed)
                    root.handleEvent(data)
                } catch (e) {
                    console.warn("[DynamicIsland] Failed to parse JSON:", trimmed, e)
                }
            }
        }

        onExited: function(code, status) {
            // backendRestartTimer.restart()
        }
    }

    property var _backendRestartTimer: Timer {
        id: backendRestartTimer
        interval: 1500
        repeat: false
        running: false
        onTriggered: {
            // if (!backendProc.running) backendProc.running = true
        }
    }

    // ── Event Dispatcher ──────────────────────────────────────────────
    function handleEvent(data) {
        if (!data || !data.type) return

        if (data.type === "status") {
            if (data.phoneName) root.phoneName = data.phoneName
            if (data.battery !== undefined) root.phoneBattery = data.battery
            if (data.charging !== undefined) root.phoneCharging = data.charging
            if (data.notificationsCount !== undefined) root.notificationsCount = data.notificationsCount
            if (data.missedCallsCount !== undefined) root.missedCallsCount = data.missedCallsCount
            if (data.lastMissedCaller !== undefined) root.lastMissedCaller = data.lastMissedCaller
        } else if (data.type === "missed_call") {
            root.missedCallsCount = data.count || (root.missedCallsCount + 1)
            root.lastMissedCaller = data.caller || root.lastMissedCaller || "Unknown"
        } else if (data.type === "call") {
            const state = data.state || ""
            if (state === "ringing") {
                root.callerName = data.contact || "Unknown Caller"
                root.callerNumber = data.number || ""
                root.activeView = "call"
                root.expanded = true // Expand below the bar with Accept / Reject buttons
            } else if (state === "talking") {
                root.callerName = data.contact || root.callerName
                root.callerNumber = data.number || root.callerNumber
                if (data.startTime && data.startTime > 0) {
                    const elapsed = Math.floor((Date.now() / 1000) - data.startTime)
                    root.callDuration = Math.max(0, elapsed)
                }
                root.callTimerRunning = true
                root.activeView = "talking"
                root.expanded = false // Collapses into compact pill with live timer
            } else if (state === "ended") {
                root.callTimerRunning = false
                root.callDuration = 0
                root.activeView = "none"
                root.expanded = false
            }
        } else if (data.type === "notification") {
            root.notificationsCount += 1
            // Focus Mode obedience: do NOT interrupt with popup when Focus Mode / DND is active
            if (root.focusMode) {
                console.info("[DynamicIsland] Focus Mode active: mobile notification popup suppressed")
                return
            }
            root.wasTalkingBeforeNotif = (root.activeView === "talking")
            root.notifId = data.id || ""
            root.notifApp = data.app || "Notification"
            root.notifTitle = data.title || ""
            root.notifBody = data.body || ""
            root.notifIcon = data.icon || ""
            root.activeView = "notification"
            root.expanded = true // Expand below the bar to show the notification
            _autoDismissTimer.restart()
        } else if (data.type === "notification_removed") {
            if (root.notificationsCount > 0) root.notificationsCount -= 1
            if (root.activeView === "notification" && root.notifId === data.id) {
                root.dismissNotification()
            }
        } else if (data.type === "all_notifications_removed") {
            root.notificationsCount = 0
            if (root.activeView === "notification") {
                root.dismissNotification()
            }
        } else if (data.type === "timer") {
            root.timerTitle = data.title || "Timer"
            root.timerSeconds = data.seconds || 154
            root.timerCountdownActive = true
            root.activeView = "timer"
            root.expanded = true
        } else if (data.type === "alarm") {
            root.alarmTitle = data.title || data.body || "Alarm"
            root.activeView = "alarm"
            root.expanded = true
        } else if (data.type === "toggle") {
            root.toggleExpand()
        }
    }
}
