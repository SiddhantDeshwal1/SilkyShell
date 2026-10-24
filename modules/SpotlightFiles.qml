import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
    id: root

    property string filterQuery: ""
    property string activeDrive: "all"
    property string activeDriveLabel: "All Drives"
    property int selectedIndex: 0
    property int contentHeight: 450
    height: contentHeight
    clip: true

    signal fileOpened(string path)

    property var drives: [
        { id: "all", label: "All Drives", icon: "󰉉" },
        { id: "os", label: "OS (Home)", icon: "󰋊" },
        { id: "alpha", label: "Alpha", icon: "󱛟" }
    ]

    property var fileItems: []
    property var pendingItems: []
    property bool isSearching: false

    function setActiveDrive(driveId) {
        if (root.activeDrive === driveId) return;
        root.activeDrive = driveId;
        for (let i = 0; i < root.drives.length; i++) {
            if (root.drives[i].id === driveId) {
                root.activeDriveLabel = root.drives[i].label;
                break;
            }
        }
        root.reload();
    }

    function cycleDrive() {
        for (let i = 0; i < root.drives.length; i++) {
            if (root.drives[i].id === root.activeDrive) {
                let next = (i + 1) % root.drives.length;
                root.setActiveDrive(root.drives[next].id);
                return;
            }
        }
        root.setActiveDrive("all");
    }

    Timer {
        id: searchDebounce
        interval: 110
        onTriggered: root.reload()
    }

    onFilterQueryChanged: {
        if (root.visible) searchDebounce.restart();
    }

    onVisibleChanged: {
        if (visible) {
            root.loadDrives();
            root.reload();
            selectedIndex = 0;
            if (listView) listView.positionViewAtIndex(0, ListView.Beginning);
        }
    }

    Component.onCompleted: {
        root.loadDrives();
    }

    Process {
        id: drivesProc
        command: [Paths.script("file-search.py"), "drives"]
        stdout: SplitParser {
            onRead: function(line) {
                try {
                    let parsed = JSON.parse(line.trim());
                    if (Array.isArray(parsed) && parsed.length > 0) {
                        let mapped = [];
                        for (let i = 0; i < parsed.length; i++) {
                            let d = parsed[i];
                            let icon = "󰉉";
                            if (d.id === "os") icon = "󰋊";
                            else if (d.id === "alpha") icon = "󱛟";
                            mapped.push({ id: d.id, label: d.label, icon: icon });
                        }
                        root.drives = mapped;
                    }
                } catch(e) {}
            }
        }
    }

    function loadDrives() {
        drivesProc.running = false;
        drivesProc.running = true;
    }

    Process {
        id: fileListProc
        stdout: SplitParser {
            onRead: function(line) {
                let trimmed = line.trim();
                if (trimmed !== "") {
                    try {
                        let item = JSON.parse(trimmed);
                        root.pendingItems.push(item);
                    } catch(e) {}
                }
            }
        }
        onExited: {
            root.fileItems = root.pendingItems;
            root.pendingItems = [];
            root.isSearching = false;
            if (root.selectedIndex >= root.fileItems.length) {
                root.selectedIndex = Math.max(0, root.fileItems.length - 1);
            }
        }
    }

    function reload() {
        fileListProc.running = false;
        root.pendingItems = [];
        root.isSearching = true;

        let q = filterQuery.trim();
        if (q === "") {
            // Show recent documents
            fileListProc.command = [
                Paths.script("file-search.py"),
                "recent",
                root.activeDrive,
                "12"
            ];
        } else {
            // Search files via fd
            fileListProc.command = [
                Paths.script("file-search.py"),
                "search",
                root.activeDrive,
                q,
                "12"
            ];
        }
        fileListProc.running = true;
    }

    function moveSelection(delta) {
        if (fileItems.length === 0) return;
        let nextIdx = selectedIndex + delta;
        if (nextIdx < 0) nextIdx = fileItems.length - 1;
        if (nextIdx >= fileItems.length) nextIdx = 0;
        selectedIndex = nextIdx;
        listView.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    Process { id: openProc }
    function openSelected(isTerminal) {
        if (selectedIndex >= 0 && selectedIndex < fileItems.length) {
            let item = fileItems[selectedIndex];
            openItem(item, isTerminal);
        }
    }

    function openItem(item, isTerminal) {
        let action = isTerminal ? "terminal" : "open";
        openProc.running = false;
        openProc.command = [Paths.script("file-open.sh"), action, item.path];
        openProc.running = true;
        root.fileOpened(item.path);
    }

    Rectangle {
        id: topDivider
        width: parent.width
        height: 1
        color: Theme.cardBorderColor
        anchors.top: parent.top
    }

    // Drive selector tabs
    Item {
        id: driveBar
        anchors.top: topDivider.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 44

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 8

            Text {
                text: root.filterQuery.trim() === "" ? "Recent in:" : "Search in:"
                font.family: "SF Pro Text"
                font.pixelSize: 13
                font.bold: true
                color: "#94a3b8"
                Layout.alignment: Qt.AlignVCenter
            }

            Repeater {
                model: root.drives

                Rectangle {
                    required property int index
                    required property var modelData
                    Layout.preferredHeight: 28
                    Layout.preferredWidth: pillText.implicitWidth + 24
                    radius: 14
                    antialiasing: true

                    color: root.activeDrive === modelData.id
                        ? (Theme.darkMode ? "#4038bdf8" : "#300284c7")
                        : (pillMouse.containsMouse ? "#20ffffff" : "transparent")
                    border.color: root.activeDrive === modelData.id
                        ? "#38bdf8"
                        : (pillMouse.containsMouse ? Theme.cardBorderColor : "#15ffffff")
                    border.width: 1

                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    RowLayout {
                        id: pillText
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: modelData.icon
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 14
                            color: root.activeDrive === modelData.id ? "#38bdf8" : "#cbd5e1"
                        }

                        Text {
                            text: modelData.label
                            font.family: "SF Pro Text"
                            font.pixelSize: 13
                            font.bold: root.activeDrive === modelData.id
                            color: root.activeDrive === modelData.id ? "#ffffff" : "#cbd5e1"
                        }
                    }

                    MouseArea {
                        id: pillMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setActiveDrive(modelData.id)
                    }
                }
            }

            Item { Layout.fillWidth: true }

            Text {
                text: root.filterQuery.trim() === "" ? "Recent Documents" : (root.fileItems.length + " found")
                font.family: "SF Pro Text"
                font.pixelSize: 12
                color: "#64748b"
                Layout.alignment: Qt.AlignVCenter
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: "#15ffffff"
        }
    }

    // Results ListView
    ListView {
        id: listView
        anchors.top: driveBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        clip: true
        model: root.fileItems
        boundsBehavior: Flickable.StopAtBounds

        // Empty state
        Item {
            anchors.centerIn: parent
            width: parent.width - 32
            height: 120
            visible: root.fileItems.length === 0 && !root.isSearching

            Column {
                anchors.centerIn: parent
                spacing: 8

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.filterQuery.trim() === "" ? "󰈔" : "󰍉"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 32
                    color: "#64748b"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.filterQuery.trim() === ""
                        ? "No recent documents on " + root.activeDriveLabel
                        : "No matching files on " + root.activeDriveLabel
                    font.family: "SF Pro Text"
                    font.pixelSize: 15
                    color: "#94a3b8"
                }
            }
        }

        delegate: Item {
            id: fileDelegate
            required property int index
            required property var modelData

            width: listView.width - 16
            x: 8
            height: 56

            Rectangle {
                anchors.fill: parent
                radius: 12
                color: root.selectedIndex === index
                    ? (Theme.darkMode ? "#30ffffff" : "#40ffffff")
                    : (delegateMouse.containsMouse ? "#18ffffff" : "transparent")
                border.width: root.selectedIndex === index ? 1 : 0
                border.color: Theme.cardBorderColor
                antialiasing: true

                Behavior on color { ColorAnimation { duration: 90 } }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 12

                    // File icon tile
                    Rectangle {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        radius: 10
                        color: Theme.darkMode ? "#22ffffff" : Qt.rgba(1.0, 1.0, 1.0, 0.35)
                        border.color: Theme.cardBorderColor
                        border.width: 1
                        antialiasing: true

                        Text {
                            anchors.centerIn: parent
                            text: modelData.icon || "󰈔"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 22
                            color: {
                                if (modelData.icon === "󰈦") return "#f87171"; // PDF red
                                if (modelData.icon === "󰈟") return "#38bdf8"; // Image blue
                                if (modelData.icon === "󰕼") return "#a855f7"; // Video purple
                                if (modelData.icon === "󰎆") return "#ec4899"; // Audio pink
                                if (modelData.icon === "󰅩") return "#34d399"; // Code green
                                if (modelData.icon === "󰛫") return "#fbbf24"; // Archive amber
                                if (modelData.icon === "󰉋") return "#f59e0b"; // Folder amber
                                return "#ffffff";
                            }
                        }
                    }

                    // Filename & path
                    Column {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            text: modelData.label
                            font.family: "SF Pro Text"
                            font.bold: true
                            font.pixelSize: 15
                            color: "#ffffff"
                            elide: Text.ElideMiddle
                            width: parent.width
                        }

                        Text {
                            text: modelData.description
                            font.family: "SF Pro Text"
                            font.pixelSize: 12
                            color: "#94a3b8"
                            elide: Text.ElideMiddle
                            width: parent.width
                        }
                    }

                    // Drive badge
                    Rectangle {
                        Layout.preferredHeight: 22
                        Layout.preferredWidth: driveBadgeText.implicitWidth + 14
                        radius: 11
                        color: modelData.drive === "Alpha" ? "#25a855f7" : "#2038bdf8"
                        border.color: modelData.drive === "Alpha" ? "#60a855f7" : "#5038bdf8"
                        border.width: 1
                        antialiasing: true

                        Text {
                            id: driveBadgeText
                            anchors.centerIn: parent
                            text: modelData.drive || "OS"
                            font.family: "SF Pro Text"
                            font.bold: true
                            font.pixelSize: 11
                            color: modelData.drive === "Alpha" ? "#c084fc" : "#7dd3fc"
                        }
                    }
                }

                MouseArea {
                    id: delegateMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selectedIndex = index
                    onClicked: function(mouse) {
                        let isAlt = (mouse.modifiers & Qt.AltModifier) !== 0;
                        root.openItem(modelData, isAlt);
                    }
                }
            }
        }
    }
}
