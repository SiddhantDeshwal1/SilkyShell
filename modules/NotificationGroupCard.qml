import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Widgets

// ─────────────────────────────────────────────────────────────────────────────
// NotificationGroupCard — Frosted Liquid Glass Stacking & Kinetic Physics
//
// Features:
//   - Subtle & Buttery Smooth 60fps Left-to-Right Dismissal Animations.
//   - Pure horizontal slide & cubic fade with zero visual flash or jarring tilts.
//   - Interactive Swipe & Drag-to-Dismiss on all individual cards.
//   - Instant Reactive Data Binding: Direct item binding with fallbacks.
//   - GPU-Accelerated Layer Caching & SDF QtRendering for rock-solid 60fps.
//   - Liquid Glass Aesthetics: Top tile dense/opaque; underlying tiles frosted & translucent.
//   - High-Contrast SF Pro Typography: Readably rendered in any lighting.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    property string groupKey: ""
    property string appName: "Notification"
    property string iconSource: ""
    property string appIcon: "󰂞"
    property string iconBg: "#2563eb"
    property var notifs: []
    property int count: (root.notifs && root.notifs.length !== undefined) ? root.notifs.length : 0
    property bool isClearingAll: false

    property string sfFont: "SF Pro Rounded"
    property string sfFontMedium: "SF Pro Rounded"
    property string sfFontSemibold: "SF Pro Rounded"
    property string sfFontBold: "SF Pro Rounded"
    property string iconFont: "JetBrainsMono NFP"

    signal dismissNotification(int notifId)
    signal dismissGroup(string groupKey)

    property bool isExpanded: false
    onCountChanged: {
        if (root.count <= 1) root.isExpanded = false
    }

    // ── Buttery 60fps Liquid Motion Physics Curves ────────────────────
    // Expressive fluid spring with soft 8% liquid momentum overshoot on expand:
    readonly property var fluidExpandCurve: [0.25, 1.08, 0.22, 1.0, 1.0, 1.0]
    // Responsive, silky smooth collapse curve without dragging delay:
    readonly property var fluidCollapseCurve: [0.32, 0.0, 0.20, 1.0, 1.0, 1.0]

    // Dynamic Stacking geometry calculations
    readonly property real cardGap: 10
    property real topCardHeight: 76
    property real expandedHeight: 0

    function recalcExpandedHeight() {
        let total = 0
        for (let i = 0; i < cardRepeater.count; i++) {
            let item = cardRepeater.itemAt(i)
            if (item) {
                total += item.calculatedHeight + (i > 0 ? root.cardGap : 0)
            }
        }
        root.expandedHeight = total
    }

    function getExpandedCardY(targetIndex) {
        let y = 0
        for (let i = 0; i < targetIndex; i++) {
            let itm = cardRepeater.itemAt(i)
            let h = (itm && itm.calculatedHeight > 0) ? itm.calculatedHeight : (root.topCardHeight > 0 ? root.topCardHeight : 76)
            y += h + root.cardGap
        }
        return y
    }

    function getStackHeight(exp, total) {
        if (total <= 1) return root.topCardHeight
        if (!exp) {
            if (total === 2) return root.topCardHeight + 14
            return root.topCardHeight + 28
        }
        if (root.expandedHeight > 0) return Math.max(root.expandedHeight, root.topCardHeight)
        return Math.max(total * (root.topCardHeight + root.cardGap), root.topCardHeight)
    }

    function getCardScale(i, exp, total) {
        if (exp) return 1.0
        if (i === 0) return 1.0
        if (i === 1) return 0.96
        if (i === 2) return 0.92
        return 0.88
    }

    function getCardOpacity(i, exp, total) {
        if (exp) return 1.0
        if (i === 0) return 1.0
        if (i === 1) return 0.90
        if (i === 2) return 0.75
        return 0.0
    }

    onNotifsChanged: {
        Qt.callLater(function() {
            root.recalcExpandedHeight()
            let c0 = cardRepeater.itemAt(0)
            if (c0) root.topCardHeight = c0.calculatedHeight
        })
    }

    width: parent ? parent.width : 376
    implicitHeight: groupContainer.implicitHeight
    height: implicitHeight

    // ══════════════════════════════════════════════════════════════════
    // UNIFIED CARD STACK CONTAINER (Handles 1, 2, or N Cards Fluidly)
    // ══════════════════════════════════════════════════════════════════
    Item {
        id: groupContainer
        anchors.left: parent.left
        anchors.right: parent.right
        implicitHeight: groupLayout.implicitHeight + (root.count > 1 ? 16 : 0)
        height: implicitHeight

        // Frosted Background Shell for Multi-card Stack
        LiquidGlassCard {
            id: outerGlassBg
            enableWave: false
            anchors.fill: parent
            cardRadius: root.isExpanded ? 30 : 28
            idleColor: root.isExpanded
                ? (Theme.darkMode ? "#55101622" : "#22ffffff")
                : (Theme.darkMode ? "#50101622" : "#18ffffff")
            opacity: root.count > 1 ? 1.0 : 0.0
            visible: opacity > 0.01

            Behavior on cardRadius {
                NumberAnimation { duration: root.isExpanded ? 500 : 200; easing.type: Easing.OutCubic }
            }
            Behavior on idleColor {
                ColorAnimation { duration: root.isExpanded ? 520 : 200 }
            }
            Behavior on opacity {
                NumberAnimation { duration: root.isExpanded ? 320 : 200; easing.type: Easing.OutCubic }
            }
        }

        // Subtle Left-to-Right Slide on Clear All
        transform: [
            Translate {
                x: root.isClearingAll ? 120 : 0
                Behavior on x {
                    NumberAnimation {
                        duration: 240
                        easing.type: Easing.OutCubic
                    }
                }
            }
        ]

        opacity: root.isClearingAll ? 0.0 : 1.0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        ColumnLayout {
            id: groupLayout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: root.count > 1 ? 8 : 0
            spacing: 8

            // ── 1. Interactive Stacked Cards Area ─────────────────────
            Item {
                id: stackContainer
                Layout.fillWidth: true
                implicitHeight: root.getStackHeight(root.isExpanded, root.count)
                height: implicitHeight

                Behavior on implicitHeight {
                    NumberAnimation {
                        duration: root.isExpanded ? 580 : 230
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: root.isExpanded ? root.fluidExpandCurve : root.fluidCollapseCurve
                    }
                }

                Repeater {
                    id: cardRepeater
                    model: root.notifs || []

                    delegate: Item {
                        id: cardItem
                        anchors.left: parent.left
                        anchors.right: parent.right
                        transformOrigin: Item.Top

                        readonly property real calculatedHeight: Math.min(
                            Screen.height - 180,
                            Math.max(
                                root.count === 1 ? 76 : 70,
                                cardContentRow.implicitHeight + (root.count === 1 ? 24 : 20)
                            )
                        )

                        readonly property real card0Height: root.topCardHeight > 0 ? root.topCardHeight : calculatedHeight

                        height: root.isExpanded ? calculatedHeight : card0Height
                        implicitHeight: height

                        Behavior on height {
                            NumberAnimation {
                                duration: root.isExpanded
                                    ? Math.min(600, 520 + index * 30)
                                    : 230
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: root.isExpanded ? root.fluidExpandCurve : root.fluidCollapseCurve
                            }
                        }

                        onCalculatedHeightChanged: {
                            if (index === 0) {
                                root.topCardHeight = calculatedHeight
                            }
                            root.recalcExpandedHeight()
                        }

                        Component.onCompleted: {
                            if (index === 0) {
                                root.topCardHeight = calculatedHeight
                            }
                            root.recalcExpandedHeight()
                        }

                        readonly property var itemData: (typeof modelData !== "undefined" && modelData) ? modelData : {}
                        readonly property int notifId: itemData.notifId !== undefined ? itemData.notifId : 0
                        readonly property string nTitle: itemData.title !== undefined ? String(itemData.title) : ""
                        readonly property string nBody: itemData.body !== undefined ? String(itemData.body) : ""
                        readonly property string nApp: itemData.app !== undefined ? String(itemData.app) : (root.appName || "Notification")
                        readonly property string nTime: itemData.timeStr !== undefined ? String(itemData.timeStr) : ""
                        readonly property string nIconSrc: itemData.iconSource !== undefined ? String(itemData.iconSource) : (root.iconSource || "")
                        readonly property string nAppIcon: itemData.appIcon !== undefined ? String(itemData.appIcon) : (root.appIcon || "󰂞")
                        readonly property string nIconBg: itemData.iconBg !== undefined ? String(itemData.iconBg) : (root.iconBg || "#2563eb")

                        property int cardIndex: index
                        property bool isTop: index === 0
                        property bool isDismissing: false
                        property real dragOffsetX: 0
                        property real exitOpacity: 1.0

                        function startDismiss() {
                            if (isDismissing) return
                            isDismissing = true
                            groupDismissAnim.restart()
                        }

                        // Subtle, Buttery Smooth 60fps Left-to-Right Dismissal Animation
                        SequentialAnimation {
                            id: groupDismissAnim
                            ParallelAnimation {
                                NumberAnimation {
                                    target: cardItem
                                    property: "dragOffsetX"
                                    to: cardItem.width + 40
                                    duration: 260
                                    easing.type: Easing.OutCubic
                                }
                                NumberAnimation {
                                    target: cardItem
                                    property: "exitOpacity"
                                    to: 0.0
                                    duration: 240
                                    easing.type: Easing.OutQuad
                                }
                            }
                            ScriptAction {
                                script: {
                                    root.dismissNotification(cardItem.notifId)
                                }
                            }
                        }

                        ParallelAnimation {
                            id: groupSpringBack
                            NumberAnimation {
                                target: cardItem
                                property: "dragOffsetX"
                                to: 0
                                duration: 220
                                easing.type: Easing.OutCubic
                            }
                            NumberAnimation {
                                target: cardItem
                                property: "exitOpacity"
                                to: 1.0
                                duration: 180
                                easing.type: Easing.OutCubic
                            }
                        }

                        z: root.count - index
                        visible: opacity > 0.01

                        readonly property real targetY: {
                            if (!root.isExpanded) {
                                if (index === 0) return 0
                                if (index === 1) return 14
                                if (index === 2) return 28
                                return 28
                            }
                            let _ = root.expandedHeight
                            return root.getExpandedCardY(index)
                        }

                        // Liquid Spring upward glide: when top tile exits, lower tiles glide smoothly up to y: 0
                        y: isDismissing ? 0 : targetY
                        scale: root.getCardScale(index, root.isExpanded, root.count)
                        opacity: isDismissing ? exitOpacity : root.getCardOpacity(index, root.isExpanded, root.count)
                        x: isDismissing ? dragOffsetX : 0

                        Behavior on y {
                            enabled: !cardItem.isDismissing
                            NumberAnimation {
                                duration: root.isExpanded
                                    ? Math.min(620, 520 + index * 35)
                                    : Math.min(250, 210 + index * 15)
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: root.isExpanded ? root.fluidExpandCurve : root.fluidCollapseCurve
                            }
                        }
                        Behavior on scale {
                            enabled: !cardItem.isDismissing
                            NumberAnimation {
                                duration: root.isExpanded
                                    ? Math.min(600, 520 + index * 30)
                                    : 230
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: root.isExpanded ? root.fluidExpandCurve : root.fluidCollapseCurve
                            }
                        }
                        Behavior on opacity {
                            enabled: !cardItem.isDismissing
                            NumberAnimation {
                                duration: root.isExpanded ? 480 : 180
                                easing.type: Easing.OutCubic
                            }
                        }

                        // Frosted Liquid Glass Card (Top tile dense/opaque; deeper tiles translucent)
                        LiquidGlassCard {
                            id: innerCardRect
                            enableWave: false
                            anchors.fill: parent
                            clip: true
                            cardRadius: root.count === 1 ? 24 : (root.isExpanded ? 22 : 20)
                            isHovered: innerMouse.containsMouse
                            idleColor: (cardItem.isTop || root.isExpanded)
                                ? (Theme.darkMode ? "#f0131c28" : "#f2ffffff")
                                : (Theme.darkMode ? "#60111822" : "#20ffffff")

                            Behavior on cardRadius {
                                NumberAnimation {
                                    duration: root.isExpanded ? 500 : 220
                                    easing.type: Easing.OutCubic
                                }
                            }
                            Behavior on idleColor {
                                ColorAnimation {
                                    duration: root.isExpanded ? 500 : 220
                                }
                            }

                            MouseArea {
                                id: innerMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: root.count === 1 ? Qt.PointingHandCursor : (pressed ? Qt.ClosedHandCursor : Qt.ArrowCursor)
                                preventStealing: true

                                property real startX: 0
                                property bool isDragging: false

                                onPressed: function(mouse) {
                                    startX = mouse.x
                                    isDragging = false
                                }

                                onPositionChanged: function(mouse) {
                                    if (pressed && !cardItem.isDismissing) {
                                        let diffX = mouse.x - startX
                                        if (diffX > 4 || isDragging) {
                                            isDragging = true
                                            cardItem.dragOffsetX = Math.max(0, diffX)
                                            cardItem.exitOpacity = Math.max(0.0, 1.0 - (cardItem.dragOffsetX / (cardItem.width * 0.9)))
                                        }
                                    }
                                }

                                onReleased: function(mouse) {
                                    if (cardItem.isDismissing) return
                                    if (isDragging) {
                                        if (cardItem.dragOffsetX > 65) {
                                            cardItem.startDismiss()
                                        } else {
                                            groupSpringBack.restart()
                                        }
                                        isDragging = false
                                    } else {
                                        if (root.count === 1) {
                                            cardItem.startDismiss()
                                        }
                                    }
                                }
                            }

                            // Content Row with intelligent fade & subtle parallax glide
                            // (When collapsed, deeper cards hide their text to eliminate ghost overlapping)
                            RowLayout {
                                id: cardContentRow
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: root.count === 1 ? 12 : 10
                                spacing: root.count === 1 ? 12 : 10

                                opacity: (cardItem.isTop || root.isExpanded) ? 1.0 : 0.0
                                Behavior on opacity {
                                    NumberAnimation {
                                        duration: root.isExpanded ? 440 : 180
                                        easing.type: root.isExpanded ? Easing.OutCubic : Easing.InQuad
                                    }
                                }

                                transform: [
                                    Translate {
                                        y: (!cardItem.isTop && !root.isExpanded) ? -8 : 0
                                        Behavior on y {
                                            NumberAnimation {
                                                duration: root.isExpanded ? 520 : 240
                                                easing.type: Easing.BezierSpline
                                                easing.bezierCurve: root.isExpanded ? root.fluidExpandCurve : root.fluidCollapseCurve
                                            }
                                        }
                                    }
                                ]

                                // App Squircle Badge
                                Rectangle {
                                    Layout.alignment: Qt.AlignTop
                                    Layout.preferredWidth: root.count === 1 ? 44 : 38
                                    Layout.preferredHeight: root.count === 1 ? 44 : 38
                                    radius: root.count === 1 ? 12 : 10
                                    color: (cIconImg.status === Image.Ready && cardItem.nIconSrc !== "")
                                        ? "transparent"
                                        : (cardItem.nIconBg !== "" ? cardItem.nIconBg : "#2563eb")
                                    clip: true

                                    IconImage {
                                        id: cIconImg
                                        anchors.fill: parent
                                        source: cardItem.nIconSrc
                                        visible: cardItem.nIconSrc !== "" && status === Image.Ready
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        font.family: root.iconFont
                                        font.pixelSize: root.count === 1 ? 22 : 19
                                        color: "#ffffff"
                                        text: cardItem.nAppIcon !== "" ? cardItem.nAppIcon : "󰂞"
                                        visible: !cIconImg.visible
                                        renderType: Text.QtRendering
                                    }
                                }

                                // Text Content (Large High-Contrast Typography)
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignTop
                                    spacing: 3

                                    // Header: App name + Counter Pill (if collapsed top) + Time + Close
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6

                                        Text {
                                            font.family: root.sfFontSemibold
                                            font.pixelSize: 13
                                            font.capitalization: Font.AllUppercase
                                            color: Theme.darkMode ? "#93c5fd" : "#000000"
                                            text: cardItem.nApp !== "" ? cardItem.nApp : "NOTIFICATION"
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                            renderType: Text.QtRendering
                                        }

                                        // RotateCcw Count Badge Pill (matches top card counter)
                                        Rectangle {
                                            id: countPill
                                            readonly property bool shouldShow: cardItem.isTop && !root.isExpanded && root.count > 1
                                            implicitWidth: cntRow.implicitWidth + 10
                                            implicitHeight: 20
                                            radius: 10
                                            color: Theme.darkMode ? "#353b82f6" : "#20000000"
                                            border.width: 1
                                            border.color: Theme.darkMode ? "#6060a5fa" : "#30000000"

                                            opacity: shouldShow ? 1.0 : 0.0
                                            scale: shouldShow ? 1.0 : 0.6
                                            visible: opacity > 0.01

                                            Behavior on opacity {
                                                NumberAnimation {
                                                    duration: root.isExpanded ? 320 : 200
                                                    easing.type: Easing.OutCubic
                                                }
                                            }
                                            Behavior on scale {
                                                NumberAnimation {
                                                    duration: root.isExpanded ? 320 : 200
                                                    easing.type: Easing.BezierSpline
                                                    easing.bezierCurve: root.isExpanded ? root.fluidExpandCurve : root.fluidCollapseCurve
                                                }
                                            }

                                            RowLayout {
                                                id: cntRow
                                                anchors.centerIn: parent
                                                spacing: 3

                                                Text {
                                                    text: "󰑖"
                                                    font.family: root.iconFont
                                                    font.pixelSize: 11
                                                    color: Theme.darkMode ? "#93c5fd" : "#000000"
                                                    renderType: Text.QtRendering
                                                }

                                                Text {
                                                    text: String(root.count)
                                                    font.family: root.sfFontBold
                                                    font.pixelSize: 12
                                                    color: Theme.darkMode ? "#ffffff" : "#000000"
                                                    renderType: Text.QtRendering
                                                }
                                            }
                                        }

                                        Text {
                                            font.family: root.sfFontSemibold
                                            font.pixelSize: 12
                                            font.bold: true
                                            color: Theme.darkMode ? "#cbd5e1" : "#334155"
                                            text: cardItem.nTime
                                            visible: cardItem.nTime !== ""
                                            renderType: Text.QtRendering
                                        }

                                        // Individual Card Close Button
                                        Rectangle {
                                            implicitWidth: 22
                                            implicitHeight: 22
                                            radius: 11
                                            opacity: (root.isExpanded || cardItem.isTop) ? 1.0 : 0.0
                                            visible: opacity > 0.01
                                            color: cCloseMouse.containsMouse ? (Theme.darkMode ? "#33ffffff" : "#20000000") : "transparent"

                                            Behavior on opacity {
                                                NumberAnimation {
                                                    duration: root.isExpanded ? 440 : 180
                                                    easing.type: root.isExpanded ? Easing.OutCubic : Easing.InQuad
                                                }
                                            }

                                            scale: cCloseMouse.pressed ? 0.90 : (cCloseMouse.containsMouse ? 1.12 : 1.0)
                                            Behavior on scale {
                                                NumberAnimation {
                                                    duration: 120
                                                    easing.type: Easing.OutCubic
                                                }
                                            }

                                            Text {
                                                anchors.centerIn: parent
                                                font.family: root.iconFont
                                                font.pixelSize: 13
                                                color: cCloseMouse.containsMouse ? "#ef4444" : (Theme.darkMode ? "#94a3b8" : "#64748b")
                                                text: "󰅖"
                                                renderType: Text.QtRendering
                                            }

                                            MouseArea {
                                                id: cCloseMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: cardItem.startDismiss()
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
                                        text: cardItem.nTitle
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
                                        text: cardItem.nBody
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

            // ── 2. Animated Footer Bar (When Count > 1) ────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 4
                Layout.rightMargin: 4
                Layout.topMargin: 2
                spacing: 8
                opacity: root.count > 1 ? 1.0 : 0.0
                visible: opacity > 0.01

                Behavior on opacity {
                    NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
                }

                // Expand / Collapse Pill Button
                Rectangle {
                    implicitWidth: expandRow.implicitWidth + 20
                    implicitHeight: 28
                    radius: 14
                    color: expMouse.containsMouse ? (Theme.darkMode ? "#30ffffff" : "#18000000") : (Theme.darkMode ? "#18ffffff" : "#0d000000")
                    border.width: 1
                    border.color: expMouse.containsMouse ? (Theme.darkMode ? "#60ffffff" : "#45000000") : (Theme.darkMode ? "#25ffffff" : "#20000000")

                    scale: expMouse.pressed ? 0.95 : (expMouse.containsMouse ? 1.03 : 1.0)
                    Behavior on scale {
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }

                    RowLayout {
                        id: expandRow
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: "󰅀"
                            font.family: root.iconFont
                            font.pixelSize: 13
                            color: Theme.darkMode ? "#93c5fd" : "#000000"
                            renderType: Text.QtRendering
                            rotation: root.isExpanded ? 180 : 0
                            Behavior on rotation {
                                NumberAnimation {
                                    duration: root.isExpanded ? 460 : 220
                                    easing.type: Easing.BezierSpline
                                    easing.bezierCurve: root.isExpanded ? root.fluidExpandCurve : root.fluidCollapseCurve
                                }
                            }
                        }

                        Text {
                            text: root.isExpanded ? "Collapse" : (root.count + " notifications")
                            font.family: root.sfFontMedium
                            font.pixelSize: 13
                            color: Theme.darkMode ? "#ffffff" : "#000000"
                            renderType: Text.QtRendering
                        }
                    }

                    MouseArea {
                        id: expMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.count > 1) {
                                root.isExpanded = !root.isExpanded
                            }
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                // Clear Group Pill Button
                Rectangle {
                    implicitWidth: clearGrpRow.implicitWidth + 18
                    implicitHeight: 28
                    radius: 14
                    color: clrGrpMouse.containsMouse ? "#35ef4444" : (Theme.darkMode ? "#18ffffff" : "#0d000000")
                    border.width: 1
                    border.color: clrGrpMouse.containsMouse ? "#80ef4444" : (Theme.darkMode ? "#25ffffff" : "#20000000")

                    scale: clrGrpMouse.pressed ? 0.95 : (clrGrpMouse.containsMouse ? 1.03 : 1.0)
                    Behavior on scale {
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }

                    RowLayout {
                        id: clearGrpRow
                        anchors.centerIn: parent
                        spacing: 5

                        Text {
                            text: "󰅖"
                            font.family: root.iconFont
                            font.pixelSize: 12
                            color: clrGrpMouse.containsMouse ? "#ef4444" : (Theme.darkMode ? "#94a3b8" : "#334155")
                            renderType: Text.QtRendering
                        }

                        Text {
                            text: "Clear"
                            font.family: root.sfFontMedium
                            font.pixelSize: 13
                            color: clrGrpMouse.containsMouse ? "#ef4444" : (Theme.darkMode ? "#94a3b8" : "#334155")
                            renderType: Text.QtRendering
                        }
                    }

                    MouseArea {
                        id: clrGrpMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.dismissGroup(root.groupKey)
                    }
                }
            }
        }
    }
}
