import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// PowerModeWidget — macOS / iOS Style APU Power Capsule (182x70, radius 35).
// Modes:
//   - Battery Saver (10W / 100°C | powersave | scx_lavd)
//   - Balanced      (15W / 100°C | schedutil | scx_rusty)
//   - Boost         (25W / 100°C | performance | scx_bpfland)
//   - Performance   (30W / 100°C | performance | scx_bpfland)
//   - Peak          (35W / 100°C | performance | scx_bpfland)
// Features:
//   - Only displays active Icon, Mode name, and Wattage (Succinct & clean).
//   - Left-click cycles through modes in cyclic order with buttery-smooth 60fps animations.
//   - 0.9s (900ms) debounce timer: mode is only triggered in backend if stopped > 0.9s.
//   - GPU-accelerated liquid animated progress bar visualizes the 0.9s countdown.
//   - High-tech vector Nerd Font icons (No emojis).
//   - Font size aligned to other Control Center pills (16px title / 13px wattage).
//   - Right-click or Chevron button opens the full Sub-Menu.
// ─────────────────────────────────────────────────────────────────────────────

LiquidGlassCard {
    id: root

    cardRadius: 35
    implicitWidth: 182
    implicitHeight: 70

    signal clicked()
    signal modeChanged(string newMode)

    isHovered: cardMouse.containsMouse || chevMouse.containsMouse || iconBadgeMouse.containsMouse
    isPressed: cardMouse.pressed || iconBadgeMouse.pressed

    readonly property string sfFont: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    // ── Active Power Mode State ───────────────────────────────────────
    // ── External Bound Mode ──────────────────────────────────────────
    property string activeMode: "balanced"
    property string currentMode: activeMode
    property string modeName: "Balanced"
    property string shortName: "Bal"
    property string wattage: "15W"
    property string temp: "100°C"
    property string iconStr: "󰞬"
    property color  modeColor: "#0ea5e9"
    property int    levelIndex: 1 // 0: Eco, 1: Bal, 2: Boost, 3: Perf, 4: Peak
    property bool   pendingCommit: debounceTimer.running || committingGuardTimer.running

    isActive: false
    idleColor: Theme.cardIdleColor
    activeColor: {
        switch (currentMode) {
            case "peak":         return Qt.rgba(0.96, 0.25, 0.38, 0.28);
            case "performance":  return Qt.rgba(0.98, 0.45, 0.09, 0.26);
            case "boost":        return Qt.rgba(0.66, 0.33, 0.97, 0.26);
            case "balanced":     return Qt.rgba(0.06, 0.65, 0.91, 0.26);
            case "batterysaver": return Qt.rgba(0.06, 0.72, 0.51, 0.26);
            default:             return Qt.rgba(0.06, 0.65, 0.91, 0.26);
        }
    }
    activeBorderColor: Qt.rgba(modeColor.r, modeColor.g, modeColor.b, 0.65)
    activeRimColor: Qt.rgba(modeColor.r, modeColor.g, modeColor.b, 0.35)

    // ── Cyclic Modes Definition (High-Tech Vector Glyphs) ─────────────
    readonly property var modeList: [
        { key: "batterysaver", name: "Battery Saver", short: "Eco",   watt: "10W", temp: "100°C", icon: "󰌪", col: "#10b981", idx: 0 },
        { key: "balanced",     name: "Balanced",      short: "Bal",   watt: "15W", temp: "100°C", icon: "󰞬", col: "#0ea5e9", idx: 1 },
        { key: "boost",        name: "Boost",         short: "Boost", watt: "25W", temp: "100°C", icon: "󰌠", col: "#a855f7", idx: 2 },
        { key: "performance",  name: "Performance",   short: "Perf",  watt: "30W", temp: "100°C", icon: "󰈸", col: "#f97316", idx: 3 },
        { key: "peak",         name: "Peak",          short: "Peak",  watt: "35W", temp: "100°C", icon: "󰓅", col: "#f43f5e", idx: 4 }
    ]

    onActiveModeChanged: {
        if (!debounceTimer.running && !committingGuardTimer.running) {
            applyLocalMode(activeMode)
        }
    }

    // ── Local Mode Transition (Instant 60fps Visual Feedback) ─────────
    function applyLocalMode(mKey) {
        let found = null
        for (let i = 0; i < modeList.length; i++) {
            if (modeList[i].key === mKey) {
                found = modeList[i]
                break
            }
        }
        if (!found) return

        if (root.currentMode !== found.key || root.iconStr !== found.icon) {
            root.currentMode = found.key
            root.modeName = found.name
            root.shortName = found.short
            root.wattage = found.watt
            root.temp = found.temp
            root.iconStr = found.icon
            root.modeColor = found.col
            root.levelIndex = found.idx

            iconPulseAnim.restart()
            textSlideAnim.restart()
        }
    }

    // ── Cyclic Left-Click Trigger ─────────────────────────────────────
    function cycleNext() {
        const nextIdx = (root.levelIndex + 1) % modeList.length
        applyLocalMode(modeList[nextIdx].key)
        committingGuardTimer.stop()
        debounceTimer.restart()
    }

    // ── 0.9s (900ms) Debounce Timer Before Triggering Backend ────────
    Timer {
        id: debounceTimer
        interval: 900
        repeat: false
        onTriggered: {
            root.commitModeToBackend(root.currentMode)
        }
    }

    // Guard timer protecting against stale disk reads during backend execution
    Timer {
        id: committingGuardTimer
        interval: 2500
        repeat: false
        onTriggered: {
            if (root.activeMode && root.activeMode !== root.currentMode) {
                root.applyLocalMode(root.activeMode)
            }
        }
    }

    function commitModeToBackend(modeKey) {
        committingGuardTimer.restart()
        commitFlashAnim.restart()
        root.modeChanged(modeKey)
    }

    Component.onCompleted: {
        applyLocalMode(activeMode)
    }

    // ── Main Layout: Icon + Mode Title & Wattage + Submenu Chevron ────
    RowLayout {
        z: 1
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 12
        anchors.topMargin: 8
        anchors.bottomMargin: 8
        spacing: 10

        // 1. High-Tech Vector Icon Badge (44x44)
        Rectangle {
            id: iconBadge
            z: 10
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 44
            Layout.preferredHeight: 44
            radius: 22
            color: iconBadgeMouse.containsMouse
                ? Qt.rgba(root.modeColor.r, root.modeColor.g, root.modeColor.b, 0.35)
                : Qt.rgba(root.modeColor.r, root.modeColor.g, root.modeColor.b, 0.22)
            border.color: Qt.rgba(root.modeColor.r, root.modeColor.g, root.modeColor.b, 0.55)
            border.width: 1.2
            scale: iconBadgeMouse.pressed ? 0.92 : 1.0

            Behavior on color { ColorAnimation { duration: 240; easing.type: Easing.OutCubic } }
            Behavior on border.color { ColorAnimation { duration: 240; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }

            // 60fps Native GPU Scale Pulse Animation
            SequentialAnimation {
                id: iconPulseAnim
                NumberAnimation { target: glyphText; property: "scale"; to: 1.25; duration: 110; easing.type: Easing.OutCubic }
                NumberAnimation { target: glyphText; property: "scale"; to: 1.0; duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
            }

            Text {
                id: glyphText
                anchors.centerIn: parent
                text: root.iconStr
                font.family: root.iconFont
                font.pixelSize: 22
                color: root.modeColor
                renderType: Text.QtRendering

                Behavior on color { ColorAnimation { duration: 240; easing.type: Easing.OutCubic } }
            }

            MouseArea {
                id: iconBadgeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.clicked()
            }
        }

        // 2. Mode Title and Wattage Column (SF Pro Rounded Typography - 16px / 13px)
        ColumnLayout {
            id: textCol
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 2
            layer.enabled: true

            transform: Translate {
                id: textSlideTrans
                y: 0
            }

            NumberAnimation {
                id: textSlideAnim
                target: textSlideTrans
                property: "y"
                from: 4
                to: 0
                duration: 180
                easing.type: Easing.OutCubic
            }

            // Mode Title (16px bold matching Wi-Fi, Bluetooth)
            Text {
                text: root.modeName
                font.family: root.sfFont
                font.pixelSize: 16
                font.bold: true
                color: "#ffffff"
                renderType: Text.QtRendering
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignLeft
                horizontalAlignment: Text.AlignLeft
            }

            // Wattage (13px bold matching other capsule subtitles)
            Text {
                text: root.wattage
                font.family: root.sfFont
                font.pixelSize: 13
                font.bold: true
                color: root.modeColor
                renderType: Text.QtRendering
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignLeft
                horizontalAlignment: Text.AlignLeft

                Behavior on color { ColorAnimation { duration: 240; easing.type: Easing.OutCubic } }
            }
        }

        // 3. Chevron Indicator for Submenu Access
        Rectangle {
            id: chevBtn
            z: 10
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 26
            Layout.preferredHeight: 26
            radius: 13
            color: chevMouse.containsMouse ? "#20ffffff" : "transparent"

            Text {
                anchors.centerIn: parent
                font.family: root.iconFont
                font.pixelSize: 14
                color: chevMouse.containsMouse ? "#ffffff" : "#64748b"
                text: "󰅂"
                renderType: Text.QtRendering
                Behavior on color { ColorAnimation { duration: 150 } }
            }

            MouseArea {
                id: chevMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.clicked()
            }
        }
    }

    // ── Subtle 0.9s Debounce Liquid Progress Bar (Zero Layout Recalc) ───
    Rectangle {
        id: commitBar
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 4
        anchors.horizontalCenter: parent.horizontalCenter
        width: 100
        height: 2.2
        radius: 1.1
        color: root.modeColor
        opacity: root.pendingCommit ? 0.9 : 0.0
        transformOrigin: Item.Center
        scale: 0.0

        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on opacity { NumberAnimation { duration: 150 } }

        NumberAnimation {
            id: fillProgressAnim
            target: commitBar
            property: "scale"
            from: 0.0
            to: 1.0
            duration: 900
            running: root.pendingCommit
            easing.type: Easing.Linear
        }

        SequentialAnimation {
            id: commitFlashAnim
            NumberAnimation { target: commitBar; property: "opacity"; to: 1.0; duration: 80 }
            NumberAnimation { target: commitBar; property: "opacity"; to: 0.0; duration: 180 }
            PropertyAction { target: commitBar; property: "scale"; value: 0.0 }
        }
    }

    // ── Main Card Mouse Area (Left-Click: Submenu, Right-Click: Cycle)
    MouseArea {
        id: cardMouse
        z: -1
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        onClicked: (mouse) => {
            root.setClickPos(mouse.x, mouse.y)
            if (mouse.button === Qt.RightButton) {
                root.cycleNext()
            } else {
                root.clicked()
            }
        }
    }
}
