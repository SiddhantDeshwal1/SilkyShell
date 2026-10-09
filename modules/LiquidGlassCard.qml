import QtQuick
import QtQuick.Layouts

Item {
    id: root

    property real cardRadius: 26
    property bool isHovered: false
    property bool isPressed: false
    property bool isActive: false
    property color activeColor: "#1d4ed8"
    property color idleColor: Theme.cardIdleColor
    property color hoverColor: idleColor        // Zero white tint on hover
    default property alias content: contentContainer.data

    // ── Smooth Tactile Hydraulic Press (Zero Hover Clipping) ─────────
    scale: isPressed ? 0.965 : 1.0
    Behavior on scale {
        NumberAnimation {
            duration: root.isPressed ? 100 : 200
            easing.type: root.isPressed ? Easing.InQuad : Easing.OutBack
            easing.overshoot: 1.15
        }
    }

    // ── 1. Clean Solid Frosted Base Glass ─────────────────────────────
    Rectangle {
        id: glassBase
        anchors.fill: parent
        radius: root.cardRadius
        color: root.isActive ? root.activeColor : root.idleColor

        border.color: root.isActive
            ? Qt.rgba(0.67, 0.88, 1.0, 0.95)   // Accent color when active
            : Theme.cardBorderColor
        border.width: 1.2

        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }

    // ── 2. Vivid Neutral Specular Underlayer ───────────────────────────
    Rectangle {
        anchors.fill: parent
        radius: root.cardRadius
        color: "transparent"
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#12ffffff" }
            GradientStop { position: 0.50; color: "#00ffffff" }
            GradientStop { position: 1.0; color: "#00000000" }
        }
    }

    // ── 3. Directional Top-Left Glass Bevel Refraction ────────────────
    // Top-down specular reflection
    Rectangle {
        anchors.fill: parent
        radius: root.cardRadius
        color: "transparent"
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#30ffffff" }
            GradientStop { position: 0.28; color: "#08ffffff" }
            GradientStop { position: 1.0; color: "#00ffffff" }
        }
    }

    // ── 4. Inset Glass Perimeter Rim Highlight ────────────────────────
    Rectangle {
        anchors.fill: parent
        anchors.margins: 1.2
        radius: Math.max(0, root.cardRadius - 1.2)
        color: "transparent"
        border.color: root.isActive
            ? Qt.rgba(0.67, 0.88, 1.0, 0.70)
            : Qt.rgba(1.0, 1.0, 1.0, 0.14)
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: 200 } }
    }

    // ── 5. Content Container ──────────────────────────────────────────
    Item {
        id: contentContainer
        anchors.fill: parent
        clip: root.clip
    }
}

