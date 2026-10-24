import QtQuick
import QtQuick.Layouts

Item {
    id: root

    property var results: [
        { id: "1", icon: "󰕋", label: "Twitter", description: "Social Media", shortcut: "T" },
        { id: "2", icon: "󰖟", label: "Browser", description: "Web", shortcut: "B" },
        { id: "3", icon: "󰇮", label: "Mail", description: "Communication", shortcut: "M" },
        { id: "4", icon: "󰃭", label: "Calendar", description: "Schedule", shortcut: "C" },
        { id: "5", icon: "󰎚", label: "Notes", description: "Text", shortcut: "N" },
        { id: "6", icon: "󰋩", label: "Photos", description: "Gallery", shortcut: "P" },
        { id: "7", icon: "󰒓", label: "Settings", description: "System", shortcut: "S" },
        { id: "8", icon: "󰆍", label: "Terminal", description: "Command Line", shortcut: "Cmd" },
        { id: "9", icon: "󰉋", label: "Files", description: "Storage", shortcut: "F" },
        { id: "10", icon: "󰍡", label: "Messages", description: "Chat", shortcut: "Msg" },
        { id: "11", icon: "󰎆", label: "Music", description: "Audio", shortcut: "Audio" }
    ]

    signal resultHovered(int index)
    signal resultUnhovered()
    signal resultClicked(var result, bool isTerminal)
    
    property int selectedIndex: -1
    property real targetContentY: 0

    function smoothScrollBy(deltaY) {
        let step = -(deltaY / 120.0) * 110;
        let maxScroll = Math.max(0, resultsColumn.height - flickable.height);
        if (!scrollAnim.running) {
            targetContentY = flickable.contentY;
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
                let maxScroll = Math.max(0, resultsColumn.height - flickable.height);
                let target = Math.max(0, Math.min(maxScroll, flickable.contentY - event.pixelDelta.y));
                flickable.contentY = target;
                root.targetContentY = target;
            } else if (event.angleDelta.y !== 0) {
                root.smoothScrollBy(event.angleDelta.y);
            }
        }
    }

    onResultsChanged: {
        scrollAnim.stop();
        flickable.contentY = 0;
        targetContentY = 0;
    }

    onSelectedIndexChanged: {
        if (selectedIndex <= 0) {
            scrollAnim.stop();
            targetContentY = 0;
            flickable.contentY = 0;
            return;
        }
        if (selectedIndex < root.results.length) {
            let itemTop = resultsColumn.topPadding + (selectedIndex * 66);
            let itemBottom = itemTop + 66;
            let effectiveHeight = Math.max(flickable.height, root.contentHeightPixels);
            if (itemTop < flickable.contentY) {
                targetContentY = Math.max(0, itemTop - 8);
                scrollAnim.to = targetContentY;
                scrollAnim.restart();
            } else if (itemBottom > flickable.contentY + effectiveHeight) {
                let maxScroll = Math.max(0, resultsColumn.height - effectiveHeight);
                targetContentY = Math.min(maxScroll, itemBottom - effectiveHeight + 8);
                scrollAnim.to = targetContentY;
                scrollAnim.restart();
            }
        }
    }

    NumberAnimation {
        id: scrollAnim
        target: flickable
        property: "contentY"
        duration: 110
        easing.type: Easing.OutQuad
    }

    // Auto-calculate height cleanly matching whole items up to 6 items (max 420px)
    property real contentHeightPixels: {
        if (!root.results || root.results.length === 0) return 0;
        let count = Math.min(root.results.length, 6);
        if (root.results.length > 6) {
            return resultsColumn.topPadding + (count * 66);
        } else {
            return resultsColumn.topPadding + (count * 66) + resultsColumn.bottomPadding;
        }
    }
    width: parent.width
    height: contentHeightPixels
    clip: true

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.cardBorderColor
        anchors.top: parent.top
    }

    Flickable {
        id: flickable
        anchors.fill: parent
        anchors.topMargin: 1
        contentHeight: resultsColumn.height
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Rectangle {
            id: liquidHighlight
            parent: flickable.contentItem
            z: 0
            visible: root.results.length > 0 && root.selectedIndex >= 0 && root.selectedIndex < root.results.length
            width: flickable.width - 16
            x: 8
            height: 66
            radius: 14
            color: Theme.darkMode ? "#30ffffff" : "#40ffffff"
            border.width: 1
            border.color: Theme.cardBorderColor
            antialiasing: true

            y: resultsColumn.topPadding + (root.selectedIndex * 66)

            Behavior on y {
                NumberAnimation {
                    duration: 90
                    easing.type: Easing.OutQuad
                }
            }
        }

        Column {
            id: resultsColumn
            width: parent.width
            topPadding: 8
            bottomPadding: root.results && root.results.length > 6 ? 8 : 16
            leftPadding: 8
            rightPadding: 8
            spacing: 0
            z: 1

            Repeater {
                model: root.results

                Item {
                    id: resultCard
                    required property int index
                    required property var modelData
                    z: 1

                    width: parent.width - 16
                    height: 66
                    opacity: 1.0

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 14

                        // Icon container
                        Rectangle {
                            Layout.preferredWidth: 48
                            Layout.preferredHeight: 48
                            radius: 12
                            color: Theme.darkMode ? "#25ffffff" : Qt.rgba(1.0, 1.0, 1.0, 0.35)
                            border.color: Theme.cardBorderColor
                            border.width: 1
                            antialiasing: true
                            scale: root.selectedIndex === index ? 1.08 : 1.0
                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack; easing.overshoot: 1.25 } }
                            
                            Image {
                                 anchors.fill: parent
                                 anchors.margins: 4
                                 visible: modelData.iconPath !== undefined && modelData.iconPath !== ""
                                 source: (modelData.iconPath && modelData.iconPath !== "") ? modelData.iconPath : ""
                                 fillMode: Image.PreserveAspectFit
                                 sourceSize: Qt.size(48, 48)
                                 asynchronous: true
                                 cache: true
                                 mipmap: true
                            }

                            Text {
                                 anchors.centerIn: parent
                                 text: modelData.icon ? modelData.icon : ""
                                 font.family: "JetBrainsMono Nerd Font"
                                 font.pixelSize: 20
                                 color: Theme.darkMode ? "#ffffff" : "#000000"
                                 visible: !modelData.iconPath || modelData.iconPath === ""
                            }
                        }

                        // Text Content
                        Column {
                            Layout.fillWidth: true
                            spacing: 3
                            
                            Text {
                                text: modelData.label
                                font.family: "SF Pro Text"
                                font.bold: true
                                font.pixelSize: 16
                                color: "#ffffff"
                                elide: Text.ElideRight
                                width: parent.width
                            }
                            Text {
                                text: modelData.description
                                font.family: "SF Pro Text"
                                font.pixelSize: 13
                                color: "#cbd5e1"
                                opacity: 0.85
                                elide: Text.ElideRight
                                width: parent.width
                            }
                        }

                        // Badge Pill
                        Rectangle {
                            visible: modelData.badge !== undefined && modelData.badge !== ""
                            Layout.preferredHeight: 22
                            Layout.preferredWidth: badgeText.implicitWidth + 14
                            radius: 11
                            color: {
                                if (modelData.badge === "Web" || modelData.badge === "Internet") return "#2238bdf8";
                                if (modelData.badge === "App") return "#22a855f7";
                                if (modelData.badge === "Related") return "#22818cf8";
                                if (modelData.badge === "File") return "#2222c55e";
                                if (modelData.badge === "Clip") return "#22eab308";
                                if (modelData.badge === "Bookmark") return "#2206b6d4";
                                return "#20ffffff";
                            }
                            border.color: {
                                if (modelData.badge === "Web" || modelData.badge === "Internet") return "#5538bdf8";
                                if (modelData.badge === "App") return "#55a855f7";
                                if (modelData.badge === "Related") return "#55818cf8";
                                if (modelData.badge === "File") return "#5522c55e";
                                if (modelData.badge === "Clip") return "#55eab308";
                                if (modelData.badge === "Bookmark") return "#5506b6d4";
                                return Theme.cardBorderColor;
                            }
                            border.width: 1
                            antialiasing: true

                            Text {
                                id: badgeText
                                anchors.centerIn: parent
                                text: modelData.badge || ""
                                font.family: "SF Pro Text"
                                font.bold: true
                                font.pixelSize: 11
                                color: {
                                    if (modelData.badge === "Web" || modelData.badge === "Internet") return "#7dd3fc";
                                    if (modelData.badge === "App") return "#d8b4fe";
                                    if (modelData.badge === "Related") return "#a5b4fc";
                                    if (modelData.badge === "File") return "#86efac";
                                    if (modelData.badge === "Clip") return "#fde047";
                                    if (modelData.badge === "Bookmark") return "#67e8f9";
                                    return "#e2e8f0";
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: cardMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPositionChanged: {
                            if (root.selectedIndex !== index) {
                                root.resultHovered(index)
                            }
                        }
                        onEntered: {
                            root.resultHovered(index)
                        }
                        onClicked: function(mouse) {
                            let isAlt = (mouse.modifiers & Qt.AltModifier) !== 0;
                            root.resultClicked(modelData, isAlt);
                        }
                    }
                }
            }
        }
    }
}
