import QtQuick
import QtQuick.Layouts
import Quickshell

// ─────────────────────────────────────────────────────────────────────────────
// DynamicIslandBar — Compact pill in the top bar.
//
// Positioned directly to the right of MediaIsland.
//
// FEATURES & 60FPS LIQUID MOTION:
//   - Collapses and hides when the island is expanded below the bar, so the bar
//     does not show the island while expanded. Springs back when collapsed!
//   - Zero emojis — 100% professional Nerd Font glyphs (JetBrainsMono NFP).
//   - Pure deep OLED black pill (#000000) with zero border artifacts (border.width: 0).
//   - Ambient Slideshow (every 4.5s) rotating between:
//       1. Phone battery & status (󰄡 Galaxy A35 • 61% 󰂄) with emerald dot
//       2. Notifications count (󰂚 17 Notifs) with sky blue dot
//       3. Missed calls if any (󰏳 Missed: Saurabh) with coral red dot
//       4. Focus Mode if active (󰤄 Focus Mode) with purple dot
//   - 60fps liquid vertical roll & fade transition + fluid spring width morphing.
//   - Priority State Lock: When an active call, talking session, timer, or alarm
//     is live, immediately locks onto priority mode with live talk duration.
//   - Clicking triggers the liquid drop expansion below the bar.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    readonly property string sfFont: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    // ── Priority State Detection ──────────────────────────────────────
    readonly property bool isTalking: DynamicIslandService.activeView === "talking"
    readonly property bool isCallRinging: DynamicIslandService.activeView === "call"
    readonly property bool isTimer: DynamicIslandService.activeView === "timer"
    readonly property bool isAlarm: DynamicIslandService.activeView === "alarm"
    readonly property bool isPriority: isTalking || isCallRinging || isTimer || isAlarm

    // Priority display properties (strictly professional Nerd Font icons)
    readonly property string priorityIcon: {
        if (root.isTalking) return "󰏲"
        if (root.isCallRinging) return "󰏲"
        if (root.isTimer) return "󱎫"
        if (root.isAlarm) return "󰂞"
        return "󰄡"
    }

    readonly property string priorityText: {
        if (root.isTalking) {
            return DynamicIslandService.callerName + " • " + DynamicIslandService.formatClock(DynamicIslandService.callDuration)
        } else if (root.isCallRinging) {
            return "Incoming: " + DynamicIslandService.callerName
        } else if (root.isTimer) {
            return DynamicIslandService.timerTitle + " " + DynamicIslandService.formatClock(DynamicIslandService.timerSeconds)
        } else if (root.isAlarm) {
            return DynamicIslandService.alarmTitle || "Alarm"
        }
        return ""
    }

    readonly property color priorityColor: {
        if (root.isTalking) return "#10b981"
        if (root.isCallRinging) return "#10b981"
        if (root.isTimer) return "#f97316"
        if (root.isAlarm) return "#eab308"
        return "#10b981"
    }

    // ── Ambient Slideshow Definition (Professional Nerd Fonts) ────────
    readonly property var ambientSlides: {
        const list = []

        // 1. Phone battery & status (Always present)
        const chargingIcon = DynamicIslandService.phoneCharging ? " 󰂄" : ""
        list.push({
            id: "battery",
            icon: "󰄡",
            text: DynamicIslandService.phoneName + " • " + DynamicIslandService.phoneBattery + "%" + chargingIcon,
            color: "#10b981",
            dotPulse: DynamicIslandService.phoneCharging
        })

        // 2. Notifications count (Always present)
        const count = DynamicIslandService.notificationsCount
        const notifTxt = count > 0 ? (count + " " + (count === 1 ? "Notification" : "Notifications")) : "No Notifications"
        list.push({
            id: "notifications",
            icon: "󰂚",
            text: notifTxt,
            color: "#38bdf8",
            dotPulse: false
        })

        // 3. Missed call (Only if missed calls exist)
        if (DynamicIslandService.missedCallsCount > 0) {
            const caller = DynamicIslandService.lastMissedCaller ? ("Missed: " + DynamicIslandService.lastMissedCaller) : (DynamicIslandService.missedCallsCount + " Missed")
            list.push({
                id: "missed_call",
                icon: "󰏳",
                text: caller,
                color: "#ef4444",
                dotPulse: true
            })
        }

        // 4. Focus Mode (Only if Focus Mode / DND is active)
        if (DynamicIslandService.focusMode) {
            list.push({
                id: "focus",
                icon: "󰤄",
                text: "Focus Mode",
                color: "#a855f7",
                dotPulse: false
            })
        }

        return list
    }

    property int currentSlideIndex: 0

    readonly property var activeSlide: {
        if (ambientSlides.length === 0) {
            return { id: "battery", icon: "󰄡", text: "Phone", color: "#10b981", dotPulse: false }
        }
        const idx = currentSlideIndex % ambientSlides.length
        return ambientSlides[idx]
    }

    // Dynamic resolution of displayed content
    readonly property string displayIcon: root.isPriority ? priorityIcon : activeSlide.icon
    readonly property string displayText: root.isPriority ? priorityText : activeSlide.text
    readonly property color displayColor: root.isPriority ? priorityColor : activeSlide.color

    // ── Slideshow Timer & Liquid Transition ───────────────────────────
    Timer {
        id: slideshowTimer
        interval: 4500
        running: !root.isPriority && !DynamicIslandService.expanded
        repeat: true
        onTriggered: {
            if (root.ambientSlides.length > 1) {
                root.advanceSlide()
            }
        }
    }

    function advanceSlide() {
        if (transitionAnim.running) return
        transitionAnim.start()
    }

    // 60fps vertical roll & cross-fade liquid transition
    SequentialAnimation {
        id: transitionAnim
        ParallelAnimation {
            NumberAnimation {
                target: slideContent
                property: "anchors.verticalCenterOffset"
                to: -9
                duration: 160
                easing.type: Easing.InQuad
            }
            NumberAnimation {
                target: slideContent
                property: "opacity"
                to: 0.0
                duration: 140
            }
        }
        ScriptAction {
            script: {
                root.currentSlideIndex = (root.currentSlideIndex + 1) % Math.max(1, root.ambientSlides.length)
                slideContent.anchors.verticalCenterOffset = 9
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: slideContent
                property: "anchors.verticalCenterOffset"
                to: 0
                duration: 260
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.38, 1.21, 0.22, 1, 1, 1]
            }
            NumberAnimation {
                target: slideContent
                property: "opacity"
                to: 1.0
                duration: 200
            }
        }
    }

    // ── Bar Geometry & Spring Width ───────────────────────────────────
    implicitHeight: 26
    Layout.preferredHeight: 26
    Layout.alignment: Qt.AlignVCenter

    // Liquid spring width animation:
    // When expanded, collapses to 0 so the bar does not show the island while expanded!
    // When collapsed, springs to content width + 24px padding.
    readonly property real targetWidth: DynamicIslandService.expanded ? 0 : (pillContent.implicitWidth + 24)
    implicitWidth: targetWidth
    Layout.preferredWidth: root.implicitWidth

    Behavior on implicitWidth {
        NumberAnimation {
            duration: DynamicIslandService.expanded ? 460 : 600
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.38, 1.21, 0.22, 1, 1, 1] // expressiveDefaultSpatial spring
        }
    }

    clip: true
    visible: implicitWidth > 1 || !DynamicIslandService.expanded

    // Export screen coordinates to DynamicIslandService so expanded overlay aligns seamlessly
    function updateCoordinates() {
        if (root.visible && root.width > 0) {
            const p = root.mapToItem(null, 0, 0)
            if (p && !isNaN(p.x)) {
                DynamicIslandService.barPillX = p.x
                DynamicIslandService.barPillWidth = Math.max(120, root.width)
            }
        }
    }

    onXChanged: updateCoordinates()
    onWidthChanged: updateCoordinates()
    Component.onCompleted: updateCoordinates()

    // ── Pill Container ────────────────────────────────────────────────
    Rectangle {
        id: pillRect
        anchors.fill: parent
        radius: 13
        color: "#000000" // Pure solid OLED black — zero border artifacts
        border.width: 0
        border.color: "transparent"

        // Disappears cleanly when island expands below the bar
        opacity: DynamicIslandService.expanded ? 0.0 : 1.0
        Behavior on opacity {
            NumberAnimation { duration: DynamicIslandService.expanded ? 320 : 420; easing.type: Easing.OutQuad }
        }

        scale: mouseArea.pressed ? 0.95 : (mouseArea.containsMouse ? 1.02 : 1.0)
        Behavior on scale {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }

        // Pill Content Row
        Row {
            id: pillContent
            anchors.centerIn: parent
            spacing: 7

            // Indicator dot with smooth 60fps color morphing and breathing pulse
            Item {
                width: 7
                height: 7
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    id: dot
                    anchors.centerIn: parent
                    width: 7
                    height: 7
                    radius: 3.5
                    color: root.displayColor

                    Behavior on color {
                        ColorAnimation { duration: 350; easing.type: Easing.InOutQuad }
                    }

                    // Pulsing breath animation on active call or charging/missed call
                    SequentialAnimation on scale {
                        running: (root.isPriority && root.isTalking) || (!root.isPriority && root.activeSlide.dotPulse)
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 1.45; duration: 800; easing.type: Easing.InOutQuad }
                        NumberAnimation { from: 1.45; to: 1.0; duration: 800; easing.type: Easing.InOutQuad }
                    }
                }
            }

            // Animated Text Content
            Item {
                id: textWrapper
                anchors.verticalCenter: parent.verticalCenter
                width: slideContent.implicitWidth
                height: 20
                clip: true

                Row {
                    id: slideContent
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 7

                    // Nerd Font Icon Glyph — Much Bigger (20px)
                    Text {
                        id: iconItem
                        anchors.verticalCenter: parent.verticalCenter
                        font.family: root.iconFont
                        font.pixelSize: 20
                        color: root.displayColor
                        text: root.displayIcon
                        renderType: Text.NativeRendering

                        Behavior on color {
                            ColorAnimation { duration: 350; easing.type: Easing.InOutQuad }
                        }
                    }

                    // Text Label in SF Pro Rounded
                    Text {
                        id: labelItem
                        anchors.verticalCenter: parent.verticalCenter
                        font.family: root.sfFont
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: "#ffffff"
                        renderType: Text.NativeRendering
                        text: root.displayText
                    }
                }
            }
        }

        // ── Click Interactions: Expand into liquid droplet below bar ──────
        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                DynamicIslandService.isManualMenu = true
                if (root.isPriority) {
                    DynamicIslandService.toggleExpand()
                } else {
                    const currentId = root.activeSlide.id
                    if (currentId === "battery") {
                        DynamicIslandService.activeView = "device_status"
                        DynamicIslandService.expanded = true
                    } else if (currentId === "missed_call") {
                        DynamicIslandService.activeView = "missed_call"
                        DynamicIslandService.expanded = true
                    } else if (currentId === "notifications") {
                        DynamicIslandService.activeView = "notification"
                        DynamicIslandService.expanded = true
                    } else if (currentId === "focus") {
                        DynamicIslandService.activeView = "device_status"
                        DynamicIslandService.expanded = true
                    }
                }
            }
        }
    }
}
