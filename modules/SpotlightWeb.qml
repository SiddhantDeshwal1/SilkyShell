import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
    id: root

    property string filterQuery: ""
    property int selectedIndex: 0
    property int contentHeight: 400
    height: contentHeight
    clip: true

    signal searchExecuted(string query)

    property var webItems: []
    property var pendingItems: []
    property bool isSearching: false

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

    Process {
        id: webSuggestProc
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
            root.webItems = root.pendingItems;
            root.pendingItems = [];
            root.isSearching = false;
            if (root.selectedIndex >= root.webItems.length) {
                root.selectedIndex = Math.max(0, root.webItems.length - 1);
            }
        }
    }

    function reload() {
        webSuggestProc.running = false;
        root.pendingItems = [];
        root.isSearching = true;

        let q = filterQuery.trim();
        if (q === "") {
            // Show initial quick prompt or bookmarks
            root.webItems = [
                {
                    action: "web",
                    id: "web_google",
                    label: "Search with Google",
                    description: "Type any search term or URL to open in Chrome",
                    query: "https://www.google.com",
                    icon: "󰖟"
                },
                {
                    action: "web",
                    id: "web_github",
                    label: "GitHub",
                    description: "https://github.com",
                    query: "https://github.com",
                    icon: "󰃃"
                },
                {
                    action: "web",
                    id: "web_youtube",
                    label: "YouTube",
                    description: "https://youtube.com",
                    query: "https://youtube.com",
                    icon: "󰃃"
                }
            ];
            root.isSearching = false;
        } else {
            webSuggestProc.command = [
                Paths.script("web-search.py"),
                "suggest",
                q,
                "6"
            ];
            webSuggestProc.running = true;
        }
    }

    function moveSelection(delta) {
        if (webItems.length === 0) return;
        let nextIdx = selectedIndex + delta;
        if (nextIdx < 0) nextIdx = webItems.length - 1;
        if (nextIdx >= webItems.length) nextIdx = 0;
        selectedIndex = nextIdx;
        listView.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    Process { id: openProc }
    function openSelected() {
        if (selectedIndex >= 0 && selectedIndex < webItems.length) {
            let item = webItems[selectedIndex];
            openItem(item);
        } else if (filterQuery.trim() !== "") {
            openQuery(filterQuery.trim());
        }
    }

    function openItem(item) {
        let q = item.query || item.label || filterQuery;
        openQuery(q);
    }

    function openQuery(q) {
        openProc.running = false;
        openProc.command = [Paths.script("web-open.sh"), q];
        openProc.running = true;
        root.searchExecuted(q);
    }

    Rectangle {
        id: topDivider
        width: parent.width
        height: 1
        color: Theme.cardBorderColor
        anchors.top: parent.top
    }

    // Results ListView
    ListView {
        id: listView
        anchors.top: topDivider.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        clip: true
        model: root.webItems
        boundsBehavior: Flickable.StopAtBounds

        delegate: Item {
            id: webDelegate
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

                    // Web icon tile
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
                            text: modelData.icon || "󰖟"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 22
                            color: modelData.icon === "󰃃" ? "#38bdf8" : "#60a5fa"
                        }
                    }

                    // Query & subtext
                    Column {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            text: modelData.label
                            font.family: "SF Pro Text"
                            font.bold: true
                            font.pixelSize: 15
                            color: "#ffffff"
                            elide: Text.ElideRight
                            width: parent.width
                        }

                        Text {
                            text: modelData.description
                            font.family: "SF Pro Text"
                            font.pixelSize: 12
                            color: "#94a3b8"
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }

                    // Chrome pill
                    Rectangle {
                        Layout.preferredHeight: 22
                        Layout.preferredWidth: chromeBadgeText.implicitWidth + 14
                        radius: 11
                        color: "#203b82f6"
                        border.color: "#503b82f6"
                        border.width: 1
                        antialiasing: true

                        Text {
                            id: chromeBadgeText
                            anchors.centerIn: parent
                            text: "Chrome"
                            font.family: "SF Pro Text"
                            font.bold: true
                            font.pixelSize: 11
                            color: "#93c5fd"
                        }
                    }
                }

                MouseArea {
                    id: delegateMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selectedIndex = index
                    onClicked: root.openItem(modelData)
                }
            }
        }
    }
}
