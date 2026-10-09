import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland

// Hyprland workspace buttons — matches waybar hyprland/workspaces module.
// Active workspace: white bg + dark text. Inactive: transparent + grey text.
// Hyprland workspace buttons with Caelestia spring active pill & hover animations
Item {
    id: root
    Layout.fillHeight: true
    implicitWidth: rowLayout.implicitWidth

    // Sliding active pill (Caelestia expressiveDefaultSpatial spring feel)
    Rectangle {
        id: activePill
        height: root.height - 2
        anchors.verticalCenter: parent.verticalCenter
        radius: 4
        color: "#ebdbb2"
        z: 0

        property real targetX: 0
        property real targetWidth: 0
        property bool ready: false

        x: targetX
        width: targetWidth
        opacity: ready && targetWidth > 0 ? 1.0 : 0.0

        Behavior on x {
            enabled: activePill.ready && activePill.targetWidth > 0
            NumberAnimation {
                duration: 260
                easing.type: Easing.OutBack
                easing.overshoot: 1.15
            }
        }
        Behavior on width {
            enabled: activePill.ready && activePill.targetWidth > 0
            NumberAnimation {
                duration: 220
                easing.type: Easing.OutCubic
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: 150
                easing.type: Easing.OutQuad
            }
        }

        function updatePosition(item, animate) {
            if (!item || item.width <= 0) return
            const newX = item.x + 1
            const newW = item.width - 2
            if (!ready) {
                targetX = newX
                targetWidth = newW
                ready = true
            } else {
                targetX = newX
                targetWidth = newW
            }
        }

        function refresh() {
            for (let i = 0; i < wsRepeater.count; i++) {
                const it = wsRepeater.itemAt(i)
                if (it && it.modelData && it.modelData.focused && it.width > 0) {
                    updatePosition(it, true)
                    return
                }
            }
        }
    }

    RowLayout {
        id: rowLayout
        anchors.fill: parent
        spacing: 0
        z: 1

        Repeater {
            id: wsRepeater
            model: Hyprland.workspaces

            onItemAdded: function(index, item) {
                Qt.callLater(activePill.refresh)
            }
            onItemRemoved: function(index, item) {
                Qt.callLater(activePill.refresh)
            }

            delegate: Item {
                id: wsItem
                required property var modelData
                Layout.fillHeight: true
                implicitWidth: wsLabel.implicitWidth + 14

                // Hover background for inactive
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: 4
                    color: !modelData.focused && hoverHandler.hovered ? "#3c3836" : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: 150; easing.type: Easing.InOutCubic }
                    }
                }

                Text {
                    id: wsLabel
                    anchors.centerIn: parent
                    font.family: "SF Pro Rounded"
                    font.pixelSize: 17
                    font.bold: false
                    color: modelData.focused ? "#282828" : (hoverHandler.hovered ? "#ebdbb2" : "#928374")
                    text: modelData.name

                    Behavior on color {
                        ColorAnimation { duration: 150; easing.type: Easing.InOutCubic }
                    }
                }

                Connections {
                    target: modelData
                    function onFocusedChanged() {
                        if (modelData && modelData.focused) {
                            if (wsItem.width > 0) {
                                activePill.updatePosition(wsItem, true)
                            } else {
                                Qt.callLater(() => {
                                    if (wsItem && modelData && modelData.focused) {
                                        activePill.updatePosition(wsItem, true)
                                    }
                                })
                            }
                        }
                    }
                }

                onXChanged: {
                    if (modelData && modelData.focused && width > 0) {
                        activePill.updatePosition(wsItem, true)
                    }
                }

                onWidthChanged: {
                    if (modelData && modelData.focused && width > 0) {
                        activePill.updatePosition(wsItem, true)
                    }
                }

                Component.onCompleted: {
                    if (modelData && modelData.focused) {
                        if (wsItem.width > 0) {
                            activePill.updatePosition(wsItem, false)
                        } else {
                            Qt.callLater(() => {
                                if (wsItem && modelData && modelData.focused) {
                                    activePill.updatePosition(wsItem, false)
                                }
                            })
                        }
                    }
                }

                HoverHandler { id: hoverHandler }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: modelData.activate()
                }
            }
        }
    }
}

