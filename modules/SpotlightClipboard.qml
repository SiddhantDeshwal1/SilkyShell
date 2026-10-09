import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
    id: root

    property string filterQuery: ""
    property int selectedIndex: 0
    property int contentHeight: 450
    height: contentHeight
    signal itemCopied()

    property var clipboardItems: []

    Timer {
        id: searchDebounce
        interval: 100
        onTriggered: root.reload()
    }

    onFilterQueryChanged: {
        if (root.visible) searchDebounce.restart();
    }

    onVisibleChanged: {
        if (visible) {
            root.reload();
            selectedIndex = 0;
            if (listView) listView.positionViewAtIndex(0, ListView.Beginning);
        }
    }

    property var pendingLines: []

    Process {
        id: clipListProcess
        stdout: SplitParser {
            onRead: function(line) {
                if (line.trim() !== "") {
                    let tabIdx = line.indexOf('\t');
                    let id = tabIdx !== -1 ? line.substring(0, tabIdx).trim() : line.trim();
                    let text = tabIdx !== -1 ? line.substring(tabIdx + 1) : "";
                    let type = "text";
                    let trimmed = text.trim();
                    if (trimmed.startsWith("http://") || trimmed.startsWith("https://") || trimmed.startsWith("www.")) {
                        type = "url";
                    } else if (trimmed.startsWith("sudo ") || trimmed.startsWith("git ") || trimmed.startsWith("cd ") ||
                               trimmed.startsWith("ls ") || trimmed.startsWith("npm ") || trimmed.startsWith("nix ") ||
                               trimmed.startsWith("cargo ") || trimmed.startsWith("curl ") || trimmed.startsWith("docker ")) {
                        type = "cmd";
                    }
                    root.pendingLines.push({ id: id, text: text, type: type });
                }
            }
        }
        onExited: {
            root.clipboardItems = root.pendingLines;
            root.pendingLines = [];
            if (root.selectedIndex >= root.clipboardItems.length)
                root.selectedIndex = Math.max(0, root.clipboardItems.length - 1);
        }
    }

    Process {
        id: clipActionProcess
        onExited: {
            root.reload();
        }
    }

    function runShell(cmd) {
        clipActionProcess.command = ["sh", "-c", cmd];
        clipActionProcess.running = true;
    }

    function reload() {
        clipListProcess.running = false;
        root.pendingLines = [];
        let safeQ = filterQuery.trim().replace(/"/g, '\\"');
        if (safeQ === "") {
            clipListProcess.command = ["sh", "-c", "cliphist list | head -n 40"];
        } else {
            clipListProcess.command = ["sh", "-c", 'cliphist list | grep -i "' + safeQ + '" | head -n 40'];
        }
        clipListProcess.running = true;
    }

    function copyItem(item) {
        runShell("echo -n '" + item.id + "' | cliphist decode | wl-copy");
        root.itemCopied();
    }

    function deleteItem(item, idx) {
        runShell("echo -n '" + item.id + "\t" + item.text.replace(/'/g, "'\\''") + "' | cliphist delete");
        let tmp = root.clipboardItems.slice();
        tmp.splice(idx, 1);
        root.clipboardItems = tmp;
    }

    function clearAll() {
        runShell("cliphist wipe");
        root.clipboardItems = [];
    }

    readonly property real totalContentHeight: clipboardItems.length * (60 + listView.spacing)
    property real targetContentY: 0

    function smoothScrollBy(deltaY) {
        let step = -(deltaY / 120.0) * 110;
        let maxScroll = Math.max(0, totalContentHeight - listView.height);
        if (!scrollAnim.running) {
            targetContentY = listView.contentY;
        }
        targetContentY = Math.max(0, Math.min(maxScroll, targetContentY + step));
        scrollAnim.to = targetContentY;
        scrollAnim.restart();
    }

    WheelHandler {
        id: wheelHandler
        target: null
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function(event) {
            if (event.pixelDelta.y !== 0) {
                let maxScroll = Math.max(0, root.totalContentHeight - listView.height);
                let target = Math.max(0, Math.min(maxScroll, listView.contentY - event.pixelDelta.y));
                listView.contentY = target;
                root.targetContentY = target;
            } else if (event.angleDelta.y !== 0) {
                root.smoothScrollBy(event.angleDelta.y);
            }
        }
    }

    function moveSelection(dy) {
        if (clipboardItems.length === 0) return;
        let nextIdx = selectedIndex + dy;
        if (nextIdx < 0) nextIdx = 0;
        if (nextIdx >= clipboardItems.length) nextIdx = clipboardItems.length - 1;
        selectedIndex = nextIdx;

        let itemTop = selectedIndex * (60 + listView.spacing);
        let itemBottom = itemTop + 60;
        if (itemTop < listView.contentY) {
            targetContentY = Math.max(0, itemTop);
            scrollAnim.to = targetContentY;
            scrollAnim.restart();
        } else if (itemBottom > listView.contentY + listView.height) {
            let maxScroll = Math.max(0, totalContentHeight - listView.height);
            targetContentY = Math.min(maxScroll, itemBottom - listView.height);
            scrollAnim.to = targetContentY;
            scrollAnim.restart();
        }
    }

    NumberAnimation {
        id: scrollAnim
        target: listView
        property: "contentY"
        duration: 110
        easing.type: Easing.OutQuad
    }

    function copySelected() {
        if (selectedIndex >= 0 && selectedIndex < clipboardItems.length) {
            copyItem(clipboardItems[selectedIndex]);
        }
    }

    Rectangle {
        id: topDivider
        width: parent.width
        height: 1
        color: Theme.cardBorderColor
        anchors.top: parent.top
    }

    Item {
        id: header
        anchors.top: topDivider.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 38

        Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 20
            spacing: 8

            Text {
                text: "Clipboard History"
                font.family: "SF Pro Text"
                font.pixelSize: 16
                font.bold: true
                color: "#ffffff"
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: countText.width + 14
                height: 20
                radius: 10
                color: "#30ffffff"
                border.width: 1
                border.color: Theme.cardBorderColor

                Text {
                    id: countText
                    anchors.centerIn: parent
                    text: String(root.clipboardItems.length)
                    font.family: "SF Pro Text"
                    font.pixelSize: 13
                    font.bold: true
                    color: "#ffffff"
                }
            }
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 20
            width: clearRow.width + 16
            height: 26
            radius: 13
            color: clearMouse.containsMouse ? "#fee2e2" : "#f3f4f6"
            visible: root.clipboardItems.length > 0

            Behavior on color { ColorAnimation { duration: 150 } }

            Row {
                id: clearRow
                anchors.centerIn: parent
                spacing: 5
                Text {
                    text: "󰃢"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 13
                    color: clearMouse.containsMouse ? "#ef4444" : "#6b7280"
                }
                Text {
                    text: "Clear All"
                    font.family: "SF Pro Text"
                    font.pixelSize: 13
                    font.bold: true
                    color: clearMouse.containsMouse ? "#ef4444" : "#6b7280"
                }
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

    ListView {
        id: listView
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.bottomMargin: 12
        clip: true
        spacing: 4

        model: root.clipboardItems

        Rectangle {
            id: liquidHighlight
            parent: listView.contentItem
            z: 0
            visible: root.clipboardItems.length > 0 && root.selectedIndex >= 0 && root.selectedIndex < root.clipboardItems.length
            width: listView.width
            height: 60
            radius: 12
            color: "#40ffffff"
            border.width: 1
            border.color: "#60ffffff"
            antialiasing: true

            y: root.selectedIndex * (60 + listView.spacing)

            Behavior on y {
                NumberAnimation {
                    duration: 90
                    easing.type: Easing.OutQuad
                }
            }
        }

        delegate: Item {
            id: itemDelegate
            required property int index
            required property var modelData
            z: 1

            width: listView.width
            height: 60

            Item {
                id: card
                anchors.fill: parent

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 12

                    // Type badge
                    Rectangle {
                        Layout.preferredWidth: 38
                        Layout.preferredHeight: 38
                        radius: 10
                        antialiasing: true
                        scale: root.selectedIndex === index ? 1.08 : 1.0
                        Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }
                        color: {
                            if (modelData.type === "url") return "#dbeafe";
                            if (modelData.type === "cmd") return "#d1fae5";
                            return "#f3f4f6";
                        }

                        Text {
                            anchors.centerIn: parent
                            text: {
                                if (modelData.type === "url") return "󰖟";
                                if (modelData.type === "cmd") return "󰆍";
                                return "󰈔";
                            }
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 17
                            color: {
                                if (modelData.type === "url") return "#2563eb";
                                if (modelData.type === "cmd") return "#059669";
                                return "#6b7280";
                            }
                        }
                    }

                    // Content text
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            Layout.fillWidth: true
                            text: modelData.text || ""
                            font.family: modelData.type === "cmd" ? "JetBrainsMono Nerd Font" : "SF Pro Text"
                            font.pixelSize: 15
                            font.bold: false
                            color: "#ffffff"
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }

                        Text {
                            Layout.fillWidth: true
                            text: (modelData.text ? modelData.text.length : 0) + " chars • #" + modelData.id
                            font.family: "SF Pro Text"
                            font.pixelSize: 13
                            color: "#cbd5e1"
                        }
                    }

                    // Quick Actions
                    Row {
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 6
                        opacity: cardMouse.containsMouse || root.selectedIndex === index ? 1.0 : 0.0
                        Behavior on opacity { NumberAnimation { duration: 150 } }

                        Rectangle {
                            width: 30
                            height: 30
                            radius: 8
                            color: copyBtnMouse.containsMouse ? "#40ffffff" : "transparent"
                            Text {
                                anchors.centerIn: parent
                                text: "󰆏"
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 15
                                color: "#ffffff"
                            }
                            MouseArea {
                                id: copyBtnMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.copyItem(modelData)
                            }
                        }

                        Rectangle {
                            width: 30
                            height: 30
                            radius: 8
                            color: delBtnMouse.containsMouse ? "#fee2e2" : "transparent"
                            Text {
                                anchors.centerIn: parent
                                text: "󰩹"
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 15
                                color: delBtnMouse.containsMouse ? "#ef4444" : "#9ca3af"
                            }
                            MouseArea {
                                id: delBtnMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.deleteItem(modelData, index)
                            }
                        }
                    }
                }

                MouseArea {
                    id: cardMouse
                    anchors.fill: parent
                    z: -1
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: {
                        if (root.selectedIndex !== index)
                            root.selectedIndex = index;
                    }
                    onEntered: root.selectedIndex = index
                    onClicked: root.copyItem(modelData)
                }
            }
        }
    }

    Item {
        anchors.fill: parent
        visible: root.clipboardItems.length === 0

        Column {
            anchors.centerIn: parent
            spacing: 10

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "󰈔"
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 36
                color: "#9ca3af"
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "No clipboard history"
                font.family: "SF Pro Text"
                font.pixelSize: 14
                font.bold: true
                color: "#4b5563"
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Copied items will appear here"
                font.family: "SF Pro Text"
                font.pixelSize: 12
                color: "#9ca3af"
            }
        }
    }
}
