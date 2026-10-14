import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io

PanelWindow {
    id: root

    property bool open: false

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-alttab"
    WlrLayershell.keyboardFocus: root.open
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    color: "transparent"
    visible: root.open || exitTimer.running

    // ─────────────────────────────────────────────────────────────────────────────
    // DOCK DIMENSIONS & SPACING (Clean, roomy, no icons sticking out)
    // ─────────────────────────────────────────────────────────────────────────────
    readonly property real baseIconSize: 64
    readonly property real maxScale: 1.60
    readonly property real minScale: 1.0
    readonly property real effectWidth: 260
    readonly property real baseSpacing: 10
    readonly property real dockPaddingX: 24
    readonly property real dockPaddingY: 16
    readonly property real dockHeight: 132
    readonly property real dockRadius: 28

    // App state
    property var apps: []
    property int selectedIndex: 0
    property int selectedInstanceIndex: 0
    property bool showInstances: false // Only true when Alt + Arrow keys are used

    // Magnification animation states
    property var targetScales: []
    property var currentScales: []
    property var currentPositions: []
    property var targetPositions: []
    property real contentWidth: 0
    property var mouseFocalX: null

    // ─────────────────────────────────────────────────────────────────────────────
    // BACKGROUND REAL-TIME CLIENTS TRACKING
    // ─────────────────────────────────────────────────────────────────────────────
    property var rawClients: []

    Process {
        id: clientsProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onTextChanged: {
                if (text && text.length > 0) {
                    try {
                        let parsed = JSON.parse(text);
                        if (Array.isArray(parsed)) {
                            root.rawClients = parsed;
                            if (root.open) {
                                root.rebuildAppsFromClients();
                            }
                        }
                    } catch(e) {}
                }
            }
        }
    }

    // Refresh clients whenever active window changes
    Connections {
        target: Hyprland
        function onActiveToplevelChanged() {
            if (!root.open) {
                clientsProc.running = false;
                clientsProc.running = true;
            }
        }
    }

    Component.onCompleted: {
        clientsProc.running = true;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // IPC HANDLER
    // ─────────────────────────────────────────────────────────────────────────────
    IpcHandler {
        target: "alttab"
        function next() { root.step(1) }
        function prev() { root.step(-1) }
        function nextInstance() { root.navigateInstance(1) }
        function prevInstance() { root.navigateInstance(-1) }
        function release() {
            if (root.open) {
                root.commit()
            }
        }
        function close() { root.cancel() }
        function toggle() { root.open ? root.cancel() : root.step(1) }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // DESKTOP ENTRY LOOKUP
    // ─────────────────────────────────────────────────────────────────────────────
    function findDesktopEntry(appClass) {
        if (!appClass) return null;
        let c = appClass.toLowerCase();
        let desktopApps = (DesktopEntries && DesktopEntries.applications && DesktopEntries.applications.values)
            ? DesktopEntries.applications.values : [];

        for (let a of desktopApps) {
            if (!a) continue;
            let id = (a.id || "").toLowerCase();
            if (id === c || id === c + ".desktop" || id.replace(".desktop", "") === c) {
                return a;
            }
        }
        for (let a of desktopApps) {
            if (!a) continue;
            let id = (a.id || "").toLowerCase();
            let name = (a.name || "").toLowerCase();
            if (id.includes(c) || c.includes(id) || name === c) {
                return a;
            }
        }
        return null;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MRU APP ORDERING ENGINE
    // ─────────────────────────────────────────────────────────────────────────────
    function rebuildAppsFromClients() {
        let clients = root.rawClients.slice();
        if (clients.length === 0) {
            root.apps = [];
            return;
        }

        // 1. Filter out invalid/background windows and sort strictly by focusHistoryID
        let valid = clients.filter(c => {
            if (!c || !c.class) return false;
            let cls = c.class.toLowerCase();
            return cls !== "quickshell" && !cls.startsWith("org.quickshell");
        });

        valid.sort((a, b) => (a.focusHistoryID !== undefined ? a.focusHistoryID : 999) - (b.focusHistoryID !== undefined ? b.focusHistoryID : 999));

        if (valid.length === 0) {
            root.apps = [];
            return;
        }

        // 2. Group into applications strictly in order of appearance in MRU
        let appMap = {};
        let mruApps = [];

        for (let w of valid) {
            let key = (w.class || "").toLowerCase();
            let addr = w.address || "";
            if (!addr.startsWith("0x")) addr = "0x" + addr;

            let winObj = {
                address: addr,
                appClass: w.class,
                title: w.title || w.class,
                focusHistoryID: (w.focusHistoryID !== undefined) ? w.focusHistoryID : 999,
                workspaceId: (w.workspace && w.workspace.id !== undefined) ? w.workspace.id : 1,
                workspaceName: (w.workspace && w.workspace.name) ? String(w.workspace.name) : "1"
            };

            if (!appMap[key]) {
                let de = findDesktopEntry(w.class);
                let friendlyName = de && de.name ? de.name : (w.class.charAt(0).toUpperCase() + w.class.slice(1));
                let iconName = de && de.icon ? de.icon : w.class;
                let resolvedIcon = Quickshell.iconPath(iconName, true) || (iconName.startsWith("/") ? ("file://" + iconName) : ("image://icon/" + iconName));

                let appObj = {
                    id: key,
                    name: friendlyName,
                    icon: resolvedIcon,
                    instances: [winObj],
                    hasCurrent: (winObj.focusHistoryID === 0)
                };
                appMap[key] = appObj;
                mruApps.push(appObj);
            } else {
                appMap[key].instances.push(winObj);
                if (winObj.focusHistoryID === 0) {
                    appMap[key].hasCurrent = true;
                }
            }
        }

        // 3. New deterministic Alt+Tab ordering rule:
        // mruApps[0] is the CURRENT app (has focusHistoryID: 0)
        // mruApps[1] is the RECENT app (the app you were on before this one!)
        // Dock order: [ recent_app (index 0), current_app (index 1), 3rd_app, 4th_app, ... ]
        let ordered = [];
        if (mruApps.length >= 2) {
            ordered.push(mruApps[1]); // Index 0: Recent app (immediately focused!)
            ordered.push(mruApps[0]); // Index 1: Current app
            for (let i = 2; i < mruApps.length; i++) {
                ordered.push(mruApps[i]);
            }
        } else if (mruApps.length === 1) {
            ordered.push(mruApps[0]);
        }

        root.apps = ordered;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // STEPPING & NAVIGATION (Alt+Tab lifecycle)
    // ─────────────────────────────────────────────────────────────────────────────
    function step(direction) {
        if (!root.open) {
            // Instant synchronous rebuild from cached fresh clients
            rebuildAppsFromClients();
            // Trigger background refresh in parallel
            clientsProc.running = false;
            clientsProc.running = true;

            if (root.apps.length === 0) return;

            root.open = true;
            exitTimer.stop();
            root.mouseFocalX = null;
            root.selectedIndex = 0; // Focus recent app immediately
            root.showInstances = false; // Never show heading/instances on normal Alt+Tab

            let cur = root.apps[0];
            if (cur && cur.hasCurrent && cur.instances.length > 1) {
                root.selectedInstanceIndex = 1;
            } else {
                root.selectedInstanceIndex = 0;
            }

            initScalesAndPositions();
            animTimer.restart();
            focusTrap.forceActiveFocus();
        } else {
            if (root.apps.length === 0) return;
            root.mouseFocalX = null;
            root.showInstances = false; // Hide instance cards when tabbing to next app

            let count = root.apps.length;
            root.selectedIndex = (root.selectedIndex + direction + count) % count;

            let cur = root.apps[root.selectedIndex];
            if (cur && cur.hasCurrent && cur.instances.length > 1) {
                root.selectedInstanceIndex = 1; // Default to other instance for current app
            } else {
                root.selectedInstanceIndex = 0;
            }

            animTimer.restart();
        }
    }

    function navigateInstance(direction) {
        if (!root.open) {
            step(1);
        }
        if (root.apps.length === 0) return;
        let cur = root.apps[root.selectedIndex];
        if (!cur) return;

        // ONLY show instances when arrow keys are used
        root.showInstances = true;

        if (cur.instances.length > 1) {
            let count = cur.instances.length;
            root.selectedInstanceIndex = (root.selectedInstanceIndex + direction + count) % count;
        }
    }

    function selectInstance(idx) {
        if (!root.open || root.apps.length === 0) return;
        let cur = root.apps[root.selectedIndex];
        if (!cur || idx < 0 || idx >= cur.instances.length) return;
        root.selectedInstanceIndex = idx;
    }

    // Process to issue Hyprland Lua window focus & workspace switch
    Process {
        id: execProc
    }

    function executeSwitch(addr) {
        if (!addr) return;
        let lua = "local a = '" + addr + "'; for _, w in ipairs(hl.get_windows()) do if w.address == a then hl.dispatch(hl.dsp.focus({ window = w })); break end end";
        execProc.running = false;
        execProc.command = ["hyprctl", "eval", lua];
        execProc.running = true;
    }

    function commit() {
        if (!root.open) return;
        if (root.apps.length === 0) {
            cancel();
            return;
        }

        let app = root.apps[root.selectedIndex];
        if (!app || app.instances.length === 0) {
            cancel();
            return;
        }

        let target = app.instances[root.selectedInstanceIndex] || app.instances[0];

        // Instantly close dock
        root.open = false;
        animTimer.stop();
        exitTimer.restart();

        // Switch workspace & focus window
        executeSwitch(target.address);
    }

    function cancel() {
        if (root.open) {
            root.open = false;
            animTimer.stop();
            exitTimer.restart();
        }
    }

    Timer {
        id: exitTimer
        interval: 160
        repeat: false
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // COSINE MAGNIFICATION ENGINE & ANIMATION LOOP
    // ─────────────────────────────────────────────────────────────────────────────
    function initScalesAndPositions() {
        let n = root.apps.length;
        let initScales = [];
        let initPositions = [];
        let curX = 0;

        for (let i = 0; i < n; i++) {
            initScales.push(minScale);
            let sw = baseIconSize * minScale;
            initPositions.push(curX + sw / 2);
            curX += sw + baseSpacing;
        }

        root.currentScales = initScales;
        root.targetScales = initScales.slice();
        root.currentPositions = initPositions;
        root.targetPositions = initPositions.slice();
        root.contentWidth = Math.max(0, curX - baseSpacing);
    }

    function computeTargetMagnification(focalPosition) {
        let n = root.apps.length;
        if (focalPosition === null || focalPosition === undefined || n === 0) {
            let res = [];
            for (let i = 0; i < n; i++) res.push(minScale);
            return res;
        }

        let res = [];
        for (let i = 0; i < n; i++) {
            let normalCenter = (i * (baseIconSize + baseSpacing)) + (baseIconSize / 2);
            let minX = focalPosition - (effectWidth / 2);
            let maxX = focalPosition + (effectWidth / 2);

            if (normalCenter < minX || normalCenter > maxX) {
                res.push(minScale);
            } else {
                let theta = ((normalCenter - minX) / effectWidth) * 2 * Math.PI;
                let cappedTheta = Math.min(Math.max(theta, 0), 2 * Math.PI);
                let scaleFactor = (1.0 - Math.cos(cappedTheta)) / 2.0;
                res.push(minScale + (scaleFactor * (maxScale - minScale)));
            }
        }
        return res;
    }

    function computePositions(scales) {
        let curX = 0;
        let pos = [];
        for (let i = 0; i < scales.length; i++) {
            let sw = baseIconSize * scales[i];
            pos.push(curX + sw / 2);
            curX += sw + baseSpacing;
        }
        return pos;
    }

    Timer {
        id: animTimer
        interval: 16
        repeat: true
        running: false

        onTriggered: {
            if (!root.open && !exitTimer.running) {
                stop();
                return;
            }

            let n = root.apps.length;
            if (n === 0) {
                stop();
                return;
            }

            let focalX = root.mouseFocalX;
            if (focalX === null) {
                let idx = Math.max(0, Math.min(n - 1, root.selectedIndex));
                focalX = (idx * (baseIconSize + baseSpacing)) + (baseIconSize / 2);
            }

            let targetS = computeTargetMagnification(focalX);
            let targetP = computePositions(targetS);

            let lerpFactor = (root.mouseFocalX !== null) ? 0.22 : 0.16;
            let curS = root.currentScales.slice();
            let curP = root.currentPositions.slice();

            if (curS.length !== n) curS = targetS.slice();
            if (curP.length !== n) curP = targetP.slice();

            let maxScaleDiff = 0;
            let maxPosDiff = 0;

            for (let i = 0; i < n; i++) {
                let sDiff = targetS[i] - curS[i];
                curS[i] += sDiff * lerpFactor;
                let pDiff = targetP[i] - curP[i];
                curP[i] += pDiff * lerpFactor;

                if (Math.abs(sDiff) > maxScaleDiff) maxScaleDiff = Math.abs(sDiff);
                if (Math.abs(pDiff) > maxPosDiff) maxPosDiff = Math.abs(pDiff);
            }

            root.currentScales = curS;
            root.currentPositions = curP;

            if (curP.length > 0) {
                let lastIdx = curP.length - 1;
                root.contentWidth = curP[lastIdx] + (baseIconSize * curS[lastIdx]) / 2;
            }

            if (maxScaleDiff < 0.0015 && maxPosDiff < 0.08 && root.mouseFocalX === null) {
                stop();
            }
        }
    }

    // Dismiss on click outside
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: root.cancel()
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // KEYBOARD EVENT TRAP
    // ─────────────────────────────────────────────────────────────────────────────
    Item {
        id: focusTrap
        anchors.fill: parent
        focus: root.open

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.cancel();
                event.accepted = true;
                return;
            }
            if (event.key === Qt.Key_Tab) {
                if (event.modifiers & Qt.ShiftModifier) {
                    root.step(-1);
                } else {
                    root.step(1);
                }
                event.accepted = true;
                return;
            }
            if (event.key === Qt.Key_Backtab) {
                root.step(-1);
                event.accepted = true;
                return;
            }
            if (event.key === Qt.Key_Right || event.key === Qt.Key_Down || event.key === Qt.Key_AsciiTilde || event.key === Qt.Key_QuoteLeft) {
                root.navigateInstance(1);
                event.accepted = true;
                return;
            }
            if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                root.navigateInstance(-1);
                event.accepted = true;
                return;
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.commit();
                event.accepted = true;
                return;
            }
            if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                let num = event.key - Qt.Key_1;
                let cur = root.apps[root.selectedIndex];
                if (cur && num < cur.instances.length) {
                    root.showInstances = true;
                    root.selectInstance(num);
                    event.accepted = true;
                    return;
                }
            }
        }

        Keys.onReleased: function(event) {
            if (event.key === Qt.Key_Alt || event.key === Qt.Key_Meta) {
                root.commit();
                event.accepted = true;
                return;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // CENTER OVERLAY CONTAINER & VISUAL PRESENTATION
    // ─────────────────────────────────────────────────────────────────────────────
    Item {
        id: centerContainer
        anchors.centerIn: parent
        width: Math.max(dockBox.width, infoShelf.width)
        height: dockBox.height + (root.showInstances ? (infoShelf.height + 24) : 0)

        opacity: root.open ? 1.0 : 0.0
        scale: root.open ? 1.0 : 0.94

        Behavior on opacity {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }
        Behavior on scale {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }

        // ── 1. Floating Instances Shelf (ONLY shown when Alt + Arrow keys are used) ──
        ColumnLayout {
            id: infoShelf
            anchors.bottom: dockBox.top
            anchors.bottomMargin: 24
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 12
            visible: root.showInstances && currentApp !== null

            readonly property var currentApp: (root.apps.length > root.selectedIndex) ? root.apps[root.selectedIndex] : null
            readonly property var currentInstance: (currentApp && currentApp.instances && currentApp.instances.length > root.selectedInstanceIndex) 
                ? currentApp.instances[root.selectedInstanceIndex] 
                : (currentApp && currentApp.instances && currentApp.instances.length > 0 ? currentApp.instances[0] : null)

            // Header Pill: App Name + Active Window Title + Workspace Badge
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                implicitHeight: 40
                implicitWidth: headerRow.implicitWidth + 32
                radius: 20
                color: Theme.cardIdleColor
                border.width: 1
                border.color: Theme.cardBorderColor

                Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }
                Behavior on border.color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }

                RowLayout {
                    id: headerRow
                    anchors.centerIn: parent
                    spacing: 10

                    Text {
                        text: infoShelf.currentApp ? infoShelf.currentApp.name : ""
                        font.family: "SF Pro Rounded"
                        font.pixelSize: 15
                        font.bold: true
                        color: Theme.darkMode ? "#ffffff" : "#0f172a"
                    }

                    Rectangle {
                        width: 1
                        height: 14
                        color: Theme.cardBorderColor
                    }

                    Text {
                        text: infoShelf.currentInstance ? infoShelf.currentInstance.title : ""
                        font.family: "SF Pro Text"
                        font.pixelSize: 13
                        color: Theme.darkMode ? Qt.rgba(1.0, 1.0, 1.0, 0.80) : Qt.rgba(0.0, 0.0, 0.0, 0.70)
                        elide: Text.ElideRight
                        Layout.maximumWidth: 380
                    }

                    // Workspace tag
                    Rectangle {
                        implicitHeight: 22
                        implicitWidth: wsText.implicitWidth + 14
                        radius: 11
                        color: Theme.darkMode ? Qt.rgba(1.0, 1.0, 1.0, 0.16) : Qt.rgba(0.0, 0.0, 0.0, 0.08)
                        border.width: 1
                        border.color: Theme.cardBorderColor

                        Text {
                            id: wsText
                            anchors.centerIn: parent
                            text: "WS " + (infoShelf.currentInstance ? infoShelf.currentInstance.workspaceName : "1")
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 11
                            font.bold: true
                            color: Theme.darkMode ? "#ffffff" : "#0f172a"
                        }
                    }
                }
            }

            // Multi-Instance Card Shelf
            RowLayout {
                id: instanceCardsRow
                Layout.alignment: Qt.AlignHCenter
                spacing: 10
                visible: infoShelf.currentApp && infoShelf.currentApp.instances && infoShelf.currentApp.instances.length > 1

                Repeater {
                    model: (infoShelf.currentApp && infoShelf.currentApp.instances) ? infoShelf.currentApp.instances : []

                    delegate: Rectangle {
                        id: instCard
                        required property int index
                        required property var modelData

                        readonly property bool isSelected: index === root.selectedInstanceIndex
                        readonly property bool isCurrentWin: modelData.focusHistoryID === 0

                        implicitHeight: 52
                        implicitWidth: Math.min(280, Math.max(160, cardContent.implicitWidth + 24))
                        radius: 14

                        color: isSelected
                            ? Qt.rgba(0.24, 0.44, 0.90, 0.90) // Vibrant macOS accent blue
                            : (instHover.hovered 
                                ? (Theme.darkMode ? Qt.rgba(0.22, 0.22, 0.25, 0.94) : Qt.rgba(0.0, 0.0, 0.0, 0.08)) 
                                : Theme.cardIdleColor)

                        border.width: 1
                        border.color: isSelected
                            ? Qt.rgba(0.70, 0.88, 1.0, 0.95)
                            : Theme.cardBorderColor

                        Behavior on color { ColorAnimation { duration: 150 } }
                        Behavior on border.color { ColorAnimation { duration: 150 } }

                        RowLayout {
                            id: cardContent
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 10

                            Rectangle {
                                width: 24
                                height: 24
                                radius: 12
                                color: isSelected ? Qt.rgba(1.0, 1.0, 1.0, 0.28) : (Theme.darkMode ? Qt.rgba(1.0, 1.0, 1.0, 0.14) : Qt.rgba(0.0, 0.0, 0.0, 0.08))

                                Text {
                                    anchors.centerIn: parent
                                    text: String(index + 1)
                                    font.family: "SF Pro Text"
                                    font.pixelSize: 12
                                    font.bold: true
                                    color: isSelected ? "#ffffff" : (Theme.darkMode ? "#ffffff" : "#0f172a")
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.title
                                    font.family: "SF Pro Text"
                                    font.pixelSize: 12
                                    font.bold: isSelected
                                    color: isSelected ? "#ffffff" : (Theme.darkMode ? "#ffffff" : "#0f172a")
                                    elide: Text.ElideRight
                                }

                                RowLayout {
                                    spacing: 6
                                    Text {
                                        text: "Workspace " + modelData.workspaceName
                                        font.family: "SF Pro Text"
                                        font.pixelSize: 10
                                        color: isSelected ? Qt.rgba(1.0, 1.0, 1.0, 0.85) : (Theme.darkMode ? Qt.rgba(1.0, 1.0, 1.0, 0.55) : Qt.rgba(0.0, 0.0, 0.0, 0.55))
                                    }

                                    Text {
                                        visible: isCurrentWin
                                        text: "• Current"
                                        font.family: "SF Pro Text"
                                        font.pixelSize: 10
                                        font.bold: true
                                        color: isSelected ? "#a7f3d0" : "#68d391"
                                    }
                                }
                            }
                        }

                        HoverHandler { id: instHover }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.selectInstance(index);
                                root.commit();
                            }
                        }
                    }
                }
            }
        }

        // ── 2. The Clean, Roomy macOS Dock Container (Middle of Screen) ───────────
        Rectangle {
            id: dockBox
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.contentWidth + (root.dockPaddingX * 2)
            height: root.dockHeight
            radius: root.dockRadius

            // Dynamic background following dark and light theme (identical to Control Center widgets)
            color: Theme.cardIdleColor
            border.width: 1
            border.color: Theme.cardBorderColor

            Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on border.color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }

            // Mouse tracking over the dock
            MouseArea {
                id: dockMouseArea
                anchors.fill: parent
                hoverEnabled: true

                onPositionChanged: function(mouse) {
                    root.mouseFocalX = mouse.x - root.dockPaddingX;
                    animTimer.restart();
                }

                onExited: {
                    root.mouseFocalX = null;
                    animTimer.restart();
                }
            }

            // The Row of Scaled Icons (Vertically centered inside spacious dockBox)
            Item {
                id: iconCanvas
                anchors.left: parent.left
                anchors.leftMargin: root.dockPaddingX
                anchors.verticalCenter: parent.verticalCenter
                width: root.contentWidth
                height: root.baseIconSize * root.maxScale
                clip: false

                Repeater {
                    model: root.apps

                    delegate: Item {
                        id: iconDelegate
                        required property int index
                        required property var modelData

                        readonly property real curScale: (root.currentScales.length > index) ? root.currentScales[index] : 1.0
                        readonly property real curPos: (root.currentPositions.length > index) ? root.currentPositions[index] : 0.0
                        readonly property real scaledDim: root.baseIconSize * curScale
                        readonly property bool isSelected: index === root.selectedIndex

                        x: curPos - (scaledDim / 2)
                        y: (iconCanvas.height - scaledDim) / 2
                        width: scaledDim
                        height: scaledDim
                        z: Math.round(curScale * 10)

                        // Selection highlight pill behind icon
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -6
                            radius: Math.max(14, width * 0.25)
                            color: isSelected ? (Theme.darkMode ? Qt.rgba(1.0, 1.0, 1.0, 0.16) : Qt.rgba(0.0, 0.0, 0.0, 0.10)) : "transparent"
                            border.width: isSelected ? 1 : 0
                            border.color: Theme.darkMode ? Qt.rgba(1.0, 1.0, 1.0, 0.38) : Qt.rgba(0.0, 0.0, 0.0, 0.20)
                            visible: isSelected
                            antialiasing: true
                        }

                        // App Icon Image
                        Image {
                            id: iconImage
                            anchors.fill: parent
                            anchors.margins: Math.max(2, parent.width * 0.04)
                            source: modelData.icon || ""
                            fillMode: Image.PreserveAspectFit
                            mipmap: true
                            smooth: true
                            asynchronous: true
                            cache: true
                            visible: status === Image.Ready
                        }

                        // Fallback icon if image fails
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Math.max(2, parent.width * 0.04)
                            radius: Math.max(8, width * 0.22)
                            color: Qt.rgba(0.3, 0.3, 0.35, 0.85)
                            border.width: 1
                            border.color: Qt.rgba(1.0, 1.0, 1.0, 0.2)
                            visible: iconImage.status !== Image.Ready

                            Text {
                                anchors.centerIn: parent
                                text: modelData.name && modelData.name.length > 0 ? modelData.name.charAt(0).toUpperCase() : "󰀻"
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: Math.max(18, parent.width * 0.45)
                                font.bold: true
                                color: "#ffffff"
                            }
                        }

                        // Multi-Instance Count Badge (Top-Right)
                        Rectangle {
                            visible: modelData.instances && modelData.instances.length > 1
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.topMargin: -4
                            anchors.rightMargin: -4
                            implicitWidth: Math.max(18, instCountText.implicitWidth + 8)
                            implicitHeight: 18
                            radius: 9
                            color: Qt.rgba(0.12, 0.12, 0.15, 0.95)
                            border.width: 1
                            border.color: Qt.rgba(1.0, 1.0, 1.0, 0.35)
                            z: 20

                            Text {
                                id: instCountText
                                anchors.centerIn: parent
                                text: String(modelData.instances ? modelData.instances.length : 1)
                                font.family: "SF Pro Text"
                                font.pixelSize: 11
                                font.bold: true
                                color: "#ffffff"
                            }
                        }

                        // Running App Indicator Dot (Underneath Icon)
                        Rectangle {
                            anchors.top: parent.bottom
                            anchors.topMargin: 4
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 5
                            height: 5
                            radius: 2.5
                            color: Theme.darkMode ? Qt.rgba(1.0, 1.0, 1.0, 0.90) : Qt.rgba(0.0, 0.0, 0.0, 0.70)
                            antialiasing: true
                        }

                        // Click and hover handler on icon
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onEntered: {
                                root.selectedIndex = index;
                                if (modelData.hasCurrent && modelData.instances.length > 1) {
                                    root.selectedInstanceIndex = 1;
                                } else {
                                    root.selectedInstanceIndex = 0;
                                }
                            }
                            onClicked: {
                                root.selectedIndex = index;
                                root.commit();
                            }
                        }
                    }
                }
            }
        }
    }
}
