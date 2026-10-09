import QtQuick
import QtQuick.Layouts
import Quickshell

Item {
    id: root

    property string filterQuery: ""
    property int selectedIndex: 0
    property int contentHeight: 450
    height: contentHeight
    signal appLaunched()

    property var allApps: []

    function refreshApps() {
        if (!DesktopEntries || !DesktopEntries.applications) return;
        let raw = [...DesktopEntries.applications.values];
        root.allApps = raw.filter(a => a && a.name && a.name.length > 0 && !a.noDisplay);
    }

    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() {
            root.refreshApps();
        }
    }

    onVisibleChanged: {
        if (visible) {
            root.refreshApps();
            selectedIndex = 0;
            if (gridView) gridView.positionViewAtIndex(0, GridView.Beginning);
        }
    }

    Component.onCompleted: {
        root.refreshApps();
    }

    readonly property var appsList: {
        let q = filterQuery.trim().toLowerCase();
        let list = [];
        let source = root.allApps;
        for (let i = 0; i < source.length; i++) {
            let app = source[i];
            if (!app || !app.name) continue;
            if (q === "") {
                list.push(app);
            } else {
                let name = (app.name || "").toLowerCase();
                let comment = (app.comment || "").toLowerCase();
                let id = (app.id || "").toLowerCase();
                let generic = (app.genericName || "").toLowerCase();
                if (name.indexOf(q) !== -1 || comment.indexOf(q) !== -1 || id.indexOf(q) !== -1 || generic.indexOf(q) !== -1) {
                    list.push(app);
                }
            }
        }
        list.sort((a, b) => {
            if (q !== "") {
                let aStarts = (a.name || "").toLowerCase().startsWith(q) ? 1 : 0;
                let bStarts = (b.name || "").toLowerCase().startsWith(q) ? 1 : 0;
                if (aStarts !== bStarts) return bStarts - aStarts;
            }
            return (a.name || "").localeCompare(b.name || "");
        });
        return list;
    }

    onAppsListChanged: {
        if (selectedIndex >= appsList.length)
            selectedIndex = Math.max(0, appsList.length - 1);
    }

    readonly property real totalContentHeight: Math.ceil(appsList.length / 5) * gridView.cellHeight
    property real targetContentY: 0

    function smoothScrollBy(deltaY) {
        let step = -(deltaY / 120.0) * 110;
        let maxScroll = Math.max(0, totalContentHeight - gridView.height);
        if (!scrollAnim.running) {
            targetContentY = gridView.contentY;
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
                let maxScroll = Math.max(0, root.totalContentHeight - gridView.height);
                let target = Math.max(0, Math.min(maxScroll, gridView.contentY - event.pixelDelta.y));
                gridView.contentY = target;
                root.targetContentY = target;
            } else if (event.angleDelta.y !== 0) {
                root.smoothScrollBy(event.angleDelta.y);
            }
        }
    }

    function moveSelection(dx, dy) {
        if (appsList.length === 0) return;
        let cols = 5;
        let nextIdx = selectedIndex + dx + (dy * cols);
        if (nextIdx < 0) nextIdx = 0;
        if (nextIdx >= appsList.length) nextIdx = appsList.length - 1;
        selectedIndex = nextIdx;

        let row = Math.floor(selectedIndex / cols);
        let itemTop = row * gridView.cellHeight;
        let itemBottom = itemTop + gridView.cellHeight;
        if (itemTop < gridView.contentY) {
            targetContentY = Math.max(0, itemTop);
            scrollAnim.to = targetContentY;
            scrollAnim.restart();
        } else if (itemBottom > gridView.contentY + gridView.height) {
            let maxScroll = Math.max(0, totalContentHeight - gridView.height);
            targetContentY = Math.min(maxScroll, itemBottom - gridView.height);
            scrollAnim.to = targetContentY;
            scrollAnim.restart();
        }
    }

    NumberAnimation {
        id: scrollAnim
        target: gridView
        property: "contentY"
        duration: 110
        easing.type: Easing.OutQuad
    }

    function launchSelected() {
        if (selectedIndex >= 0 && selectedIndex < appsList.length) {
            appsList[selectedIndex].execute();
            root.appLaunched();
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
                text: "Applications"
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
                    text: String(root.appsList.length)
                    font.family: "SF Pro Text"
                    font.pixelSize: 13
                    font.bold: true
                    color: "#ffffff"
                }
            }
        }
    }

    GridView {
        id: gridView
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.bottomMargin: 12
        clip: true

        cellWidth: width / 5
        cellHeight: 128

        model: root.appsList

        Rectangle {
            id: liquidHighlight
            parent: gridView.contentItem
            z: 0
            visible: root.appsList.length > 0 && root.selectedIndex >= 0 && root.selectedIndex < root.appsList.length
            width: gridView.cellWidth - 8
            height: gridView.cellHeight - 8
            radius: 16
            color: "#40ffffff"
            border.width: 1
            border.color: "#60ffffff"
            antialiasing: true

            readonly property int col: root.selectedIndex % 5
            readonly property int row: Math.floor(root.selectedIndex / 5)

            x: (col * gridView.cellWidth) + 4
            y: (row * gridView.cellHeight) + 4

            Behavior on x {
                NumberAnimation {
                    duration: 90
                    easing.type: Easing.OutQuad
                }
            }
            Behavior on y {
                NumberAnimation {
                    duration: 90
                    easing.type: Easing.OutQuad
                }
            }
        }

        delegate: Item {
            id: appDelegate
            required property int index
            required property var modelData
            z: 1

            width: gridView.cellWidth
            height: gridView.cellHeight

            Item {
                id: card
                anchors.fill: parent
                anchors.margins: 4

                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    width: parent.width - 12

                    Rectangle {
                        id: iconContainer
                        width: 60
                        height: 60
                        radius: 15
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: root.selectedIndex === index ? "#40ffffff" : "#20ffffff"
                        border.width: 1
                        border.color: Theme.cardBorderColor
                        antialiasing: true

                        scale: root.selectedIndex === index ? 1.08 : (mouseArea.pressed ? 0.95 : 1.0)
                        Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Behavior on border.color { ColorAnimation { duration: 150 } }

                        Image {
                            id: iconImg
                            anchors.fill: parent
                            anchors.margins: 5
                            source: Quickshell.iconPath(modelData.icon, true) || (modelData.icon && modelData.icon.startsWith("/") ? ("file://" + modelData.icon) : "")
                            fillMode: Image.PreserveAspectFit
                            mipmap: true
                            visible: status === Image.Ready
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: 15
                            color: "#30ffffff"
                            border.color: Theme.cardBorderColor
                            border.width: 1
                            antialiasing: true
                            visible: iconImg.status !== Image.Ready

                            Text {
                                anchors.centerIn: parent
                                text: modelData.name && modelData.name.length > 0 ? modelData.name.charAt(0).toUpperCase() : "󰀻"
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 24
                                font.bold: true
                                color: "#ffffff"
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        text: modelData.name || ""
                        font.family: "SF Pro Text"
                        font.pixelSize: 14
                        font.bold: true
                        color: "#ffffff"
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.Wrap
                    }
                }

                MouseArea {
                    id: mouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: {
                        if (root.selectedIndex !== index)
                            root.selectedIndex = index;
                    }
                    onEntered: root.selectedIndex = index
                    onClicked: {
                        modelData.execute();
                        root.appLaunched();
                    }
                }
            }
        }
    }

    Item {
        anchors.fill: parent
        visible: root.appsList.length === 0

        Column {
            anchors.centerIn: parent
            spacing: 10

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "󰀻"
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 36
                color: "#9ca3af"
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "No applications found"
                font.family: "SF Pro Text"
                font.pixelSize: 14
                font.bold: true
                color: "#4b5563"
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Try searching with a different keyword"
                font.family: "SF Pro Text"
                font.pixelSize: 12
                color: "#9ca3af"
            }
        }
    }
}
