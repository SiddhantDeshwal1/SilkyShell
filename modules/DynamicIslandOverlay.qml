import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

// ─────────────────────────────────────────────────────────────────────────────
// DynamicIslandOverlay — Expanded Dynamic Island Overlay Window.
//
// Features & Motion Architecture:
//   - Liquid Drop Animation: Drops down from the bar like fluid water droplet
//     with squash-and-stretch volume preservation and elastic teardrop spring
//     overshoot ([0.34, 1.56, 0.22, 1.0, 1.0, 1.0]).
//   - Click-Anywhere-to-Close: When expanded, clicking anywhere outside the island
//     closes it immediately. When collapsed, mask is emptyRegion (0x0 input).
//   - Left and Right Mode Switching (󰅁 and 󰅂) with 60fps horizontal slide & spring
//     transition animations and pagination pill indicator.
//   - In-Call Voice Waveform: 7-bar vocal wave visualizer animation and live talk timer.
//   - Zero Emojis: 100% professional Nerd Font glyphs (JetBrainsMono NFP).
//   - Full Text for Notifications: Dynamic height scaling, full text wrapping!
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    readonly property string sfFont: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    // Layer shell positioning
    anchors {
        top: true
        left: true
        right: true
    }

    // Flush right below the 28px top bar, covers desktop so click-outside works anywhere
    WlrLayershell.margins.top: 28
    implicitHeight: Screen.height - 28
    color: "transparent"

    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-dynamic-island"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Active state from singleton
    readonly property bool isOpen: DynamicIslandService.expanded && DynamicIslandService.activeView !== "none"

    visible: root.isOpen || islandShell.height > 1 || islandShell.opacity > 0.01

    // ── Input Region Mask ─────────────────────────────────────────────
    // Full screen when open to capture click-outside anywhere on the screen,
    // and emptyRegion (0x0 input area) when closed so zero input is ever captured.
    mask: root.isOpen ? fullRegion : emptyRegion

    Region {
        id: fullRegion
        x: 0
        y: 0
        width: root.width
        height: root.height
    }

    Region {
        id: emptyRegion
        x: 0
        y: 0
        width: 0
        height: 0
    }

    // ── Backdrop Click-Outside to Close ───────────────────────────────
    MouseArea {
        id: backdropArea
        anchors.fill: parent
        enabled: root.isOpen
        z: 1

        onClicked: function(mouse) {
            const cx = islandShell.x
            const cy = islandShell.y
            const cw = islandShell.width
            const ch = islandShell.height

            // If clicked outside islandShell bounds, dismiss notification or close menu
            if (mouse.x < cx || mouse.x > cx + cw || mouse.y < cy || mouse.y > cy + ch) {
                if (DynamicIslandService.activeView === "notification") {
                    DynamicIslandService.dismissNotification()
                } else {
                    DynamicIslandService.closeIsland()
                }
            }
        }
    }

    // ── Available Modes for Left / Right Navigation ───────────────────
    readonly property var availableModes: {
        const modes = ["device_status", "notification"]
        if (DynamicIslandService.callTimerRunning || DynamicIslandService.activeView === "talking") {
            modes.push("talking")
        } else if (DynamicIslandService.activeView === "call") {
            modes.push("call")
        } else if (DynamicIslandService.missedCallsCount > 0 || DynamicIslandService.activeView === "missed_call") {
            modes.push("missed_call")
        }
        if (DynamicIslandService.timerCountdownActive || DynamicIslandService.activeView === "timer") {
            modes.push("timer")
        }
        if (DynamicIslandService.activeView === "alarm") {
            modes.push("alarm")
        }
        return modes
    }

    property int navDirection: 1 // 1 = right, -1 = left

    function navigateMode(direction) {
        if (availableModes.length <= 1) return
        DynamicIslandService.isManualMenu = true
        root.navDirection = direction
        const curIdx = availableModes.indexOf(DynamicIslandService.activeView)
        const validIdx = curIdx >= 0 ? curIdx : 0
        const nextIdx = (validIdx + direction + availableModes.length) % availableModes.length
        const targetMode = availableModes[nextIdx]

        // Trigger horizontal slide transition animation
        modeSwitchAnim.direction = direction
        modeSwitchAnim.nextView = targetMode
        modeSwitchAnim.start()
    }

    SequentialAnimation {
        id: modeSwitchAnim
        property int direction: 1
        property string nextView: ""

        ParallelAnimation {
            NumberAnimation {
                target: slotWrapper
                property: "x"
                to: -35 * modeSwitchAnim.direction
                duration: 140
                easing.type: Easing.InQuad
            }
            NumberAnimation {
                target: slotWrapper
                property: "opacity"
                to: 0.0
                duration: 120
            }
        }
        ScriptAction {
            script: {
                DynamicIslandService.activeView = modeSwitchAnim.nextView
                slotWrapper.x = 35 * modeSwitchAnim.direction
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: slotWrapper
                property: "x"
                to: 0
                duration: 260
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.34, 1.35, 0.22, 1.0, 1.0, 1.0]
            }
            NumberAnimation {
                target: slotWrapper
                property: "opacity"
                to: 1.0
                duration: 200
            }
        }
    }

    // ── Dynamic Island Shell Container ────────────────────────────────
    Rectangle {
        id: islandShell
        z: 10

        // Position: Centered relative to the bar pill location next to music island
        x: {
            const targetX = DynamicIslandService.pillCenterX - (width / 2)
            const minX = 16
            const maxX = root.width - width - 16
            return Math.max(minX, Math.min(maxX, targetX))
        }

        // Liquid Drop Motion: Droplet drops from -24 down to 8 below bar hairline
        y: root.isOpen ? 8 : -24
        Behavior on y {
            NumberAnimation {
                duration: root.isOpen ? 620 : 580
                easing.type: Easing.BezierSpline
                easing.bezierCurve: root.isOpen
                    ? [0.34, 1.56, 0.22, 1.0, 1.0, 1.0] // Elastic teardrop droplet release
                    : [0.32, 0.0, 0.24, 1.0, 1.0, 1.0]  // Fluid snap retraction into bar
            }
        }

        // Dynamic target geometry per mode (notification expands to show full wrapped text)
        readonly property real targetWidth: {
            switch (DynamicIslandService.activeView) {
                case "call": return 450
                case "talking": return 460
                case "notification": return 480
                case "timer": return 400
                case "alarm": return 410
                case "missed_call": return 450
                case "device_status": return 450
                default: return 140
            }
        }

        readonly property real targetHeight: {
            switch (DynamicIslandService.activeView) {
                case "call": return 106
                case "talking": return 106
                case "notification": return Math.min(260, Math.max(116, notifTextCol.implicitHeight + 46))
                case "timer": return 100
                case "alarm": return 102
                case "missed_call": return 102
                case "device_status": return 102
                default: return 0
            }
        }

        // Direct Spring Animation on Width & Height
        width: root.isOpen ? targetWidth : 140
        height: root.isOpen ? targetHeight : 0

        Behavior on width {
            NumberAnimation {
                duration: root.isOpen ? 600 : 560
                easing.type: Easing.BezierSpline
                easing.bezierCurve: root.isOpen
                    ? [0.34, 1.35, 0.22, 1.0, 1.0, 1.0]
                    : [0.32, 0.0, 0.24, 1.0, 1.0, 1.0]
            }
        }

        Behavior on height {
            NumberAnimation {
                duration: root.isOpen ? 580 : 540
                easing.type: Easing.BezierSpline
                easing.bezierCurve: root.isOpen
                    ? [0.34, 1.45, 0.22, 1.0, 1.0, 1.0]
                    : [0.32, 0.0, 0.24, 1.0, 1.0, 1.0]
            }
        }

        radius: 36
        color: "#000000" // Pure solid OLED pitch black — zero border
        border.width: 0
        border.color: "transparent"
        clip: true

        opacity: root.isOpen ? 1.0 : 0.0
        Behavior on opacity {
            NumberAnimation { duration: root.isOpen ? 340 : 440; easing.type: Easing.OutQuad }
        }

        // Liquid Teardrop Squash & Stretch Physics
        transformOrigin: Item.Top
        transform: [
            Scale {
                id: liquidSquash
                origin.x: islandShell.width / 2
                origin.y: 0
                xScale: root.isOpen ? 1.0 : 0.88
                yScale: root.isOpen ? 1.0 : 0.60

                Behavior on xScale {
                    NumberAnimation {
                        duration: root.isOpen ? 620 : 560
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: root.isOpen
                            ? [0.34, 1.40, 0.22, 1.0, 1.0, 1.0]
                            : [0.32, 0.0, 0.24, 1.0, 1.0, 1.0]
                    }
                }
                Behavior on yScale {
                    NumberAnimation {
                        duration: root.isOpen ? 600 : 560
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: root.isOpen
                            ? [0.34, 1.62, 0.22, 1.0, 1.0, 1.0] // Teardrop elongation bounce
                            : [0.32, 0.0, 0.24, 1.0, 1.0, 1.0]
                    }
                }
            }
        ]

        // ── Navigation Buttons: Left & Right (󰅁 and 󰅂) ─────────────────
        readonly property bool showNav: root.availableModes.length > 1 && islandShell.height > 50

        // Left Navigation Chevron Button
        Rectangle {
            id: leftNavBtn
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 26
            height: 26
            radius: 13
            color: leftNavMouse.containsMouse ? "#30ffffff" : "#12ffffff"
            visible: islandShell.showNav
            z: 20

            scale: leftNavMouse.pressed ? 0.85 : (leftNavMouse.containsMouse ? 1.15 : 1.0)
            Behavior on scale { NumberAnimation { duration: 120 } }
            Behavior on color { ColorAnimation { duration: 140 } }

            Text {
                anchors.centerIn: parent
                font.family: root.iconFont
                font.pixelSize: 13
                color: "#ffffff"
                text: "󰅁" // Chevron left
            }

            MouseArea {
                id: leftNavMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.navigateMode(-1)
                }
            }
        }

        // Right Navigation Chevron Button
        Rectangle {
            id: rightNavBtn
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 26
            height: 26
            radius: 13
            color: rightNavMouse.containsMouse ? "#30ffffff" : "#12ffffff"
            visible: islandShell.showNav
            z: 20

            scale: rightNavMouse.pressed ? 0.85 : (rightNavMouse.containsMouse ? 1.15 : 1.0)
            Behavior on scale { NumberAnimation { duration: 120 } }
            Behavior on color { ColorAnimation { duration: 140 } }

            Text {
                anchors.centerIn: parent
                font.family: root.iconFont
                font.pixelSize: 13
                color: "#ffffff"
                text: "󰅂" // Chevron right
            }

            MouseArea {
                id: rightNavMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.navigateMode(1)
                }
            }
        }

        // ── Mode Indicator Dots at Bottom ─────────────────────────────
        Row {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 7
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 5
            visible: islandShell.showNav
            z: 20

            Repeater {
                model: root.availableModes

                Rectangle {
                    readonly property bool isCurrent: modelData === DynamicIslandService.activeView
                    width: isCurrent ? 14 : 5
                    height: 5
                    radius: 2.5
                    color: isCurrent ? "#38bdf8" : "#30ffffff"

                    Behavior on width { NumberAnimation { duration: 200 } }
                    Behavior on color { ColorAnimation { duration: 180 } }
                }
            }
        }

        // ── Slot Content Wrapper ──────────────────────────────────────
        Item {
            id: slotWrapper
            anchors.fill: parent
            anchors.leftMargin: islandShell.showNav ? 34 : 20
            anchors.rightMargin: islandShell.showNav ? 34 : 20
            anchors.topMargin: 12
            anchors.bottomMargin: islandShell.showNav ? 18 : 12
            visible: islandShell.height > 30

            // ═════════════════════════════════════════════════════════════
            // VIEW 1: INCOMING CALL (id="call")
            // ═════════════════════════════════════════════════════════════
            RowLayout {
                anchors.fill: parent
                spacing: 16
                visible: DynamicIslandService.activeView === "call"

                // Caller info
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 3

                    Row {
                        spacing: 6
                        Text {
                            font.family: root.iconFont
                            font.pixelSize: 12
                            color: "#10b981"
                            text: "󰏲" // Phone icon
                        }
                        Text {
                            font.family: root.sfFont
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 1.0
                            color: "#99ffffff"
                            text: "INCOMING CALL"
                            renderType: Text.NativeRendering
                        }
                    }

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 22
                        font.weight: Font.Bold
                        color: "#ffffff"
                        text: DynamicIslandService.callerName
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        renderType: Text.NativeRendering
                    }

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 13
                        color: "#88ffffff"
                        text: DynamicIslandService.callerNumber || "Mobile Voice Call"
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        renderType: Text.NativeRendering
                    }
                }

                // Call Action Buttons (Right: Decline + Accept)
                Row {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 12

                    // Decline button (Red)
                    Rectangle {
                        width: 46
                        height: 46
                        radius: 23
                        color: declineMouse.containsMouse ? "#dc2626" : "#ef4444"

                        scale: declineMouse.pressed ? 0.90 : (declineMouse.containsMouse ? 1.06 : 1.0)
                        Behavior on scale { NumberAnimation { duration: 120 } }
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 19
                            color: "#ffffff"
                            text: "󰅖" // Cross / Decline
                        }

                        MouseArea {
                            id: declineMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                DynamicIslandService.rejectCall()
                            }
                        }
                    }

                    // Accept button (Emerald Green)
                    Rectangle {
                        width: 46
                        height: 46
                        radius: 23
                        color: acceptMouse.containsMouse ? "#059669" : "#10b981"

                        scale: acceptMouse.pressed ? 0.90 : (acceptMouse.containsMouse ? 1.06 : 1.0)
                        Behavior on scale { NumberAnimation { duration: 120 } }
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 19
                            color: "#ffffff"
                            text: "󰏲" // Phone / Answer
                        }

                        MouseArea {
                            id: acceptMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                DynamicIslandService.attendCall()
                            }
                        }
                    }
                }
            }

            // ═════════════════════════════════════════════════════════════
            // VIEW 2: TALKING / IN-CALL MODE (id="talking")
            // Features: 7-bar vocal wave visualizer animation + live talk duration
            // ═════════════════════════════════════════════════════════════
            RowLayout {
                anchors.fill: parent
                spacing: 14
                visible: DynamicIslandService.activeView === "talking"

                // Contact & Live Duration
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 3

                    Row {
                        spacing: 8
                        Text {
                            font.family: root.iconFont
                            font.pixelSize: 12
                            color: "#10b981"
                            text: "󰏲"
                        }

                        Text {
                            font.family: root.sfFont
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 1.0
                            color: "#99ffffff"
                            text: "CALL IN PROGRESS"
                            renderType: Text.NativeRendering
                        }

                        Text {
                            font.family: root.sfFont
                            font.pixelSize: 12
                            font.weight: Font.Bold
                            color: "#10b981"
                            text: "• " + DynamicIslandService.formatClock(DynamicIslandService.callDuration)
                            renderType: Text.NativeRendering
                        }
                    }

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: "#ffffff"
                        text: DynamicIslandService.callerName
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        renderType: Text.NativeRendering
                    }
                }

                // 7-Bar Animated Vocal Waveform Visualizer
                Row {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 3.5
                    height: 28

                    Repeater {
                        model: [
                            { minH: 6, maxH: 22, dur1: 280, dur2: 340, delay: 0 },
                            { minH: 8, maxH: 28, dur1: 220, dur2: 300, delay: 90 },
                            { minH: 10, maxH: 34, dur1: 260, dur2: 240, delay: 150 },
                            { minH: 12, maxH: 38, dur1: 190, dur2: 280, delay: 60 },
                            { minH: 10, maxH: 32, dur1: 250, dur2: 310, delay: 180 },
                            { minH: 8, maxH: 26, dur1: 230, dur2: 270, delay: 120 },
                            { minH: 6, maxH: 20, dur1: 300, dur2: 250, delay: 40 }
                        ]

                        Rectangle {
                            id: barItem
                            width: 3.5
                            height: modelData.minH
                            radius: 1.75
                            color: "#10b981"
                            anchors.verticalCenter: parent.verticalCenter

                            SequentialAnimation on height {
                                loops: Animation.Infinite
                                running: DynamicIslandService.activeView === "talking"
                                PauseAnimation { duration: modelData.delay }
                                NumberAnimation { from: modelData.minH; to: modelData.maxH; duration: modelData.dur1; easing.type: Easing.InOutQuad }
                                NumberAnimation { from: modelData.maxH; to: modelData.minH + 4; duration: modelData.dur2; easing.type: Easing.InOutQuad }
                                NumberAnimation { from: modelData.minH + 4; to: modelData.maxH * 0.75; duration: 200; easing.type: Easing.InOutQuad }
                                NumberAnimation { from: modelData.maxH * 0.75; to: modelData.minH; duration: 240; easing.type: Easing.InOutQuad }
                            }
                        }
                    }
                }

                // Hang up / End call button (Red)
                Rectangle {
                    width: 44
                    height: 44
                    radius: 22
                    color: endMouse.containsMouse ? "#dc2626" : "#ef4444"
                    Layout.alignment: Qt.AlignVCenter

                    scale: endMouse.pressed ? 0.90 : (endMouse.containsMouse ? 1.06 : 1.0)
                    Behavior on scale { NumberAnimation { duration: 120 } }
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 18
                        color: "#ffffff"
                        text: "󰅖" // PhoneOff icon
                    }

                    MouseArea {
                        id: endMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            DynamicIslandService.endCall()
                        }
                    }
                }
            }

            // ═════════════════════════════════════════════════════════════
            // VIEW 3: MOBILE NOTIFICATION (id="notification")
            // Features: FULL wrapped text display + dynamic card height
            // ═════════════════════════════════════════════════════════════
            RowLayout {
                anchors.fill: parent
                spacing: 14
                visible: DynamicIslandService.activeView === "notification"

                // App Icon badge
                Rectangle {
                    width: 44
                    height: 44
                    radius: 14
                    color: {
                        const app = (DynamicIslandService.notifApp || "").toLowerCase()
                        if (app.includes("whatsapp")) return "#25d366"
                        if (app.includes("telegram")) return "#229ed9"
                        if (app.includes("message") || app.includes("sms")) return "#3b82f6"
                        if (app.includes("instagram")) return "#e1306c"
                        if (app.includes("linkedin")) return "#0a66c2"
                        return "#6366f1"
                    }
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 22
                        color: "#ffffff"
                        text: {
                            const app = (DynamicIslandService.notifApp || "").toLowerCase()
                            if (app.includes("whatsapp")) return "󰖣"
                            if (app.includes("telegram")) return "󰈙"
                            if (app.includes("message") || app.includes("sms")) return "󰍡"
                            if (app.includes("mail") || app.includes("outlook")) return "󰇮"
                            if (app.includes("linkedin")) return "󰌻"
                            if (app.includes("phone")) return "󰏲"
                            return "󰂚"
                        }
                    }
                }

                // Full text container (Header, Title, Body — NO ELISION)
                ColumnLayout {
                    id: notifTextCol
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 4

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.0
                        color: "#99ffffff"
                        text: DynamicIslandService.notifApp || "Notification"
                        renderType: Text.NativeRendering
                    }

                    // Full Title without truncation
                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 17
                        font.weight: Font.Bold
                        color: "#ffffff"
                        text: DynamicIslandService.notifTitle || "New Message"
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                        renderType: Text.NativeRendering
                    }

                    // Full Body Message without truncation
                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 13
                        color: "#d4ffffff"
                        lineHeight: 1.25
                        text: DynamicIslandService.notifBody
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                        visible: DynamicIslandService.notifBody !== ""
                        renderType: Text.NativeRendering
                    }
                }

                // Dismiss button
                Rectangle {
                    width: 34
                    height: 34
                    radius: 17
                    color: notifDismissMouse.containsMouse ? "#40ffffff" : "#22ffffff"
                    Layout.alignment: Qt.AlignVCenter

                    scale: notifDismissMouse.pressed ? 0.90 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120 } }
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 14
                        color: "#ffffff"
                        text: "󰅖"
                    }

                    MouseArea {
                        id: notifDismissMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            DynamicIslandService.dismissNotification()
                        }
                    }
                }
            }

            // ═════════════════════════════════════════════════════════════
            // VIEW 4: TIMER (id="timer")
            // ═════════════════════════════════════════════════════════════
            RowLayout {
                anchors.fill: parent
                spacing: 16
                visible: DynamicIslandService.activeView === "timer"

                // Timer Icon (Orange)
                Rectangle {
                    width: 44
                    height: 44
                    radius: 22
                    color: "#2bf97316"
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 22
                        color: "#f97316"
                        text: "󱎫" // Timer icon
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 3

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.0
                        color: "#99ffffff"
                        text: DynamicIslandService.timerTitle || "TIMER"
                        renderType: Text.NativeRendering
                    }

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 22
                        font.weight: Font.Bold
                        color: "#ffffff"
                        text: DynamicIslandService.formatClock(DynamicIslandService.timerSeconds)
                        renderType: Text.NativeRendering
                    }
                }

                // Stop / Dismiss button
                Rectangle {
                    width: 36
                    height: 36
                    radius: 18
                    color: timerDismissMouse.containsMouse ? "#f97316" : "#2bf97316"
                    Layout.alignment: Qt.AlignVCenter

                    scale: timerDismissMouse.pressed ? 0.90 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120 } }
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 15
                        color: "#ffffff"
                        text: "󰅖"
                    }

                    MouseArea {
                        id: timerDismissMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            DynamicIslandService.dismissTimer()
                        }
                    }
                }
            }

            // ═════════════════════════════════════════════════════════════
            // VIEW 5: ALARM (id="alarm")
            // ═════════════════════════════════════════════════════════════
            RowLayout {
                anchors.fill: parent
                spacing: 16
                visible: DynamicIslandService.activeView === "alarm"

                // Alarm Icon (Amber / Yellow)
                Rectangle {
                    width: 44
                    height: 44
                    radius: 22
                    color: "#2beab308"
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 22
                        color: "#eab308"
                        text: "󰂞"
                    }

                    SequentialAnimation on rotation {
                        loops: Animation.Infinite
                        running: DynamicIslandService.activeView === "alarm"
                        NumberAnimation { from: -14; to: 14; duration: 120; easing.type: Easing.InOutQuad }
                        NumberAnimation { from: 14; to: -14; duration: 120; easing.type: Easing.InOutQuad }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 3

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.0
                        color: "#99ffffff"
                        text: "ALARM"
                        renderType: Text.NativeRendering
                    }

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: "#ffffff"
                        text: DynamicIslandService.alarmTitle || "Alarm Ringing"
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        renderType: Text.NativeRendering
                    }
                }

                // Dismiss button
                Rectangle {
                    width: 36
                    height: 36
                    radius: 18
                    color: alarmDismissMouse.containsMouse ? "#ef4444" : "#2bef4444"
                    Layout.alignment: Qt.AlignVCenter

                    scale: alarmDismissMouse.pressed ? 0.90 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120 } }
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 15
                        color: "#ffffff"
                        text: "󰅖"
                    }

                    MouseArea {
                        id: alarmDismissMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            DynamicIslandService.dismissAlarm()
                        }
                    }
                }
            }

            // ═════════════════════════════════════════════════════════════
            // VIEW 6: MISSED CALL (id="missed_call")
            // ═════════════════════════════════════════════════════════════
            RowLayout {
                anchors.fill: parent
                spacing: 16
                visible: DynamicIslandService.activeView === "missed_call"

                Rectangle {
                    width: 44
                    height: 44
                    radius: 22
                    color: "#2bef4444"
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 21
                        color: "#ef4444"
                        text: "󰏳" // Missed call icon
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 3

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.0
                        color: "#ef4444"
                        text: "MISSED CALL"
                        renderType: Text.NativeRendering
                    }

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: "#ffffff"
                        text: DynamicIslandService.lastMissedCaller || "Unknown Caller"
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        renderType: Text.NativeRendering
                    }
                }

                // Clear button
                Rectangle {
                    width: 36
                    height: 36
                    radius: 18
                    color: missedClearMouse.containsMouse ? "#ef4444" : "#25ffffff"
                    Layout.alignment: Qt.AlignVCenter

                    scale: missedClearMouse.pressed ? 0.90 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120 } }
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 15
                        color: "#ffffff"
                        text: "󰅖"
                    }

                    MouseArea {
                        id: missedClearMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            DynamicIslandService.clearMissedCalls()
                        }
                    }
                }
            }

            // ═════════════════════════════════════════════════════════════
            // VIEW 7: PHONE DEVICE STATUS (id="device_status")
            // ═════════════════════════════════════════════════════════════
            RowLayout {
                anchors.fill: parent
                spacing: 16
                visible: DynamicIslandService.activeView === "device_status"

                Rectangle {
                    width: 44
                    height: 44
                    radius: 22
                    color: "#2b10b981"
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 22
                        color: "#10b981"
                        text: "󰄡" // Phone mobile icon
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 3

                    Text {
                        font.family: root.sfFont
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.0
                        color: "#99ffffff"
                        text: "CONNECTED PHONE"
                        renderType: Text.NativeRendering
                    }

                    Row {
                        spacing: 8
                        Text {
                            font.family: root.sfFont
                            font.pixelSize: 19
                            font.weight: Font.Bold
                            color: "#ffffff"
                            text: DynamicIslandService.phoneName
                            renderType: Text.NativeRendering
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            font.family: root.sfFont
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                            color: "#10b981"
                            text: "• " + DynamicIslandService.phoneBattery + "%" + (DynamicIslandService.phoneCharging ? " 󰂄 Charging" : "")
                            renderType: Text.NativeRendering
                        }
                    }
                }

                // Close button
                Rectangle {
                    width: 36
                    height: 36
                    radius: 18
                    color: statusCloseMouse.containsMouse ? "#40ffffff" : "#22ffffff"
                    Layout.alignment: Qt.AlignVCenter

                    scale: statusCloseMouse.pressed ? 0.90 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120 } }
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 15
                        color: "#ffffff"
                        text: "󰅖"
                    }

                    MouseArea {
                        id: statusCloseMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            DynamicIslandService.dismissDeviceStatus()
                        }
                    }
                }
            }
        }
    }
}
