import QtQuick

Item {
    id: root

    property real radius: 30
    property color baseColor: Theme.cardIdleColor
    property color borderColor: Theme.cardBorderColor
    property real borderWidth: 1.2
    property color insetBorderColor: Qt.rgba(1.0, 1.0, 1.0, 0.14)
    property real specularScale: 1.0
    property bool clipContent: false

    default property alias content: contentContainer.data
    property alias contentContainer: contentContainer

    // ── 1. Clean Solid Frosted Base Glass (Hyprland Blurred & Anti-Aliased) ──
    Rectangle {
        id: glassBase
        anchors.fill: parent
        radius: root.radius
        antialiasing: true
        color: root.baseColor

        border.color: root.borderColor
        border.width: root.borderWidth

        Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on border.color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }

    // ── 2. Vivid Neutral Specular Underlayer ───────────────────────────
    Rectangle {
        id: specularUnderlayer
        anchors.fill: parent
        radius: root.radius
        antialiasing: true
        color: "transparent"
        opacity: root.specularScale
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#12ffffff" }
            GradientStop { position: 0.50; color: "#00ffffff" }
            GradientStop { position: 1.0; color: "#00000000" }
        }
    }

    // ── 3. Directional Top-Left Glass Bevel Refraction ────────────────
    Rectangle {
        id: specularRefraction
        anchors.fill: parent
        radius: root.radius
        antialiasing: true
        color: "transparent"
        opacity: root.specularScale
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#30ffffff" }
            GradientStop { position: 0.28; color: "#08ffffff" }
            GradientStop { position: 1.0; color: "#00ffffff" }
        }
    }

    // ── 4. Inset Glass Perimeter Rim Highlight ────────────────────────
    Rectangle {
        id: insetRim
        anchors.fill: parent
        anchors.margins: root.borderWidth
        radius: Math.max(0, root.radius - root.borderWidth)
        antialiasing: true
        color: "transparent"
        border.color: root.insetBorderColor
        border.width: 1
        opacity: root.specularScale

        Behavior on border.color { ColorAnimation { duration: 180 } }
    }

    // ── 5. Content Container ──────────────────────────────────────────
    Item {
        id: contentContainer
        anchors.fill: parent
        clip: root.clipContent
    }
}
