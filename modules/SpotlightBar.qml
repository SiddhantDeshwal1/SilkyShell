import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "SpotlightSemantic.js" as Semantic

Item {
    id: root
    property bool isOpen: false
    signal closeRequested()
    signal runCommand(string cmd)
    function forceSearch(q) { searchValue = q; textInput.text = q; }

    property bool hovered: false
    property int hoveredShortcut: -1
    property int hoveredResult: -1
    property string searchValue: ""
    property var searchResults: []

    property string activeFilter: ""
    property var shortcuts: [
        { id: "apps", icon: "󰕰", label: "Apps" },
        { id: "files", icon: "󰉋", label: "Files" },
        { id: "clipboard", icon: "󰈔", label: "Clipboard" },
        { id: "web", icon: "󰖟", label: "Web" }
    ]
    readonly property var springCurve: [0.25, 0.80, 0.35, 1.015, 0.55, 1.015, 0.70, 1.015, 0.80, 1.000, 1.00, 1.000]
    // Hyprland myBezier from hyprland.lua: points = {{0.05, 0.9}, {0.1, 1.05}}
    readonly property var myBezier: [0.05, 0.9, 0.1, 1.05, 1.0, 1.0]
    // Exact mathematical time-reverse mirror of myBezier: (1-x2, 1-y2, 1-x1, 1-y1) -> [0.90, 0.0, 0.95, 0.10, 1.0, 1.0]
    readonly property var reverseMyBezier: [0.90, 0.0, 0.95, 0.10, 1.0, 1.0]
    readonly property bool showShortcuts: root.hovered && root.searchValue === "" && root.activeFilter === ""

    function activateShortcut(index) {
        if (index >= 0 && index < root.shortcuts.length) {
            let label = root.shortcuts[index].label;
            root.activeFilter = (root.activeFilter === label) ? "" : label;
            root.hoveredShortcut = -1;
            root.searchValue = "";
            textInput.text = "";
            if (root.activeFilter === "Clipboard") {
                clipboardView.reload();
            } else if (root.activeFilter === "Files") {
                filesView.reload();
            } else if (root.activeFilter === "Web") {
                webView.reload();
            }
            focusTimer.restart();
        }
    }


    readonly property int activeMenuHeight: {
        if (activeFilter === "Apps") return appGrid.contentHeight;
        if (activeFilter === "Clipboard") return clipboardView.contentHeight;
        if (activeFilter === "Files") return filesView.contentHeight;
        if (activeFilter === "Web") return webView.contentHeight;
        if (searchValue !== "") return resultsContainer.contentHeightPixels;
        return 0;
    }

    property int contentWidth: 768
    width: contentWidth + (padding * 2)
    property int padding: 40
    height: searchBarContainer.height + (padding * 2)

    opacity: 0.0
    property bool wasOpen: false

    transform: [
        Scale {
            id: barScale
            origin.x: root.width / 2
            origin.y: root.height / 2
            xScale: 0.01
            yScale: 0.01
        }
    ]

    state: root.isOpen ? "open" : "closed"
    states: [
        State {
            name: "open"
            PropertyChanges { target: barScale; xScale: 1.0; yScale: 1.0 }
            PropertyChanges { target: root; opacity: 1.0 }
        },
        State {
            name: "closed"
            PropertyChanges { target: barScale; xScale: 0.01; yScale: 0.01 }
            PropertyChanges { target: root; opacity: 0.0 }
        }
    ]
    transitions: [
        // Opening animation: 200ms myBezier
        Transition {
            from: "closed"; to: "open"
            ParallelAnimation {
                NumberAnimation {
                    target: root
                    property: "opacity"
                    duration: 200
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: root.myBezier
                }
                NumberAnimation {
                    target: barScale
                    properties: "xScale,yScale"
                    duration: 200
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: root.myBezier
                }
            }
        },
        // Closing animation: exact 200ms reverse of opening
        Transition {
            from: "open"; to: "closed"
            SequentialAnimation {
                ParallelAnimation {
                    NumberAnimation {
                        target: root
                        property: "opacity"
                        duration: 200
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: root.reverseMyBezier
                    }
                    NumberAnimation {
                        target: barScale
                        properties: "xScale,yScale"
                        duration: 200
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: root.reverseMyBezier
                    }
                }
                ScriptAction {
                    script: root.resetState()
                }
            }
        }
    ]

    function resetState() {
        hoverDwellTimer.stop();
        root.hovered = false;
        root.activeFilter = "";
        root.searchValue = "";
        textInput.text = "";
        root.hoveredShortcut = -1;
        root.hoveredResult = -1;
        root.searchResults = [];
    }

    Timer {
        id: focusTimer
        interval: 100
        onTriggered: textInput.forceActiveFocus()
    }

    Timer {
        id: hoverDwellTimer
        interval: 150
        repeat: false
        onTriggered: {
            if (barHoverHandler.hovered) {
                root.hovered = true;
            }
        }
    }

    onIsOpenChanged: {
        if (isOpen) {
            wasOpen = true;
            focusTimer.start();
        } else {
            hoverDwellTimer.stop();
        }
    }

    property var pendingAsyncResults: []

    Timer {
        id: batchFlushTimer
        interval: 35
        repeat: false
        onTriggered: root.flushAsyncResults()
    }

    function flushAsyncResults() {
        if (root.pendingAsyncResults.length === 0) return;
        let current = root.searchResults.slice();
        let existingIds = {};
        for (let i = 0; i < current.length; i++) {
            existingIds[current[i].id] = true;
        }
        let added = false;
        for (let j = 0; j < root.pendingAsyncResults.length; j++) {
            let item = root.pendingAsyncResults[j];
            if (!existingIds[item.id]) {
                existingIds[item.id] = true;
                current.push(item);
                added = true;
            }
        }
        root.pendingAsyncResults = [];
        if (added) {
            current.sort((a, b) => {
                let pA = a.priority !== undefined ? a.priority : 1;
                let pB = b.priority !== undefined ? b.priority : 1;
                if (pA !== pB) return pA - pB;
                return 0;
            });
            root.searchResults = current;
            if (root.hoveredResult < 0 && root.searchResults.length > 0) {
                root.hoveredResult = 0;
            }
        }
    }

    onSearchValueChanged: {
        if (activeFilter !== "") {
            return;
        }
        if (!searchValue || searchValue.trim() === "") {
            searchDebounce.stop();
            batchFlushTimer.stop();
            pendingAsyncResults = [];
            webProcess.running = false;
            filesProcess.running = false;
            clipboardProcess.running = false;
            searchResults = [];
            root.hoveredResult = -1;
            return;
        }
        searchDebounce.restart();
    }

    Timer {
        id: searchDebounce
        interval: 140
        onTriggered: root.doSearch()
    }

    Process {
        id: webProcess
        stdout: SplitParser {
            onRead: function(line) {
                let trimmed = line.trim();
                if (trimmed !== "") {
                    try {
                        let item = JSON.parse(trimmed);
                        root.pendingAsyncResults.push({
                            action: "web",
                            id: item.id,
                            label: item.label,
                            description: item.description,
                            icon: item.icon || "󰖟",
                            query: item.query || item.label,
                            badge: item.badge || "Web",
                            priority: item.priority !== undefined ? item.priority : 3
                        });
                        batchFlushTimer.restart();
                    } catch(e) {}
                }
            }
        }
        onExited: root.flushAsyncResults()
    }

    Process {
        id: filesProcess
        stdout: SplitParser {
            onRead: function(line) {
                let trimmed = line.trim();
                if (trimmed !== "") {
                    try {
                        let item = JSON.parse(trimmed);
                        root.pendingAsyncResults.push({
                            action: "file",
                            id: item.id,
                            label: item.label,
                            description: item.description,
                            icon: item.icon,
                            path: item.path,
                            badge: "File",
                            priority: 4
                        });
                        batchFlushTimer.restart();
                    } catch(e) {}
                }
            }
        }
        onExited: root.flushAsyncResults()
    }

    Process {
        id: clipboardProcess
        stdout: SplitParser {
            onRead: function(line) {
                let trimmed = line.trim();
                if (trimmed !== "") {
                    let tabIdx = trimmed.indexOf('\t');
                    let idPart = tabIdx !== -1 ? trimmed.substring(0, tabIdx).trim() : trimmed;
                    let decoded = tabIdx !== -1 ? trimmed.substring(tabIdx + 1) : trimmed;
                    root.pendingAsyncResults.push({
                        action: "command",
                        id: "clip_" + idPart,
                        label: decoded,
                        description: "Clipboard",
                        icon: "󰅌",
                        command: "echo -n '" + idPart + "' | cliphist decode | wl-copy",
                        badge: "Clip",
                        priority: 5
                    });
                    batchFlushTimer.restart();
                }
            }
        }
        onExited: root.flushAsyncResults()
    }

    function doSearch() {
        let q = searchValue.trim();
        if (q === "") return;

        batchFlushTimer.stop();
        pendingAsyncResults = [];
        webProcess.running = false;
        filesProcess.running = false;
        clipboardProcess.running = false;

        let res = [];
        if (q.startsWith(">")) {
            let cmd = q.substring(1).trim();
            if (cmd.length > 0) res.push({ action: "command", id: "cmd", label: cmd, description: "Run Command", icon: "󰆍", command: cmd, badge: "Cmd", priority: 0 });
            searchResults = res;
            root.hoveredResult = res.length > 0 ? 0 : -1;
            return;
        }
        try {
            if (/^[\d\s\+\-\*\/\(\)\.]+$/.test(q) && q.match(/[\+\-\*\/]/)) {
                let result = eval(q);
                if (result !== undefined && !isNaN(result)) res.push({ action: "none", id: "math", label: String(result), description: "Calculator", icon: "󰪚", badge: "Calc", priority: 0 });
            }
        } catch(e) {}

        let filter = root.activeFilter;

        if (filter === "Apps" || filter === "") {
            let apps = (DesktopEntries && DesktopEntries.applications && DesktopEntries.applications.values)
                ? DesktopEntries.applications.values : [];
            let matches = Semantic.searchApps(q, apps, 4, 4);
            for (let i = 0; i < matches.length; i++) {
                let m = matches[i];
                let app = m.app;
                res.push({
                    action: "app",
                    id: "app_" + app.id,
                    label: app.name,
                    description: m.description,
                    iconPath: Quickshell.iconPath(app.icon, true) || "",
                    appRef: app,
                    badge: m.badge || (m.priority === 2 ? "Related" : "App"),
                    priority: m.priority !== undefined ? m.priority : 1
                });
            }
        }

        if (filter === "Web" || filter === "") {
            res.push({
                action: "web",
                id: "web_search_query",
                label: `Search Google for "${q}"`,
                description: "Open in Google Chrome",
                icon: "󰖟",
                query: q,
                badge: "Web",
                priority: 6
            });
        }
        searchResults = res;
        root.hoveredResult = res.length > 0 ? 0 : -1;

        if ((filter === "" || filter === "Web") && q.length >= 2) {
            webProcess.command = [Paths.script("web-search.py"), "search", q, "3"];
            webProcess.running = true;
        }

        if (filter === "" && q.length >= 2) {
            filesProcess.command = [Paths.script("file-search.py"), "search", "all", q, "6"];
            filesProcess.running = true;
        }

        if (filter === "Clipboard" || (filter === "" && q.length >= 2)) {
            let safeQ = q.replace(/"/g, '\\"');
            clipboardProcess.command = ["sh", "-c", 'cliphist list | grep -i "' + safeQ + '" | head -n 6'];
            clipboardProcess.running = true;
        }
    }


    MouseArea {
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.AllButtons
        onPressed: function(mouse) { mouse.accepted = true }
        onClicked: function(mouse) { mouse.accepted = true }
    }

    Item {
        id: gooeyContainer
        width: parent.width
        height: parent.height
        x: 0
        y: 0

        // === FOREGROUND LIQUID GLASS CONTENT ===
        Row {
            id: foregroundRow
            width: root.contentWidth
            height: searchBarContainer.height
            anchors.centerIn: parent
            layoutDirection: Qt.LeftToRight
            spacing: 16

            HoverHandler {
                id: barHoverHandler
                onHoveredChanged: {
                    if (hovered) {
                        hoverDwellTimer.restart();
                    } else {
                        hoverDwellTimer.stop();
                        root.hovered = false;
                        root.hoveredShortcut = -1;
                    }
                }
            }

            LiquidGlassBackground {
                id: searchBarContainer
                z: 2
                width: root.contentWidth - (root.showShortcuts ? (root.shortcuts.length * 80) : 0)
                height: 64 + root.activeMenuHeight
                radius: 30
                baseColor: Theme.cardIdleColor
                borderColor: Theme.cardBorderColor
                borderWidth: 1.2
                specularScale: 1.0
                clipContent: true

                Behavior on width {
                    enabled: root.isOpen
                    NumberAnimation {
                        duration: root.showShortcuts ? 455 : 240
                        easing.type: Easing.OutCubic
                    }
                }
                Behavior on height {
                    enabled: root.isOpen
                    NumberAnimation {
                        duration: searchBarContainer.height > 64 ? 280 : 220
                        easing.type: Easing.OutCubic
                    }
                }

                Item {
                    id: searchInput
                    width: parent.width
                    height: 64
                    
                    Text {
                        id: searchIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            if (root.activeFilter === "Apps") return "󰕰";
                            if (root.activeFilter === "Files") return "󰉋";
                            if (root.activeFilter === "Clipboard") return "󰈔";
                            if (root.activeFilter === "Web") return "󰖟";
                            return "󰍉";
                        }
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 24
                        color: root.activeFilter !== "" ? "#38bdf8" : "#cbd5e1"
                    }

                    Rectangle {
                        id: clearFilterBtn
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        width: 28
                        height: 28
                        radius: 14
                        antialiasing: true
                        color: clearFilterMouse.containsMouse ? "#50ffffff" : "#25ffffff"
                        border.color: Theme.cardBorderColor
                        border.width: 1
                        visible: root.activeFilter !== ""

                        Behavior on color { ColorAnimation { duration: 150 } }

                        Text {
                            anchors.centerIn: parent
                            text: "󰅖"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 15
                            color: "#ffffff"
                        }

                        MouseArea {
                            id: clearFilterMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.activeFilter = "";
                                root.searchValue = "";
                                textInput.text = "";
                            }
                        }
                    }

                    Item {
                        anchors.left: searchIcon.right
                        anchors.leftMargin: 8
                        anchors.right: root.activeFilter !== "" ? clearFilterBtn.left : parent.right
                        anchors.rightMargin: root.activeFilter !== "" ? 8 : 24
                        height: parent.height
                        
                        Text {
                            id: placeholderText
                            anchors.verticalCenter: parent.verticalCenter
                            
                            text: {
                                if (root.hoveredShortcut >= 0 && root.hoveredShortcut < root.shortcuts.length) return "Search " + root.shortcuts[root.hoveredShortcut].label;
                                if (root.activeFilter === "Apps") return "Search applications...";
                                if (root.activeFilter === "Files") return "Search files (" + (filesView.activeDriveLabel || "All Drives") + ")...";
                                if (root.activeFilter === "Clipboard") return "Search clipboard history...";
                                if (root.activeFilter === "Web") return "Search web with Chrome...";
                                return "Search";
                            }
                            
                            color: "#94a3b8"
                            font.family: "SF Pro Text"
                            font.pixelSize: 24
                            opacity: (root.searchValue.length === 0 || root.hoveredShortcut >= 0) ? 1.0 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
                        }

                        TextInput {
                            id: textInput
                            anchors.fill: parent
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: "SF Pro Text"
                            font.pixelSize: 24
                            color: "#ffffff"
                            opacity: text.length > 0 ? 1.0 : 0.0
                            onTextChanged: root.searchValue = text
                            function handleActivate(isAlt) {
                                if (root.activeFilter === "Apps") {
                                    appGrid.launchSelected();
                                } else if (root.activeFilter === "Clipboard") {
                                    clipboardView.copySelected();
                                } else if (root.activeFilter === "Files") {
                                    filesView.openSelected(isAlt);
                                } else if (root.activeFilter === "Web") {
                                    webView.openSelected();
                                } else if (root.hoveredResult >= 0 && root.hoveredResult < root.searchResults.length) {
                                    resultsContainer.resultClicked(root.searchResults[root.hoveredResult], isAlt);
                                } else if (root.searchResults.length > 0) {
                                    resultsContainer.resultClicked(root.searchResults[0], isAlt);
                                }
                            }

                            Keys.onPressed: function(event) {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    let isAlt = (event.modifiers & Qt.AltModifier) !== 0;
                                    textInput.handleActivate(isAlt);
                                    event.accepted = true;
                                    return;
                                }
                                if ((event.modifiers & Qt.MetaModifier) !== 0 || textInput.text.length === 0) {
                                    if (event.key === Qt.Key_1) { root.activateShortcut(0); event.accepted = true; return; }
                                    if (event.key === Qt.Key_2) { root.activateShortcut(1); event.accepted = true; return; }
                                    if (event.key === Qt.Key_3) { root.activateShortcut(2); event.accepted = true; return; }
                                    if (event.key === Qt.Key_4) { root.activateShortcut(3); event.accepted = true; return; }
                                }
                                if (event.key === Qt.Key_Tab && root.activeFilter === "Files") {
                                    filesView.cycleDrive();
                                    event.accepted = true;
                                    return;
                                }
                            }
                            Keys.onEscapePressed: function(event) {
                                root.closeRequested();
                                event.accepted = true;
                            }
                            Keys.onUpPressed: {
                                if (root.activeFilter === "Apps") {
                                    appGrid.moveSelection(0, -1);
                                } else if (root.activeFilter === "Clipboard") {
                                    clipboardView.moveSelection(-1);
                                } else if (root.activeFilter === "Files") {
                                    filesView.moveSelection(-1);
                                } else if (root.activeFilter === "Web") {
                                    webView.moveSelection(-1);
                                } else if (root.searchResults.length > 0) {
                                    root.hoveredResult = root.hoveredResult <= 0 ? root.searchResults.length - 1 : root.hoveredResult - 1;
                                }
                            }
                            Keys.onDownPressed: {
                                if (root.activeFilter === "Apps") {
                                    appGrid.moveSelection(0, 1);
                                } else if (root.activeFilter === "Clipboard") {
                                    clipboardView.moveSelection(1);
                                } else if (root.activeFilter === "Files") {
                                    filesView.moveSelection(1);
                                } else if (root.activeFilter === "Web") {
                                    webView.moveSelection(1);
                                } else if (root.searchResults.length > 0) {
                                    root.hoveredResult = root.hoveredResult >= root.searchResults.length - 1 ? 0 : root.hoveredResult + 1;
                                }
                            }
                            Keys.onLeftPressed: {
                                if (root.activeFilter === "Apps" && textInput.cursorPosition === 0) {
                                    appGrid.moveSelection(-1, 0);
                                }
                            }
                            Keys.onRightPressed: {
                                if (root.activeFilter === "Apps" && textInput.cursorPosition === textInput.text.length) {
                                    appGrid.moveSelection(1, 0);
                                }
                            }
                            Keys.onReturnPressed: function(event) {
                                let isAlt = (event.modifiers & Qt.AltModifier) !== 0;
                                textInput.handleActivate(isAlt);
                            }
                            Keys.onEnterPressed: function(event) {
                                let isAlt = (event.modifiers & Qt.AltModifier) !== 0;
                                textInput.handleActivate(isAlt);
                            }
                        }
                    }
                }

                SpotlightAppGrid {
                    id: appGrid
                    anchors.top: searchInput.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    opacity: root.activeFilter === "Apps" ? 1.0 : 0.0
                    visible: root.activeFilter === "Apps" || opacity > 0.01
                    transform: Translate {
                        y: root.activeFilter === "Apps" ? 0 : 8
                        Behavior on y { enabled: root.isOpen; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    }
                    Behavior on opacity { enabled: root.isOpen; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    filterQuery: root.activeFilter === "Apps" ? root.searchValue : ""
                    onAppLaunched: root.closeRequested()
                }

                SpotlightFiles {
                    id: filesView
                    anchors.top: searchInput.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    opacity: root.activeFilter === "Files" ? 1.0 : 0.0
                    visible: root.activeFilter === "Files" || opacity > 0.01
                    transform: Translate {
                        y: root.activeFilter === "Files" ? 0 : 8
                        Behavior on y { enabled: root.isOpen; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    }
                    Behavior on opacity { enabled: root.isOpen; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    filterQuery: root.activeFilter === "Files" ? root.searchValue : ""
                    onFileOpened: root.closeRequested()
                }

                SpotlightClipboard {
                    id: clipboardView
                    anchors.top: searchInput.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    opacity: root.activeFilter === "Clipboard" ? 1.0 : 0.0
                    visible: root.activeFilter === "Clipboard" || opacity > 0.01
                    transform: Translate {
                        y: root.activeFilter === "Clipboard" ? 0 : 8
                        Behavior on y { enabled: root.isOpen; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    }
                    Behavior on opacity { enabled: root.isOpen; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    filterQuery: root.activeFilter === "Clipboard" ? root.searchValue : ""
                    onItemCopied: root.closeRequested()
                }

                SpotlightWeb {
                    id: webView
                    anchors.top: searchInput.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    opacity: root.activeFilter === "Web" ? 1.0 : 0.0
                    visible: root.activeFilter === "Web" || opacity > 0.01
                    transform: Translate {
                        y: root.activeFilter === "Web" ? 0 : 8
                        Behavior on y { enabled: root.isOpen; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    }
                    Behavior on opacity { enabled: root.isOpen; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    filterQuery: root.activeFilter === "Web" ? root.searchValue : ""
                    onSearchExecuted: root.closeRequested()
                }

                SpotlightResults {
                    id: resultsContainer
                    anchors.top: searchInput.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    visible: root.activeFilter === "" && root.searchValue !== ""
                    transform: Translate {
                        y: (root.activeFilter === "" && root.searchValue !== "") ? 0 : 8
                        Behavior on y { enabled: root.isOpen; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    }
                    opacity: (root.activeFilter === "" && root.searchValue !== "") ? 1.0 : 0.0
                    Behavior on opacity { enabled: root.isOpen; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    results: root.searchResults
                    selectedIndex: root.hoveredResult
                    onResultHovered: function(idx) { root.hoveredResult = idx; }
                    onResultUnhovered: function() { }
                    onResultClicked: function(result, isTerminal) {
                        if (result.action === "app") {
                            result.appRef.execute();
                        } else if (result.action === "command") {
                            root.runCommand(result.command);
                        } else if (result.action === "file") {
                            root.runCommand(Paths.script("file-open.sh") + " " + (isTerminal ? "terminal" : "open") + " '" + result.path.replace(/'/g, "'\\''") + "'");
                        } else if (result.action === "web") {
                            root.runCommand(Paths.script("web-open.sh") + " '" + (result.query || result.label).replace(/'/g, "'\\''") + "'");
                        }
                        root.closeRequested();
                    }
                }

            }

            Repeater {
                model: root.shortcuts

                Item {
                    z: 1
                    width: root.showShortcuts ? 64 : 0
                    height: 64
                    visible: root.showShortcuts || realBubble.opacity > 0.01
                    Behavior on width { enabled: root.isOpen; NumberAnimation { duration: root.showShortcuts ? 490 : 140; easing.type: Easing.OutCubic } }

                    LiquidGlassBackground {
                        id: realBubble
                        width: 64
                        height: 64
                        radius: 32
                        baseColor: root.activeFilter === modelData.label 
                            ? Qt.rgba(1.0, 1.0, 1.0, 0.40) 
                            : (shortcutMouse.containsMouse ? Qt.rgba(1.0, 1.0, 1.0, 0.28) : Theme.cardIdleColor)
                        borderColor: root.activeFilter === modelData.label
                            ? Qt.rgba(1.0, 1.0, 1.0, 0.45)
                            : Theme.cardBorderColor
                        borderWidth: 1.2
                        specularScale: 0.8
                        
                        property real startX: -64 * (index + 1)
                        
                        x: startX
                        scale: 0.7
                        opacity: 0.0

                        state: root.showShortcuts ? "hovered" : "unhovered"
                        states: [
                            State { name: "hovered"; PropertyChanges { target: realBubble; x: 0; scale: 1.0; opacity: 1.0 } },
                            State { name: "unhovered"; PropertyChanges { target: realBubble; x: 0; scale: 0.7; opacity: 0.0 } }
                        ]
                        transitions: [
                            Transition {
                                from: "unhovered"; to: "hovered"
                                SequentialAnimation {
                                    PropertyAction { target: realBubble; property: "x"; value: realBubble.startX }
                                    PropertyAction { target: realBubble; property: "scale"; value: 0.7 }
                                    PropertyAction { target: realBubble; property: "opacity"; value: 1.0 }
                                    PauseAnimation { duration: index * 50 }
                                    ParallelAnimation {
                                        NumberAnimation { target: realBubble; property: "x"; duration: 665; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                        NumberAnimation { target: realBubble; property: "scale"; duration: 665; easing.type: Easing.BezierSpline; easing.bezierCurve: root.springCurve }
                                    }
                                }
                            },
                            Transition {
                                from: "hovered"; to: "unhovered"
                                ParallelAnimation {
                                    NumberAnimation { target: realBubble; property: "scale"; to: 0.6; duration: 140; easing.type: Easing.OutQuad }
                                    NumberAnimation { target: realBubble; property: "opacity"; to: 0.0; duration: 140; easing.type: Easing.OutQuad }
                                }
                            }
                        ]

                        Text {
                            anchors.centerIn: parent
                            text: modelData.icon
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 28
                            color: "#ffffff"
                            opacity: shortcutMouse.containsMouse || root.activeFilter === modelData.label ? 1.0 : 0.70
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }

                        MouseArea {
                            id: shortcutMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: root.hoveredShortcut = index
                            onExited: {
                                if (root.hoveredShortcut === index)
                                    root.hoveredShortcut = -1
                            }
                            onClicked: {
                                root.activateShortcut(index);
                            }
                        }
                    }
                }
            }
        }
    }
}
