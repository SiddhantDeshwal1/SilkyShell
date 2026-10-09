import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets

// System tray using Quickshell's StatusNotifier support.
// Icon-size 22, spacing 6, margin-left 8.
RowLayout {
    id: root
    Layout.fillHeight: true
    spacing: 6

    // Left margin
    Item { implicitWidth: 8; height: 1 }

    Repeater {
        model: SystemTray.items

        delegate: Item {
            required property var modelData
            Layout.fillHeight: true
            implicitWidth: 28
            implicitHeight: 28

            IconImage {
                anchors.centerIn: parent
                antialiasing: true
                implicitWidth: 28
                implicitHeight: 28
                source: modelData.icon
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton && modelData.hasMenu) {
                        // display() needs the backing QObject window + item-relative coords
                        modelData.display(root.Window.window, mapToGlobal(0, 0).x, mapToGlobal(0, 0).y)
                    } else {
                        modelData.activate()
                    }
                }
            }
        }
    }
}
