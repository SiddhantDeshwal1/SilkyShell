import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import Quickshell.Widgets

// ─────────────────────────────────────────────────────────────────────────────
// NotificationWidget — macOS-Style Floating Notification Cards & History Center.
//
// Design:
//   - Individual standalone floating rounded glass boxes (no giant panel wrapper).
//   - Notification history has no "Notifications" title; shows floating "Clear All" pill.
//   - Highly curvy cards (cardRadius: 26) with authentic Apple macOS squircle badges.
//   - Full backdrop click-away dismiss.
//   - Subtle & Buttery Smooth 60fps Left-to-Right Dismissal Animations.
//   - Zero Flash / Zero Pop dismissal state machine.
//   - Mutual exclusivity: opening notifications closes Control Center.
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    // ── Apple SF Pro Rounded Typography ──────────────────────────────
    readonly property string sfFont: "SF Pro Rounded"
    readonly property string sfFontMedium: "SF Pro Rounded"
    readonly property string sfFontSemibold: "SF Pro Rounded"
    readonly property string sfFontBold: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    property int lastNotifId: 0
    property bool dndActive: false
    property bool panelOpen: false
    property var controlCenter: null

    // Grouped History List (Stores clubbed notifications by application)
    property var groupList: []
    property bool _historyLoaded: false

    FileView {
        id: historyStorage
        path: "/home/banana/.cache/quickshell/notification_history.json"
        printErrors: false
        watchChanges: false
        onLoaded: root.loadHistory()
        onLoadFailed: function(err) {
            root._historyLoaded = true
        }
    }

    function loadHistory() {
        if (root._historyLoaded) return
        try {
            const content = historyStorage.text()
            if (!content || content.trim() === "") {
                return
            }
            const data = JSON.parse(content.trim())
            if (Array.isArray(data)) {
                root.groupList = data
                let maxId = root.lastNotifId
                for (let i = 0; i < data.length; i++) {
                    let items = data[i].items || []
                    for (let j = 0; j < items.length; j++) {
                        if (items[j].notifId && items[j].notifId > maxId) {
                            maxId = items[j].notifId
                        }
                    }
                }
                root.lastNotifId = maxId
                root._historyLoaded = true
            }
        } catch(e) {
            console.log("Failed to parse notification history:", e)
            root._historyLoaded = true
        }
    }

    function saveHistory() {
        if (!root._historyLoaded) {
            root.loadHistory()
        }
        try {
            const jsonStr = JSON.stringify(root.groupList || [])
            historyStorage.setText(jsonStr)
        } catch(e) {
            console.log("Failed to save notification history:", e)
        }
    }

    Component.onCompleted: {
        root.loadHistory()
    }

    // Transient Toast Model (Active popups)
    ListModel {
        id: toastModel
    }

    function addNotificationToHistory(notif) {
        if (!root._historyLoaded) {
            root.loadHistory()
        }
        root.openedWithEmptyHistory = false
        let groups = []
        for (let i = 0; i < root.groupList.length; i++) {
            groups.push(root.groupList[i])
        }

        let isSingle = notif.groupKey && notif.groupKey.indexOf("single:") === 0

        let foundIdx = -1
        if (!isSingle) {
            for (let i = 0; i < groups.length; i++) {
                if (groups[i].groupKey === notif.groupKey) {
                    foundIdx = i
                    break
                }
            }
        }

        if (foundIdx >= 0) {
            let grp = groups[foundIdx]
            let oldItems = grp.items || []
            let newItems = [notif]
            for (let j = 0; j < oldItems.length; j++) {
                if (j < 14) newItems.push(oldItems[j])
            }
            let iSrc = notif.iconSource || grp.iconSource || ""
            let aIcn = notif.appIcon || grp.appIcon || "󰂞"
            let iBg = notif.iconBg || grp.iconBg || "#2563eb"

            groups.splice(foundIdx, 1)
            groups.unshift({
                groupKey:   grp.groupKey,
                app:        notif.app,
                iconSource: iSrc,
                appIcon:    aIcn,
                iconBg:     iBg,
                count:      newItems.length,
                items:      newItems
            })
        } else {
            groups.unshift({
                groupKey:   notif.groupKey,
                app:        notif.app,
                iconSource: notif.iconSource,
                appIcon:    notif.appIcon,
                iconBg:     notif.iconBg,
                count:      1,
                items:      [notif]
            })
        }

        if (groups.length > 25) {
            groups.pop()
        }
        root.groupList = groups
        root.saveHistory()
    }

    // Helper process runner
    Process { id: notifProc }
    function runShell(cmd) {
        notifProc.command = ["sh", "-c", cmd]
        notifProc.running = true
    }

    // Format local filesystem icon path to valid QML URL
    function formatIconUrl(p) {
        if (!p) return ""
        const s = String(p).trim()
        if (s === "") return ""
        if (s.startsWith("/") && !s.startsWith("//")) return "file://" + s
        return s
    }

    // Helper to clean hostname / web domain
    function cleanDomain(str) {
        if (!str) return ""
        let s = String(str).trim()
        s = s.replace(/^[a-zA-Z]+:\/\//, "")
        let slashIdx = s.indexOf("/")
        if (slashIdx !== -1) s = s.substring(0, slashIdx)
        let colonIdx = s.indexOf(":")
        if (colonIdx !== -1) s = s.substring(0, colonIdx)
        s = s.trim().toLowerCase()
        if (s.indexOf(".") !== -1 && s.indexOf(" ") === -1 && s.length > 3) {
            return s
        }
        return ""
    }

    // Helper to resolve specific origin/service vs. host browser/generic app
    function resolveNotificationSource(notification, rawAppName, summary, bodyText, notifId) {
        const hints = notification.hints || {}
        const appRaw = (rawAppName || "").trim()
        const appLower = appRaw.toLowerCase()
        const sumLower = (summary || "").toLowerCase()
        const bodyLower = (bodyText || "").toLowerCase()
        const deskEntry = (notification.desktopEntry || "").toLowerCase()

        // Gather origin hints
        let originCandidates = []
        if (hints["x-kde-origin-name"]) originCandidates.push(String(hints["x-kde-origin-name"]))
        if (hints["origin"]) originCandidates.push(String(hints["origin"]))
        if (hints["origin-url"]) originCandidates.push(String(hints["origin-url"]))
        if (hints["desktop-entry"]) originCandidates.push(String(hints["desktop-entry"]))
        if (deskEntry) originCandidates.push(deskEntry)

        const originStr = originCandidates.join(" ").toLowerCase()

        // Browser detection
        const browserKeywords = ["chrome", "chromium", "brave", "firefox", "zen", "vivaldi", "opera", "edge", "waterfox", "librewolf"]
        let isBrowser = false
        for (let b = 0; b < browserKeywords.length; b++) {
            if (appLower.indexOf(browserKeywords[b]) !== -1 || originStr.indexOf(browserKeywords[b]) !== -1) {
                isBrowser = true
                break
            }
        }

        // Generic app detection (must NOT stack together unless specific source identified)
        const genericApps = ["", "notification", "notifications", "notify-send", "unknown", "quickshell", "bash", "sh", "python", "system"]
        const isGeneric = genericApps.indexOf(appLower) !== -1

        // 1. WhatsApp / WhatsApp Web
        if (originStr.indexOf("whatsapp") !== -1 || appLower.indexOf("whatsapp") !== -1 || 
            sumLower.indexOf("whatsapp") !== -1 || bodyLower.indexOf("web.whatsapp.com") !== -1) {
            return {
                sourceName: "WhatsApp Web",
                groupKey: "source:whatsapp",
                appIcon: "󰖣",
                iconBg: "#25d366",
                isWebSource: true
            }
        }

        // 2. Gmail / Google Mail
        if (originStr.indexOf("mail.google.com") !== -1 || originStr.indexOf("gmail") !== -1 || 
            appLower.indexOf("gmail") !== -1 || sumLower.indexOf("gmail") !== -1 || 
            bodyLower.indexOf("mail.google.com") !== -1 || sumLower.indexOf("mail.google.com") !== -1) {
            return {
                sourceName: "Gmail",
                groupKey: "source:gmail",
                appIcon: "󰇮",
                iconBg: "#ea4335",
                isWebSource: true
            }
        }

        // 3. Google Calendar
        if (originStr.indexOf("calendar.google.com") !== -1 || sumLower.indexOf("calendar.google.com") !== -1 || bodyLower.indexOf("calendar.google.com") !== -1) {
            return {
                sourceName: "Google Calendar",
                groupKey: "source:google-calendar",
                appIcon: "󰸗",
                iconBg: "#4285f4",
                isWebSource: true
            }
        }

        // 4. Google Meet
        if (originStr.indexOf("meet.google.com") !== -1 || sumLower.indexOf("meet.google.com") !== -1 || bodyLower.indexOf("meet.google.com") !== -1) {
            return {
                sourceName: "Google Meet",
                groupKey: "source:google-meet",
                appIcon: "󰕧",
                iconBg: "#00897b",
                isWebSource: true
            }
        }

        // 5. Google Drive / Docs / Sheets
        if (originStr.indexOf("drive.google.com") !== -1 || originStr.indexOf("docs.google.com") !== -1) {
            return {
                sourceName: "Google Docs",
                groupKey: "source:google-docs",
                appIcon: "󰈙",
                iconBg: "#1a73e8",
                isWebSource: true
            }
        }

        // 6. YouTube
        if (originStr.indexOf("youtube.com") !== -1 || originStr.indexOf("youtu.be") !== -1 || 
            sumLower.indexOf("youtube") !== -1 || bodyLower.indexOf("youtube.com") !== -1) {
            return {
                sourceName: "YouTube",
                groupKey: "source:youtube",
                appIcon: "󰗃",
                iconBg: "#ff0000",
                isWebSource: true
            }
        }

        // 7. Discord (Web or App)
        if (originStr.indexOf("discord") !== -1 || appLower.indexOf("discord") !== -1) {
            return {
                sourceName: "Discord",
                groupKey: "source:discord",
                appIcon: "󰙯",
                iconBg: "#5865f2",
                isWebSource: isBrowser
            }
        }

        // 8. Telegram (Web or App)
        if (originStr.indexOf("telegram") !== -1 || appLower.indexOf("telegram") !== -1) {
            return {
                sourceName: "Telegram",
                groupKey: "source:telegram",
                appIcon: "󰈔",
                iconBg: "#0284c7",
                isWebSource: isBrowser
            }
        }

        // 9. Slack (Web or App)
        if (originStr.indexOf("slack") !== -1 || appLower.indexOf("slack") !== -1) {
            return {
                sourceName: "Slack",
                groupKey: "source:slack",
                appIcon: "󰒱",
                iconBg: "#4a154b",
                isWebSource: isBrowser
            }
        }

        // 10. GitHub (Web or App)
        if (originStr.indexOf("github") !== -1 || appLower.indexOf("github") !== -1) {
            return {
                sourceName: "GitHub",
                groupKey: "source:github",
                appIcon: "󰊤",
                iconBg: "#24292e",
                isWebSource: isBrowser
            }
        }

        // 11. Reddit
        if (originStr.indexOf("reddit") !== -1 || appLower.indexOf("reddit") !== -1) {
            return {
                sourceName: "Reddit",
                groupKey: "source:reddit",
                appIcon: "󰑍",
                iconBg: "#ff4500",
                isWebSource: isBrowser
            }
        }

        // 12. Twitter / X
        if (originStr.indexOf("twitter.com") !== -1 || originStr.indexOf("x.com") !== -1) {
            return {
                sourceName: "X",
                groupKey: "source:twitter",
                appIcon: "󰕄",
                iconBg: "#0f1419",
                isWebSource: true
            }
        }

        // 13. Spotify (Web or App)
        if (originStr.indexOf("spotify") !== -1 || appLower.indexOf("spotify") !== -1) {
            return {
                sourceName: "Spotify",
                groupKey: "source:spotify",
                appIcon: "󰝚",
                iconBg: "#1db954",
                isWebSource: isBrowser
            }
        }

        // 14. Arbitrary Web Domain Extraction (from origin hints)
        for (let c = 0; c < originCandidates.length; c++) {
            let dom = root.cleanDomain(originCandidates[c])
            if (dom !== "") {
                let parts = dom.split(".")
                let domainName = parts.length > 2 ? parts[parts.length - 2] : parts[0]
                let title = domainName.charAt(0).toUpperCase() + domainName.slice(1)
                return {
                    sourceName: title,
                    groupKey: "web:" + dom,
                    appIcon: "󰇧",
                    iconBg: "#f59e0b",
                    isWebSource: true
                }
            }
        }

        // Also check if summary or body has a domain pattern e.g. "somewebsite.com"
        if (isBrowser) {
            let matchDomain = summary.match(/([a-zA-Z0-9-]+\.[a-zA-Z]{2,})/i) || bodyText.match(/([a-zA-Z0-9-]+\.[a-zA-Z]{2,})/i)
            if (matchDomain && matchDomain[1]) {
                let dom = root.cleanDomain(matchDomain[1])
                if (dom !== "") {
                    let parts = dom.split(".")
                    let domainName = parts.length > 2 ? parts[parts.length - 2] : parts[0]
                    let title = domainName.charAt(0).toUpperCase() + domainName.slice(1)
                    return {
                        sourceName: title,
                        groupKey: "web:" + dom,
                        appIcon: "󰇧",
                        iconBg: "#f59e0b",
                        isWebSource: true
                    }
                }
            }
        }

        // 15. If Browser but NO specific website source could be determined:
        if (isBrowser) {
            return {
                sourceName: appRaw || "Browser",
                groupKey: "app:" + (appLower || "browser"),
                appIcon: "󰇧",
                iconBg: "#f59e0b",
                isWebSource: true
            }
        }

        // 16. Generic or CLI/system notification (notify-send, bash, etc.):
        // Group by application name so repeated notifications form a neat stack
        if (isGeneric) {
            const cleanApp = (appRaw && appRaw.trim() !== "") ? appRaw : "Notification"
            const cleanKey = (appLower && appLower.trim() !== "") ? appLower : "notification"
            return {
                sourceName: cleanApp,
                groupKey: "app:" + cleanKey,
                appIcon: "󰂞",
                iconBg: "#2563eb",
                isWebSource: false
            }
        }

        // 17. Dedicated desktop application (e.g. VLC, Steam, GIMP, Alacritty):
        return {
            sourceName: appRaw,
            groupKey: "app:" + (appLower || "notification"),
            appIcon: "󰂞",
            iconBg: "#2563eb",
            isWebSource: false
        }
    }

    // Helper to resolve primary notification icon vs. sending app fallback icon
    function resolveNotificationIcon(notification, appName, sourceInfo) {
        let iconSource = ""
        let appIcon = (sourceInfo && sourceInfo.appIcon) ? sourceInfo.appIcon : "󰂞"
        let iconBg = (sourceInfo && sourceInfo.iconBg) ? sourceInfo.iconBg : "#2563eb"

        // 1. PRIMARY: Check if the notification itself provided an image or custom icon
        if (notification.image && String(notification.image).trim() !== "") {
            iconSource = root.formatIconUrl(notification.image)
        } else if (notification.appIcon && String(notification.appIcon).trim() !== "") {
            const rawIcon = String(notification.appIcon).trim()
            if (rawIcon.startsWith("/") || rawIcon.startsWith("file://") || rawIcon.startsWith("image://")) {
                iconSource = root.formatIconUrl(rawIcon)
            } else {
                // If it's a generic browser icon name but the source is a web service (WhatsApp, Gmail, etc.),
                // prioritize the branded service glyph & accent color instead
                const rawLower = rawIcon.toLowerCase()
                const isBrowserIcon = rawLower.includes("chrome") || rawLower.includes("chromium") ||
                                      rawLower.includes("brave") || rawLower.includes("firefox") ||
                                      rawLower.includes("zen") || rawLower.includes("browser")
                const isIdentifiedWeb = sourceInfo && sourceInfo.isWebSource && sourceInfo.groupKey.indexOf("source:") === 0

                if (!isIdentifiedWeb || !isBrowserIcon) {
                    try {
                        const de = DesktopEntries.heuristicLookup(rawIcon)
                        if (de && de.icon) {
                            iconSource = Quickshell.iconPath(de.icon) || de.icon
                        } else {
                            iconSource = Quickshell.iconPath(rawIcon) || rawIcon
                        }
                    } catch(e) {
                        try {
                            iconSource = Quickshell.iconPath(rawIcon) || rawIcon
                        } catch(e2) {
                            iconSource = rawIcon
                        }
                    }
                }
            }
        }

        // 2. FALLBACK: When no icon was received with the notification
        const isIdentifiedWeb = sourceInfo && sourceInfo.isWebSource && sourceInfo.groupKey.indexOf("source:") === 0
        if (!iconSource || iconSource === "") {
            if (!isIdentifiedWeb) {
                const desktopKey = (notification.desktopEntry || "").trim()
                if (desktopKey !== "") {
                    try {
                        const de = DesktopEntries.heuristicLookup(desktopKey)
                        if (de && de.icon) {
                            iconSource = Quickshell.iconPath(de.icon) || de.icon
                        } else {
                            iconSource = Quickshell.iconPath(desktopKey) || desktopKey
                        }
                    } catch(e) {}
                }

                if (!iconSource || iconSource === "") {
                    const lookupName = (sourceInfo && sourceInfo.sourceName) ? sourceInfo.sourceName : appName
                    const appClean = (lookupName || "").trim()
                    if (appClean !== "") {
                        try {
                            const de = DesktopEntries.heuristicLookup(appClean)
                            if (de && de.icon) {
                                iconSource = Quickshell.iconPath(de.icon) || de.icon
                            }
                        } catch(e) {}
                        if (!iconSource || iconSource === "") {
                            try {
                                iconSource = Quickshell.iconPath(appClean.toLowerCase()) || Quickshell.iconPath(appClean)
                            } catch(e) {}
                        }
                    }
                }
            }
        }

        // 3. Fallback glyph and color accents if not already set by sourceInfo
        if (!sourceInfo || !sourceInfo.appIcon) {
            const appLower = (appName || "").toLowerCase()
            if (appLower.includes("spotify") || appLower.includes("music")) {
                appIcon = "󰝚"
                iconBg = "#10b981"
            } else if (appLower.includes("discord")) {
                appIcon = "󰙯"
                iconBg = "#5865f2"
            } else if (appLower.includes("github") || appLower.includes("git")) {
                appIcon = "󰊤"
                iconBg = "#2563eb"
            } else if (appLower.includes("code") || appLower.includes("vsc") || appLower.includes("nvim")) {
                appIcon = "󰨞"
                iconBg = "#0284c7"
            } else if (appLower.includes("telegram")) {
                appIcon = "󰈔"
                iconBg = "#0284c7"
            } else if (appLower.includes("steam")) {
                appIcon = "󰓓"
                iconBg = "#1e293b"
            } else if (appLower.includes("chrome") || appLower.includes("firefox") || appLower.includes("browser") || appLower.includes("brave") || appLower.includes("zen")) {
                appIcon = "󰇧"
                iconBg = "#f59e0b"
            } else if (appLower.includes("fitness") || appLower.includes("health")) {
                appIcon = "󰋉"
                iconBg = "#ef4444"
            } else if (appLower.includes("terminal") || appLower.includes("kitty") || appLower.includes("alacritty") || appLower.includes("foot") || appLower.includes("wezterm")) {
                appIcon = "󰆍"
                iconBg = "#334155"
            } else if (appLower.includes("mail") || appLower.includes("gmail") || appLower.includes("thunderbird")) {
                appIcon = "󰇮"
                iconBg = "#3b82f6"
            } else if (appLower.includes("settings") || appLower.includes("system") || appLower.includes("control")) {
                appIcon = "󰒓"
                iconBg = "#64748b"
            } else if (appLower.includes("file") || appLower.includes("folder") || appLower.includes("thunar") || appLower.includes("dolphin")) {
                appIcon = "󰉋"
                iconBg = "#0284c7"
            }
        }

        return {
            iconSource: iconSource,
            appIcon: appIcon,
            iconBg: iconBg
        }
    }

    NotificationServer {
        id: notifServer
        keepOnReload: true

        onNotification: function(notification) {
            notification.tracked = false

            const id = ++root.lastNotifId
            const now = new Date()
            const hours = String(now.getHours()).padStart(2, "0")
            const mins = String(now.getMinutes()).padStart(2, "0")
            const timeStr = hours + ":" + mins
            const timeout = notification.expireTimeout > 0 ? notification.expireTimeout : 5000

            const appName = notification.appName && notification.appName.trim() !== "" 
                ? notification.appName.trim() 
                : "Notification"
            const summary = notification.summary ? notification.summary.trim() : ""
            const bodyText = notification.body ? notification.body.trim() : ""

            // Resolve real source and grouping key
            const sourceInfo = root.resolveNotificationSource(notification, appName, summary, bodyText, id)

            // Resolve primary icon with app fallback and branded glyphs
            const iconInfo = root.resolveNotificationIcon(notification, appName, sourceInfo)

            // 1. Store to Grouped History
            root.addNotificationToHistory({
                notifId:    id,
                title:      summary,
                body:       bodyText,
                app:        sourceInfo.sourceName,
                groupKey:   sourceInfo.groupKey,
                timeStr:    timeStr,
                iconSource: iconInfo.iconSource,
                appIcon:    iconInfo.appIcon,
                iconBg:     iconInfo.iconBg,
                timestamp:  now.getTime()
            })

            // 2. If DND is active or Panel is open, don't show floating popup toast
            if (root.dndActive || root.panelOpen) return

            // 2b. Phone notifications are displayed exclusively by Dynamic Island.
            // They are preserved in Notification History above, but corner toast is suppressed to avoid duplicates.
            const appLower = appName.toLowerCase()
            const deskEntry = (notification.desktopEntry || "").toLowerCase()
            const srcName = (sourceInfo.sourceName || "").toLowerCase()
            const hints = notification.hints || {}
            const isPhoneNotification = appLower.includes("kdeconnect") 
                || deskEntry.includes("kdeconnect")
                || srcName.includes("kdeconnect")
                || (hints["x-kde-origin-name"] !== undefined)
                || (hints["x-kdeconnect-device-id"] !== undefined)
                || (hints["x-kdeconnect-id"] !== undefined)
                || (hints["kdeconnect-id"] !== undefined)
                || (hints["desktop-entry"] && String(hints["desktop-entry"]).toLowerCase().includes("kdeconnect"))

            if (isPhoneNotification) return

            // 3. Show floating toast for ONLY this newly arrived notification
            toastModel.append({
                notifId:    id,
                title:      summary,
                body:       bodyText,
                app:        sourceInfo.sourceName,
                timeStr:    timeStr,
                iconSource: iconInfo.iconSource,
                appIcon:    iconInfo.appIcon,
                iconBg:     iconInfo.iconBg,
                timeout:    timeout
            })
        }
    }

    property bool clearingAll: false
    property bool isPanelVisible: false
    property bool openedWithEmptyHistory: false

    function togglePanel() {
        if (panelOpen) closePanel()
        else openPanel()
    }

    function openPanel() {
        hidePanelTimer.stop()
        if (root.controlCenter) {
            root.controlCenter.close()
        }
        root.openedWithEmptyHistory = (!root.groupList || root.groupList.length === 0)
        panelOpen = true
        isPanelVisible = true
        toastModel.clear()
    }

    function closePanel() {
        panelOpen = false
        hidePanelTimer.restart()
    }

    Timer {
        id: hidePanelTimer
        interval: root.openedWithEmptyHistory ? 440 : 200
        repeat: false
        onTriggered: {
            if (!root.panelOpen) {
                root.isPanelVisible = false
                root.openedWithEmptyHistory = false
            }
        }
    }

    function clearAll() {
        if (!root.groupList || root.groupList.length === 0 || clearingAll) return
        clearingAll = true
        root.openedWithEmptyHistory = false
        clearAnimTimer.restart()
    }

    Timer {
        id: clearAnimTimer
        interval: 330
        repeat: false
        onTriggered: {
            root.groupList = []
            root.saveHistory()
            root.clearingAll = false
            root.closePanel()
        }
    }

    function removeNotification(id) {
        let groups = []
        for (let i = 0; i < (root.groupList ? root.groupList.length : 0); i++) {
            let grp = root.groupList[i]
            let oldItems = grp.items || []
            let found = false
            let newItems = []
            for (let j = 0; j < oldItems.length; j++) {
                if (oldItems[j].notifId === id) {
                    found = true
                } else {
                    newItems.push(oldItems[j])
                }
            }
            if (found) {
                if (newItems.length > 0) {
                    groups.push({
                        groupKey:   grp.groupKey,
                        app:        grp.app,
                        iconSource: grp.iconSource,
                        appIcon:    grp.appIcon,
                        iconBg:     grp.iconBg,
                        count:      newItems.length,
                        items:      newItems
                    })
                }
            } else {
                groups.push(grp)
            }
        }
        root.groupList = groups
        root.saveHistory()
    }

    function removeGroup(groupKey) {
        if (!root.groupList) return
        root.groupList = root.groupList.filter(function(g) { return g.groupKey !== groupKey })
        root.saveHistory()
    }

    Timer {
        id: toastExitGraceTimer
        interval: 350
        repeat: false
    }

    property bool hasActiveToasts: toastModel.count > 0 || toastExitGraceTimer.running

    function removeToast(id) {
        for (let i = 0; i < toastModel.count; i++) {
            if (toastModel.get(i).notifId === id) {
                toastModel.remove(i)
                toastExitGraceTimer.restart()
                break
            }
        }
    }

    IpcHandler {
        target: "notifications"
        function toggle() { root.togglePanel() }
        function open() { root.openPanel() }
        function close() { root.closePanel() }
        function clearAll() { root.clearAll() }
    }

    // ── Full Window Layer for Reliable Backdrop Click-Away ────────────
    anchors {
        top: true
        left: true
        right: true
    }

    WlrLayershell.margins.top: 28
    implicitHeight: Screen.height - 28

    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-notifications"
    WlrLayershell.keyboardFocus: root.panelOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    color: "transparent"
    visible: root.isPanelVisible || root.hasActiveToasts

    mask: root.isPanelVisible ? fullRegion : toastRegion

    Region {
        id: fullRegion
        x: 0
        y: 0
        width: root.width
        height: root.height
    }

    Region {
        id: toastRegion
        x: root.width - 376 - 20
        y: 0
        width: 376 + 20
        height: (!root.panelOpen && root.hasActiveToasts) ? Math.min(Screen.height - 28, Math.max(toastListView.contentHeight + 40, Math.max(1, toastModel.count) * 220 + 60)) : 0
    }

    // Backdrop Click-away: clicking anywhere outside history cards closes the panel
    MouseArea {
        anchors.fill: parent
        enabled: root.panelOpen
        hoverEnabled: false
        focus: root.panelOpen

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.closePanel()
                event.accepted = true
            }
        }
        onClicked: function(mouse) {
            const pad = 10
            const cardLeft = historyContainer.x + historyTrans.x
            const cardRight = cardLeft + historyContainer.width
            const cardTop = historyContainer.y
            const cardBottom = cardTop + historyContainer.height
            const inCard = (mouse.x >= cardLeft - pad && mouse.x <= cardRight + pad &&
                            mouse.y >= cardTop - pad && mouse.y <= cardBottom + pad)
            if (!inCard) {
                root.closePanel()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // LAYER 1: NOTIFICATION CENTER HISTORY STACK (Curvy Floating Boxes)
    // ══════════════════════════════════════════════════════════════════
    Item {
        id: historyContainer
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 8
        anchors.rightMargin: 16
        width: 376
        implicitHeight: historyCol.implicitHeight
        height: Math.min(implicitHeight, Screen.height - 60)

        // Fluid liquid spring transform: coordinated scale and translation
        transform: [
            Translate {
                id: historyTrans
                x: root.panelOpen ? 0 : 28
                Behavior on x {
                    NumberAnimation {
                        duration: root.panelOpen ? 520 : 380
                        easing.type: root.panelOpen ? Easing.OutBack : Easing.InCubic
                        easing.overshoot: 1.15
                    }
                }
            },
            Scale {
                id: historyScale
                origin.x: historyContainer.width
                origin.y: 0
                xScale: root.panelOpen ? 1.0 : 0.96
                yScale: root.panelOpen ? 1.0 : 0.96
                Behavior on xScale {
                    NumberAnimation {
                        duration: root.panelOpen ? 520 : 380
                        easing.type: root.panelOpen ? Easing.OutBack : Easing.InCubic
                        easing.overshoot: 1.15
                    }
                }
                Behavior on yScale {
                    NumberAnimation {
                        duration: root.panelOpen ? 520 : 380
                        easing.type: root.panelOpen ? Easing.OutBack : Easing.InCubic
                        easing.overshoot: 1.15
                    }
                }
            }
        ]

        opacity: root.panelOpen ? 1.0 : 0.0
        Behavior on opacity {
            NumberAnimation {
                duration: root.panelOpen ? 420 : 300
                easing.type: root.panelOpen ? Easing.OutCubic : Easing.InCubic
            }
        }

        visible: root.isPanelVisible

        ColumnLayout {
            id: historyCol
            width: parent.width
            spacing: 10

            // Floating Header: Only [ Clear All ] Button (No "Notifications" Title)
            RowLayout {
                Layout.fillWidth: true
                visible: root.groupList && root.groupList.length > 0
                opacity: root.clearingAll ? 0.0 : 1.0
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                Item { Layout.fillWidth: true }

                // Clear All Pill Button
                Rectangle {
                    implicitWidth: clearText.implicitWidth + 30
                    implicitHeight: 36
                    radius: 18
                    color: clearMouse.containsMouse 
                        ? (Theme.darkMode ? "#45ffffff" : "#25000000") 
                        : (Theme.darkMode ? "#22ffffff" : "#12000000")
                    border.width: 1
                    border.color: clearMouse.containsMouse 
                        ? (Theme.darkMode ? "#90ffffff" : "#45000000") 
                        : (Theme.darkMode ? "#40ffffff" : "#20000000")

                    scale: clearMouse.pressed ? 0.94 : (clearMouse.containsMouse ? 1.05 : 1.0)
                    Behavior on scale {
                        NumberAnimation {
                            duration: 125
                            easing.type: Easing.OutBack
                            easing.overshoot: 1.15
                        }
                    }
                    Behavior on color { ColorAnimation { duration: 105 } }
                    Behavior on border.color { ColorAnimation { duration: 105 } }

                    Text {
                        id: clearText
                        anchors.centerIn: parent
                        text: "Clear All"
                        font.family: root.sfFontMedium
                        font.pixelSize: 15
                        color: Theme.darkMode ? "#ffffff" : "#000000"
                        renderType: Text.QtRendering
                    }

                    MouseArea {
                        id: clearMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.clearAll()
                    }
                }
            }

            // Empty State Card (With Smooth Opening and Closing Animations)
            LiquidGlassCard {
                id: emptyStateCard
                visible: root.openedWithEmptyHistory && (!root.groupList || root.groupList.length === 0) && !root.clearingAll && root.isPanelVisible
                Layout.fillWidth: true
                implicitHeight: 82
                cardRadius: 26

                transform: [
                    Translate {
                        id: emptyTrans
                        x: root.panelOpen ? 0 : 32
                        y: root.panelOpen ? 0 : 12
                        Behavior on x {
                            NumberAnimation {
                                duration: root.panelOpen ? 600 : 400
                                easing.type: root.panelOpen ? Easing.OutBack : Easing.InCubic
                                easing.overshoot: 1.15
                            }
                        }
                        Behavior on y {
                            NumberAnimation {
                                duration: root.panelOpen ? 600 : 400
                                easing.type: root.panelOpen ? Easing.OutBack : Easing.InCubic
                                easing.overshoot: 1.15
                            }
                        }
                    },
                    Scale {
                        id: emptyScale
                        origin.x: emptyStateCard.width / 2
                        origin.y: emptyStateCard.height / 2
                        xScale: root.panelOpen ? 1.0 : 0.90
                        yScale: root.panelOpen ? 1.0 : 0.90
                        Behavior on xScale {
                            NumberAnimation {
                                duration: root.panelOpen ? 600 : 400
                                easing.type: root.panelOpen ? Easing.OutBack : Easing.InCubic
                                easing.overshoot: 1.15
                            }
                        }
                        Behavior on yScale {
                            NumberAnimation {
                                duration: root.panelOpen ? 600 : 400
                                easing.type: root.panelOpen ? Easing.OutBack : Easing.InCubic
                                easing.overshoot: 1.15
                            }
                        }
                    }
                ]

                opacity: root.panelOpen ? 1.0 : 0.0
                Behavior on opacity {
                    NumberAnimation {
                        duration: root.panelOpen ? 450 : 320
                        easing.type: root.panelOpen ? Easing.OutCubic : Easing.InCubic
                    }
                }

                RowLayout {
                    anchors.centerIn: parent
                    spacing: 12

                    Text {
                        font.family: root.iconFont
                        font.pixelSize: 26
                        color: Theme.darkMode ? "#64748b" : "#475569"
                        text: "󰂚"
                        renderType: Text.QtRendering
                    }

                    Text {
                        text: "No Notifications"
                        font.family: root.sfFontMedium
                        font.pixelSize: 17
                        color: Theme.darkMode ? "#94a3b8" : "#000000"
                        renderType: Text.QtRendering
                    }
                }
            }

            // Scrollable History Cards List (Clubbed Group Stacks)
            ListView {
                id: historyListView
                Layout.fillWidth: true
                implicitHeight: Math.min(contentHeight, Screen.height - 130)
                Layout.preferredHeight: implicitHeight
                clip: true
                spacing: 12
                model: root.groupList
                boundsBehavior: Flickable.StopAtBounds

                displaced: Transition {
                    NumberAnimation {
                        property: "y"
                        duration: 560
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: [0.25, 1.08, 0.22, 1.0, 1.0, 1.0]
                    }
                }

                remove: Transition {
                    ParallelAnimation {
                        NumberAnimation { property: "x"; to: 80; duration: 320; easing.type: Easing.OutCubic }
                        NumberAnimation { property: "opacity"; to: 0.0; duration: 280 }
                    }
                }

                add: Transition {
                    ParallelAnimation {
                        NumberAnimation { property: "x"; from: 60; to: 0; duration: 360; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
                        NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 300 }
                    }
                }

                delegate: NotificationGroupCard {
                    id: groupDelegate
                    width: historyListView.width
                    groupKey: modelData.groupKey || ""
                    appName: modelData.app || "Notification"
                    iconSource: modelData.iconSource || ""
                    appIcon: modelData.appIcon || "󰂞"
                    iconBg: modelData.iconBg || "#2563eb"
                    notifs: modelData.items || []
                    count: modelData.count || (modelData.items ? modelData.items.length : 0)
                    isClearingAll: root.clearingAll
                    sfFont: root.sfFont
                    sfFontMedium: root.sfFontMedium
                    sfFontSemibold: root.sfFontSemibold
                    sfFontBold: root.sfFontBold
                    iconFont: root.iconFont

                    onDismissNotification: function(notifId) {
                        root.removeNotification(notifId)
                    }
                    onDismissGroup: function(grpKey) {
                        root.removeGroup(grpKey)
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // LAYER 2: TRANSIENT TOAST NOTIFICATIONS (Individual Floating Boxes)
    // ══════════════════════════════════════════════════════════════════
    ListView {
        id: toastListView
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 8
        anchors.rightMargin: 16
        width: 376
        height: Screen.height - 60
        clip: false
        interactive: false
        spacing: 12
        visible: !root.panelOpen && root.hasActiveToasts
        model: toastModel

        // Buttery Smooth 60fps Liquid Opening Glide
        add: Transition {
            ParallelAnimation {
                NumberAnimation {
                    property: "x"
                    from: 100
                    to: 0
                    duration: 320
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    property: "opacity"
                    from: 0.0
                    to: 1.0
                    duration: 220
                    easing.type: Easing.OutQuad
                }
            }
        }

        // Buttery Smooth Liquid Upward Glide on Displacement
        displaced: Transition {
            NumberAnimation {
                property: "y"
                duration: 300
                easing.type: Easing.OutCubic
            }
        }

        addDisplaced: Transition {
            NumberAnimation {
                property: "y"
                duration: 300
                easing.type: Easing.OutCubic
            }
        }

        delegate: Item {
            id: toastCardItem
            width: toastListView.width
            implicitHeight: toastCardRect.height
            height: implicitHeight

            // Local frozen snapshot properties so model destruction during exit never causes flashes
            readonly property int notifId: model.notifId !== undefined ? model.notifId : 0
            readonly property string cardTitle: model.title !== undefined ? String(model.title) : ""
            readonly property string cardBody: model.body !== undefined ? String(model.body) : ""
            readonly property string cardApp: model.app !== undefined ? String(model.app) : "NOTIFICATION"
            readonly property string cardTime: model.timeStr !== undefined ? String(model.timeStr) : ""
            readonly property string cardIconSource: model.iconSource !== undefined ? String(model.iconSource) : ""
            readonly property string cardAppIcon: model.appIcon !== undefined ? String(model.appIcon) : "󰂞"
            readonly property string cardIconBg: model.iconBg !== undefined ? String(model.iconBg) : "#2563eb"
            readonly property int cardTimeout: model.timeout > 0 ? model.timeout : 5000

            property bool isDismissing: false
            property real dragOffsetX: 0
            property real exitOpacity: 1.0

            function startDismiss() {
                if (isDismissing) return
                isDismissing = true
                tAutoTimer.stop()
                exitAnim.restart()
            }

            Timer {
                id: tAutoTimer
                interval: toastCardItem.cardTimeout
                running: !tCardMouse.containsMouse && !tCloseMouse.containsMouse && !toastCardItem.isDismissing
                repeat: false
                onTriggered: toastCardItem.startDismiss()
            }

            // Subtle, Buttery Smooth 60fps Left-to-Right Dismissal Animation
            SequentialAnimation {
                id: exitAnim
                ParallelAnimation {
                    NumberAnimation {
                        target: toastCardItem
                        property: "dragOffsetX"
                        to: toastCardItem.width + 40
                        duration: 260
                        easing.type: Easing.OutCubic
                    }
                    NumberAnimation {
                        target: toastCardItem
                        property: "exitOpacity"
                        to: 0.0
                        duration: 240
                        easing.type: Easing.OutQuad
                    }
                }
                NumberAnimation {
                    target: toastCardItem
                    property: "height"
                    to: 0
                    duration: 160
                    easing.type: Easing.OutCubic
                }
                ScriptAction {
                    script: {
                        root.removeToast(toastCardItem.notifId)
                    }
                }
            }

            // Gentle return if drag was released before threshold
            ParallelAnimation {
                id: springBackAnim
                NumberAnimation {
                    target: toastCardItem
                    property: "dragOffsetX"
                    to: 0
                    duration: 220
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: toastCardItem
                    property: "exitOpacity"
                    to: 1.0
                    duration: 180
                    easing.type: Easing.OutCubic
                }
            }

            LiquidGlassCard {
                id: toastCardRect
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                implicitHeight: Math.min(Screen.height - 120, Math.max(76, tContentRow.implicitHeight + 24))
                height: implicitHeight
                clip: true
                cardRadius: 26
                idleColor: Theme.darkMode ? "#f0131c28" : "#f8ffffff"
                isHovered: tCardMouse.containsMouse

                x: toastCardItem.dragOffsetX
                opacity: toastCardItem.exitOpacity

                scale: (tCardMouse.pressed && !tCardMouse.isDragging)
                    ? 0.98
                    : ((tCardMouse.containsMouse && !tCardMouse.isDragging) ? 1.015 : 1.0)

                Behavior on scale {
                    enabled: !tCardMouse.isDragging && !toastCardItem.isDismissing
                    NumberAnimation {
                        duration: 160
                        easing.type: Easing.OutCubic
                    }
                }

                // Glossy specular shimmer light sweep on tile transition
                Rectangle {
                    id: shimmerFlare
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 70
                    radius: 26
                    x: -width - 20
                    opacity: 0.0
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.5; color: "#35ffffff" }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    transform: Rotation { origin.x: 35; origin.y: 40; angle: 18 }
                }

                SequentialAnimation {
                    id: shimmerAnim
                    ParallelAnimation {
                        NumberAnimation {
                            target: shimmerFlare
                            property: "x"
                            from: -80
                            to: toastCardRect.width + 80
                            duration: 400
                            easing.type: Easing.OutCubic
                        }
                        SequentialAnimation {
                            NumberAnimation { target: shimmerFlare; property: "opacity"; from: 0.0; to: 0.8; duration: 120 }
                            NumberAnimation { target: shimmerFlare; property: "opacity"; to: 0.0; duration: 280 }
                        }
                    }
                }

                Component.onCompleted: {
                    shimmerAnim.restart()
                }

                Connections {
                    target: toastCardItem
                    function onYChanged() {
                        shimmerAnim.restart()
                    }
                }

                // Interactive Swipe-to-Dismiss Gesture
                MouseArea {
                    id: tCardMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                    preventStealing: true

                    property real startX: 0
                    property bool isDragging: false

                    onPressed: function(mouse) {
                        startX = mouse.x
                        isDragging = false
                        tAutoTimer.stop()
                    }

                    onPositionChanged: function(mouse) {
                        if (pressed && !toastCardItem.isDismissing) {
                            let diffX = mouse.x - startX
                            if (diffX > 4 || isDragging) {
                                isDragging = true
                                toastCardItem.dragOffsetX = Math.max(0, diffX)
                                toastCardItem.exitOpacity = Math.max(0.0, 1.0 - (toastCardItem.dragOffsetX / (toastCardRect.width * 0.9)))
                            }
                        }
                    }

                    onReleased: function(mouse) {
                        if (toastCardItem.isDismissing) return
                        if (isDragging) {
                            if (toastCardItem.dragOffsetX > 65) {
                                toastCardItem.startDismiss()
                            } else {
                                springBackAnim.restart()
                            }
                            isDragging = false
                        } else {
                            toastCardItem.startDismiss()
                        }
                    }
                }

                RowLayout {
                    id: tContentRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 12

                    // Left App Squircle Badge (46x46)
                    Rectangle {
                        Layout.alignment: Qt.AlignTop
                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 46
                        radius: 12
                        color: (tIconImg.status === Image.Ready && toastCardItem.cardIconSource !== "")
                            ? "transparent"
                            : (toastCardItem.cardIconBg !== "" ? toastCardItem.cardIconBg : "#2563eb")
                        clip: true

                        IconImage {
                            id: tIconImg
                            anchors.fill: parent
                            anchors.margins: 0
                            source: toastCardItem.cardIconSource
                            visible: toastCardItem.cardIconSource !== "" && status === Image.Ready
                        }

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 24
                            color: "#ffffff"
                            text: toastCardItem.cardAppIcon !== "" ? toastCardItem.cardAppIcon : "󰂞"
                            visible: !tIconImg.visible
                            renderType: Text.QtRendering
                        }
                    }

                    // Right Text Content
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignTop
                        spacing: 3

                        // Header: App Name + Time + Dismiss
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                font.family: root.sfFontSemibold
                                font.pixelSize: 13
                                font.capitalization: Font.AllUppercase
                                color: Theme.darkMode ? "#93c5fd" : "#000000"
                                text: toastCardItem.cardApp !== "" ? toastCardItem.cardApp : "NOTIFICATION"
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                renderType: Text.QtRendering
                            }

                            Text {
                                font.family: root.sfFontSemibold
                                font.pixelSize: 13
                                font.bold: true
                                color: Theme.darkMode ? "#e2e8f0" : "#334155"
                                text: toastCardItem.cardTime
                                visible: toastCardItem.cardTime !== ""
                                renderType: Text.QtRendering
                            }

                            Rectangle {
                                implicitWidth: 22
                                implicitHeight: 22
                                radius: 11
                                color: tCloseMouse.containsMouse ? (Theme.darkMode ? "#33ffffff" : "#20000000") : "transparent"

                                scale: tCloseMouse.pressed ? 0.90 : (tCloseMouse.containsMouse ? 1.12 : 1.0)
                                Behavior on scale {
                                    NumberAnimation {
                                        duration: 120
                                        easing.type: Easing.OutCubic
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    font.family: root.iconFont
                                    font.pixelSize: 14
                                    color: tCloseMouse.containsMouse ? "#ef4444" : (Theme.darkMode ? "#94a3b8" : "#64748b")
                                    text: "󰅖"
                                    renderType: Text.QtRendering
                                }

                                MouseArea {
                                    id: tCloseMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: toastCardItem.startDismiss()
                                }
                            }
                        }

                        // Title
                        Text {
                            Layout.fillWidth: true
                            font.family: root.sfFontBold
                            font.pixelSize: 16
                            font.bold: true
                            color: Theme.darkMode ? "#ffffff" : "#000000"
                            text: toastCardItem.cardTitle
                            wrapMode: Text.Wrap
                            visible: text !== ""
                            renderType: Text.QtRendering
                        }

                        // Body
                        Text {
                            Layout.fillWidth: true
                            font.family: root.sfFont
                            font.pixelSize: 15
                            lineHeight: 1.18
                            color: Theme.darkMode ? "#cbd5e1" : "#000000"
                            text: toastCardItem.cardBody
                            wrapMode: Text.Wrap
                            maximumLineCount: 12
                            elide: Text.ElideRight
                            visible: text !== ""
                            renderType: Text.QtRendering
                        }
                    }
                }
            }
        }
    }
}