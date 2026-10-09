import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// MacSpinner — Authentic 12-Spoke macOS/iOS Radial Loading Spinner.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    property real size: 22
    property color spokeColor: "#ffffff"
    property bool running: true
    property int currentStep: 0

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    // Spoke dimensions proportional to spinner size
    readonly property real spokeWidth: Math.max(1.8, size * 0.09)
    readonly property real spokeHeight: size * 0.28
    readonly property real spokeRadius: spokeWidth / 2
    readonly property real spokeDistance: size * 0.32

    // Stepped phase timer (12 steps per cycle ~ 83ms per step = 1 full second rotation)
    Timer {
        id: stepTimer
        interval: 83
        running: root.running && root.visible
        repeat: true
        onTriggered: {
            root.currentStep = (root.currentStep + 1) % 12
        }
    }

    Item {
        anchors.centerIn: parent
        width: root.size
        height: root.size

        Repeater {
            model: 12

            delegate: Item {
                id: spokeContainer
                anchors.centerIn: parent
                width: root.size
                height: root.size
                rotation: index * 30

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: (root.size / 2) - root.spokeDistance - root.spokeHeight
                    width: root.spokeWidth
                    height: root.spokeHeight
                    radius: root.spokeRadius
                    color: root.spokeColor

                    // Staggered Apple opacity formula
                    opacity: {
                        if (!root.running) return 0.25
                        const stepDiff = (index - root.currentStep + 12) % 12
                        // Step 0 is 1.0 (brightest), fading down to 0.20
                        return Math.max(0.20, 1.0 - (stepDiff / 12.0) * 0.80)
                    }

                    Behavior on opacity {
                        NumberAnimation { duration: 60 }
                    }
                }
            }
        }
    }
}
