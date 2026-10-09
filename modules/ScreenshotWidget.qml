import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// ─────────────────────────────────────────────────────────────────────────────
// ScreenshotWidget — Native Quickshell Screenshot Engine & Liquid Preview Hub
//
// Root-Cause Fix Applied:
//   - Root dimensions (root.width / root.height) evaluate to 0 before a LayerShell
//     surface is configured by the compositor on the first capture.
//   - Replaced dynamic unmapped dimensions with guaranteed monitor bounds
//     via `Screen.width` / `Screen.height`, with explicit animation target
//     re-anchoring in triggerScreenshot().
//   - Eliminates the upper-left (0,0) flight trajectory glitch completely.
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    readonly property string sfFont: "SF Pro Rounded"
    readonly property string sfFontMedium: "SF Pro Rounded"
    readonly property string sfFontBold: "SF Pro Rounded"
    readonly property string sfFontSemibold: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    // Guaranteed screen dimensions (always non-zero, even before LayerShell configuration)
    readonly property real screenWidth: (root.width > 0) ? root.width : (Screen.width > 0 ? Screen.width : 1920)
    readonly property real screenHeight: (root.height > 0) ? root.height : (Screen.height > 0 ? Screen.height : 1080)

    // State properties
    property bool isActive: false
    property bool inFlight: false
    property bool isExiting: false
    property bool menuOpen: false
    property bool isHovered: false
    property bool autoSaved: false

    property string imagePath: ""
    property string fileName: ""
    property string fileDir: ""

    // Source capture geometry
    property real sourceX: 0
    property real sourceY: 0
    property real sourceW: 400
    property real sourceH: 300

    // Docked target dimensions (image + separate bottom slider tray)
    readonly property real dockW: 290
    readonly property real dockH: 196
    readonly property real dockMargin: 24

    // Dock target coordinates on screen (guaranteed non-negative)
    readonly property real dockX: screenWidth - dockW - dockMargin
    readonly property real dockY: screenHeight - dockH - dockMargin

    // Full screen overlay
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-screenshot"
    WlrLayershell.keyboardFocus: root.menuOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    color: "transparent"
    visible: root.isActive

    // ── Mouse Passthrough Mask ───────────────────────────────────────────────
    mask: root.menuOpen ? fullRegion : (root.isActive && !root.inFlight ? dockRegion : emptyRegion)

    Region {
        id: fullRegion
        x: 0
        y: 0
        width: root.screenWidth
        height: root.screenHeight
    }

    Region {
        id: dockRegion
        x: Math.max(0, root.dockX - 40)
        y: Math.max(0, root.dockY - (root.menuOpen ? 380 : 30))
        width: root.dockW + 80
        height: root.dockH + (root.menuOpen ? 400 : 60)
    }

    Region {
        id: emptyRegion
        x: 0
        y: 0
        width: 0
        height: 0
    }

    // ── Helper Process Runner ────────────────────────────────────────────────
    Process { id: actionProc }
    function runShell(cmd) {
        actionProc.running = false
        actionProc.command = ["sh", "-c", cmd]
        actionProc.running = true
    }

    // ── IPC Interface ────────────────────────────────────────────────────────
    IpcHandler {
        target: "screenshot"

        function trigger(dataStr: string): void { root.triggerScreenshot(dataStr) }
        function capture(dataStr: string): void { root.triggerScreenshot(dataStr) }

        function area(): void { root.runShell("~/.config/quickshell/scripts/screenshot.sh --area &") }
        function full(): void { root.runShell("~/.config/quickshell/scripts/screenshot.sh --full &") }
        function window(): void { root.runShell("~/.config/quickshell/scripts/screenshot.sh --win &") }

        function captureArea(): void { root.area() }
        function captureFull(): void { root.full() }
        function captureWindow(): void { root.window() }

        function dismiss(): void { root.startDismiss() }
        function edit(): void { root.openSatty() }
    }

    // ── Trigger Function ─────────────────────────────────────────────────────
    function triggerScreenshot(dataStr) {
        let data = {}
        try {
            if (typeof dataStr === "string" && dataStr.trim().startsWith("{")) {
                data = JSON.parse(dataStr)
            } else if (typeof dataStr === "object") {
                data = dataStr
            } else if (typeof dataStr === "string" && dataStr.trim() !== "") {
                data = { path: dataStr.trim() }
            }
        } catch(e) {
            data = { path: String(dataStr) }
        }

        const rawPath = data.path || ""
        if (!rawPath) return

        root.imagePath = rawPath.startsWith("file://") ? rawPath : "file://" + rawPath
        root.fileName = rawPath.substring(rawPath.lastIndexOf("/") + 1)
        root.fileDir = rawPath.substring(0, rawPath.lastIndexOf("/"))
        root.autoSaved = !!data.autoSaved

        // Guaranteed screen dimensions
        const sW = root.screenWidth
        const sH = root.screenHeight
        const targetDockX = sW - root.dockW - root.dockMargin
        const targetDockY = sH - root.dockH - root.dockMargin

        // Parse capture geometry
        const capX = Number(data.x)
        const capY = Number(data.y)
        const capW = Number(data.w)
        const capH = Number(data.h)

        if (!isNaN(capW) && capW > 10 && !isNaN(capH) && capH > 10) {
            root.sourceX = !isNaN(capX) ? capX : (sW - capW) / 2
            root.sourceY = !isNaN(capY) ? capY : (sH - capH) / 2
            root.sourceW = capW
            root.sourceH = capH
        } else {
            root.sourceX = 0
            root.sourceY = 0
            root.sourceW = sW
            root.sourceH = sH
        }

        // Initialize flight container explicitly
        flightContainer.flightX = root.sourceX
        flightContainer.flightY = root.sourceY
        flightContainer.flightW = root.sourceW
        flightContainer.flightH = root.sourceH
        flightContainer.flightRadius = 4
        flightContainer.flightGlow = 0.0

        // Set explicit animation endpoints
        flightAnimX.from = root.sourceX
        flightAnimX.to = targetDockX

        flightAnimY.from = root.sourceY
        flightAnimY.to = targetDockY

        flightAnimW.from = root.sourceW
        flightAnimW.to = root.dockW

        flightAnimH.from = root.sourceH
        flightAnimH.to = 180

        // Reset states
        progressAnim.stop()
        root.progressValue = 1.0
        root.menuOpen = false
        root.isExiting = false
        root.isHovered = false
        cardSlideX = 0
        cardOpacity = 1.0

        // Begin display & flight sequence
        root.isActive = true
        root.inFlight = true

        // 1. Shutter Flash
        flashAnim.restart()

        // 2. Liquid Flight Morph
        flightAnim.restart()
    }

    // ── GPU-Synchronized SceneGraph Progress Animation ───────────────────────
    property real progressValue: 1.0

    NumberAnimation {
        id: progressAnim
        target: root
        property: "progressValue"
        from: 1.0
        to: 0.0
        duration: 7500 // 7.5 seconds
        easing.type: Easing.Linear
        onFinished: {
            if (root.isActive && !root.isExiting) {
                root.startDismiss()
            }
        }
    }

    function pauseCountdown() {
        if (progressAnim.running) {
            progressAnim.pause()
        }
    }

    function resumeCountdown() {
        if (!root.menuOpen && root.isActive && !root.isExiting) {
            if (progressAnim.paused) {
                progressAnim.resume()
            } else if (!progressAnim.running && root.progressValue > 0) {
                progressAnim.restart()
            }
        }
    }

    function startDismiss() {
        if (root.isExiting || !root.isActive) return
        root.isExiting = true
        root.menuOpen = false
        progressAnim.stop()
        exitAnim.restart()
    }

    function resetAndHide() {
        // Zero-footprint VRAM cleanup: release textures from GPU memory
        root.imagePath = ""
        root.fileName = ""
        root.fileDir = ""
        root.isActive = false
        root.inFlight = false
        root.isExiting = false
        root.menuOpen = false
        root.progressValue = 1.0
        cardSlideX = 0
        cardOpacity = 1.0
    }

    // ── Sub-Menu Actions ─────────────────────────────────────────────────────
    function openSatty() {
        const cleanPath = root.imagePath.replace(/^file:\/\//, "")
        root.runShell("hyprctl dispatch exec \"satty --filename '" + cleanPath + "' --copy-command wl-copy --early-exit copy\" &")
        root.startDismiss()
    }

    function openSwappy() {
        const cleanPath = root.imagePath.replace(/^file:\/\//, "")
        root.runShell("hyprctl dispatch exec \"swappy -f '" + cleanPath + "'\" &")
        root.startDismiss()
    }

    function saveToDefault() {
        const cleanPath = root.imagePath.replace(/^file:\/\//, "")
        const defaultDir = "/home/banana/Pictures/Screenshots"
        const now = new Date()
        const pad = function(n) { return String(n).padStart(2, '0') }
        const ts = now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate()) + "_" + pad(now.getHours()) + "-" + pad(now.getMinutes()) + "-" + pad(now.getSeconds())
        const targetPath = defaultDir + "/Screenshot_" + ts + ".png"

        root.runShell("mkdir -p '" + defaultDir + "' && cp -f '" + cleanPath + "' '" + targetPath + "' && notify-send -u low 'Screenshot Saved' 'Saved to ~/Pictures/Screenshots' &")
        root.autoSaved = true
        root.startDismiss()
    }

    function saveAsDialog() {
        const cleanPath = root.imagePath.replace(/^file:\/\//, "")
        const now = new Date()
        const pad = function(n) { return String(n).padStart(2, '0') }
        const ts = now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate()) + "_" + pad(now.getHours()) + "-" + pad(now.getMinutes()) + "-" + pad(now.getSeconds())
        const defaultFile = "Screenshot_" + ts + ".png"
        
        const script = "DEST=$(zenity --file-selection --save --confirm-overwrite --filename=\"$HOME/Pictures/Screenshots/" + defaultFile + "\" --file-filter=\"PNG images | *.png\"); if [ -n \"$DEST\" ]; then cp -f '" + cleanPath + "' \"$DEST\" && notify-send -u low 'Screenshot Saved' \"Saved to $DEST\"; fi"
        root.runShell(script + " &")
        root.startDismiss()
    }

    function deleteScreenshot() {
        const cleanPath = root.imagePath.replace(/^file:\/\//, "")
        root.runShell("rm -f '" + cleanPath + "' &")
        root.startDismiss()
    }

    // ── Backdrop Click-Away (Closes Menu when Open) ──────────────────────────
    MouseArea {
        anchors.fill: parent
        enabled: root.menuOpen
        hoverEnabled: false
        onClicked: {
            root.menuOpen = false
            root.resumeCountdown()
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 1. FULLSCREEN CAMERA FLASH & SHUTTER PULSE
    // ══════════════════════════════════════════════════════════════════════════
    Rectangle {
        id: shutterFlash
        x: root.sourceX
        y: root.sourceY
        width: root.sourceW
        height: root.sourceH
        color: "transparent"
        border.color: Qt.rgba(1.0, 1.0, 1.0, 0.95)
        border.width: 3
        radius: 6
        opacity: 0.0

        Rectangle {
            anchors.fill: parent
            color: "#ffffff"
            opacity: 0.35
            radius: 4
        }

        SequentialAnimation {
            id: flashAnim
            NumberAnimation {
                target: shutterFlash
                property: "opacity"
                from: 0.0
                to: 1.0
                duration: 60
                easing.type: Easing.OutQuad
            }
            NumberAnimation {
                target: shutterFlash
                property: "opacity"
                from: 1.0
                to: 0.0
                duration: 220
                easing.type: Easing.InQuad
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 2. LIQUID FLIGHT MORPHING CONTAINER
    // ══════════════════════════════════════════════════════════════════════════
    Item {
        id: flightContainer
        visible: root.inFlight
        z: 999

        property real flightX: root.sourceX
        property real flightY: root.sourceY
        property real flightW: root.sourceW
        property real flightH: root.sourceH
        property real flightRadius: 0
        property real flightGlow: 0.0

        x: flightX
        y: flightY
        width: flightW
        height: flightH

        Rectangle {
            id: flightMask
            anchors.fill: parent
            radius: flightContainer.flightRadius
            color: "#ffffff"
            layer.enabled: true
            visible: false
        }

        Image {
            id: flightImg
            anchors.fill: parent
            source: root.imagePath
            fillMode: Image.PreserveAspectCrop
            smooth: true
            mipmap: true
            cache: false
            asynchronous: false
            visible: false
        }

        MultiEffect {
            anchors.fill: parent
            source: flightImg
            maskEnabled: true
            maskSource: flightMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }

        ParallelAnimation {
            id: flightAnim

            NumberAnimation {
                id: flightAnimX
                target: flightContainer
                property: "flightX"
                duration: 480
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                id: flightAnimY
                target: flightContainer
                property: "flightY"
                duration: 480
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                id: flightAnimW
                target: flightContainer
                property: "flightW"
                duration: 480
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                id: flightAnimH
                target: flightContainer
                property: "flightH"
                duration: 480
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                id: flightAnimR
                target: flightContainer
                property: "flightRadius"
                from: 4
                to: 18
                duration: 480
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                id: flightAnimG
                target: flightContainer
                property: "flightGlow"
                from: 0.0
                to: 1.0
                duration: 480
                easing.type: Easing.OutCubic
            }

            onFinished: {
                root.inFlight = false
                root.progressValue = 1.0
                progressAnim.restart()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 3. DOCKED BOTTOM-RIGHT PREVIEW CARD & SUB-MENU
    // ══════════════════════════════════════════════════════════════════════════
    property real cardSlideX: 0
    property real cardOpacity: 1.0

    // Dismiss Slide-Out Animation
    ParallelAnimation {
        id: exitAnim
        NumberAnimation {
            target: root
            property: "cardSlideX"
            from: 0
            to: 380
            duration: 320
            easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: root
            property: "cardOpacity"
            from: 1.0
            to: 0.0
            duration: 280
            easing.type: Easing.InQuad
        }
        onFinished: {
            root.resetAndHide()
        }
    }

    Item {
        id: dockAnchor
        x: root.dockX + root.cardSlideX
        y: root.dockY
        width: root.dockW
        height: root.dockH
        visible: root.isActive && !root.inFlight
        opacity: root.cardOpacity

        // ─────────────────────────────────────────────────────────────────────
        // CONTEXTUAL EDITING SUB-MENU (POPS UP ABOVE DOCKED PREVIEW ON CLICK)
        // ─────────────────────────────────────────────────────────────────────
        Item {
            id: editMenu
            anchors.bottom: mainPreviewCard.top
            anchors.bottomMargin: 12
            anchors.right: mainPreviewCard.right
            width: 310
            height: menuColumn.implicitHeight + 20
            visible: opacity > 0.001
            opacity: root.menuOpen ? 1.0 : 0.0
            scale: root.menuOpen ? 1.0 : 0.90
            transformOrigin: Item.BottomRight

            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }

            // Frosted Glass Menu Backdrop
            Rectangle {
                anchors.fill: parent
                radius: 20
                color: Theme.panelBgColor
                border.color: Theme.panelBorderColor
                border.width: 1.2

                // Specular Glass Gradient Highlight
                Rectangle {
                    anchors.fill: parent
                    radius: 20
                    color: "transparent"
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#30ffffff" }
                        GradientStop { position: 0.35; color: "#08ffffff" }
                        GradientStop { position: 1.0; color: "#00ffffff" }
                    }
                }

                // Inset Perimeter Rim
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1.2
                    radius: 18.8
                    color: "transparent"
                    border.color: Qt.rgba(1, 1, 1, 0.14)
                    border.width: 1
                }
            }

            ColumnLayout {
                id: menuColumn
                anchors.fill: parent
                anchors.margins: 10
                spacing: 5

                // ── Option 1: Annotate with Satty ────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    radius: 12
                    color: itemSattyMouse.containsMouse ? Qt.rgba(0.22, 0.48, 0.95, 0.35) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 12

                        Text {
                            text: "󰏫"
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: "#60a5fa"
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                text: "Annotate with Satty"
                                font.family: root.sfFontBold
                                font.pixelSize: 14
                                font.bold: true
                                color: "#ffffff"
                            }
                            Text {
                                text: "Arrows, text, shapes, blur & crop"
                                font.family: root.sfFont
                                font.pixelSize: 11
                                color: Qt.rgba(1, 1, 1, 0.65)
                            }
                        }
                    }
                    MouseArea {
                        id: itemSattyMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openSatty()
                    }
                }

                // ── Option 2: Open in Swappy ─────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    radius: 12
                    color: itemSwappyMouse.containsMouse ? Qt.rgba(1.0, 1.0, 1.0, 0.12) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 12

                        Text {
                            text: "󰄀"
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: "#34d399"
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                text: "Open in Swappy"
                                font.family: root.sfFontBold
                                font.pixelSize: 14
                                font.bold: true
                                color: "#ffffff"
                            }
                            Text {
                                text: "Simple brush & paint editor"
                                font.family: root.sfFont
                                font.pixelSize: 11
                                color: Qt.rgba(1, 1, 1, 0.65)
                            }
                        }
                    }
                    MouseArea {
                        id: itemSwappyMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openSwappy()
                    }
                }

                // Separator
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Qt.rgba(1, 1, 1, 0.12)
                }

                // ── Option 3: Save (to Pictures/Screenshots) ─────────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    radius: 12
                    color: itemSaveMouse.containsMouse ? Qt.rgba(1.0, 1.0, 1.0, 0.12) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 12

                        Text {
                            text: "󰆓"
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: "#38bdf8"
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                text: "Save"
                                font.family: root.sfFontBold
                                font.pixelSize: 14
                                font.bold: true
                                color: "#ffffff"
                            }
                            Text {
                                text: root.autoSaved ? "Already saved to ~/Pictures/Screenshots" : "Save to ~/Pictures/Screenshots"
                                font.family: root.sfFont
                                font.pixelSize: 11
                                color: Qt.rgba(1, 1, 1, 0.65)
                            }
                        }
                    }
                    MouseArea {
                        id: itemSaveMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.saveToDefault()
                    }
                }

                // ── Option 4: Save As... ─────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    radius: 12
                    color: itemSaveAsMouse.containsMouse ? Qt.rgba(1.0, 1.0, 1.0, 0.12) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 12

                        Text {
                            text: "󰉋"
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: "#fbbf24"
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                text: "Save As..."
                                font.family: root.sfFontBold
                                font.pixelSize: 14
                                font.bold: true
                                color: "#ffffff"
                            }
                            Text {
                                text: "Choose destination folder & file name"
                                font.family: root.sfFont
                                font.pixelSize: 11
                                color: Qt.rgba(1, 1, 1, 0.65)
                            }
                        }
                    }
                    MouseArea {
                        id: itemSaveAsMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.saveAsDialog()
                    }
                }

                // Separator
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Qt.rgba(1, 1, 1, 0.12)
                }

                // ── Option 5: Delete ─────────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    radius: 12
                    color: itemDeleteMouse.containsMouse ? Qt.rgba(0.9, 0.2, 0.2, 0.3) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 12

                        Text {
                            text: "󰆴"
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: "#f87171"
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                text: "Delete Screenshot"
                                font.family: root.sfFontBold
                                font.pixelSize: 14
                                font.bold: true
                                color: "#fca5a5"
                            }
                            Text {
                                text: "Discard file and dismiss"
                                font.family: root.sfFont
                                font.pixelSize: 11
                                color: Qt.rgba(1, 0.65, 0.65, 0.7)
                            }
                        }
                    }
                    MouseArea {
                        id: itemDeleteMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.deleteScreenshot()
                    }
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // MAIN PREVIEW CARD: IMAGE + SEPARATE BOTTOM TIMER TRAY (NO OVERLAP)
        // ─────────────────────────────────────────────────────────────────────
        Item {
            id: mainPreviewCard
            anchors.fill: parent

            // Tactile scale bounce on press
            scale: cardDragArea.pressed ? 0.975 : 1.0
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

            ColumnLayout {
                anchors.fill: parent
                spacing: 7

                // ── 1. ROUNDED IMAGE PREVIEW (TRUE BORDER RADIUS, NO OVERFLOW) ─
                Item {
                    id: imageSlot
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // Mask Texture
                    Rectangle {
                        id: imageMask
                        anchors.fill: parent
                        radius: 18
                        color: "#ffffff"
                        layer.enabled: true
                        visible: false
                    }

                    // Source Image
                    Image {
                        id: previewImg
                        anchors.fill: parent
                        source: root.imagePath
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                        cache: false
                        asynchronous: false
                        visible: false
                    }

                    // Hardware Masked Output
                    MultiEffect {
                        anchors.fill: parent
                        source: previewImg
                        maskEnabled: true
                        maskSource: imageMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }

                    // Subtle Specular Glaze (Rounded)
                    Rectangle {
                        anchors.fill: parent
                        radius: 18
                        color: "transparent"
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#22ffffff" }
                            GradientStop { position: 0.35; color: "#04ffffff" }
                            GradientStop { position: 1.0; color: "#00000000" }
                        }
                    }
                }

                // ── 2. SEPARATE BOTTOM TIMER SLIDER BAR (NEVER OVERLAPS IMAGE) ─
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 4
                    Layout.leftMargin: 6
                    Layout.rightMargin: 6
                    radius: 2
                    color: Qt.rgba(1.0, 1.0, 1.0, 0.15)
                    clip: true

                    Rectangle {
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        width: parent.width * root.progressValue
                        radius: 2
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#38bdf8" }
                            GradientStop { position: 1.0; color: "#60a5fa" }
                        }
                    }
                }
            }

            // ── DRAG AND DROP ITEM ───────────────────────────────────────────
            Item {
                id: dragProxy
                anchors.fill: parent

                Drag.active: cardDragArea.drag.active
                Drag.dragType: Drag.Automatic
                Drag.supportedActions: Qt.CopyAction | Qt.LinkAction
                Drag.mimeData: {
                    "text/uri-list": root.imagePath + "\r\n",
                    "text/plain": root.imagePath.replace(/^file:\/\//, "")
                }
                Drag.imageSource: root.imagePath
            }

            // ── MOUSE & DRAG INTERACTION AREA ────────────────────────────────
            MouseArea {
                id: cardDragArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                drag.target: dragProxy
                cursorShape: cardDragArea.drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                z: 20

                onEntered: {
                    root.isHovered = true
                    root.pauseCountdown()
                }

                onExited: {
                    root.isHovered = false
                    if (!cardDragArea.drag.active && !root.menuOpen) {
                        root.resumeCountdown()
                    }
                }

                onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) {
                        // Right Click: Immediately dismiss (slide to right)
                        root.startDismiss()
                    } else if (mouse.button === Qt.LeftButton) {
                        // Left Click: Toggle sub-menu
                        root.menuOpen = !root.menuOpen
                        if (root.menuOpen) root.pauseCountdown()
                        else root.resumeCountdown()
                    }
                }
            }
        }
    }
}
