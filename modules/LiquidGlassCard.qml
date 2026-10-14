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
    property color activeBorderColor: Qt.rgba(0.67, 0.88, 1.0, 0.95)
    property color activeRimColor: Qt.rgba(0.67, 0.88, 1.0, 0.70)
    default property alias content: contentContainer.data

    // ── Liquid Wave Fill Engine Properties ───────────────────────────
    readonly property color targetColor: root.isActive ? root.activeColor : root.idleColor
    property color fromColor: targetColor
    property color toColor: targetColor
    property real fillProgress: 1.0
    property real originX: root.cardRadius > 0 ? root.cardRadius : 35
    property real originY: root.height > 0 ? root.height / 2 : 35
    property real maxRadius: 200
    property real fluidPulse: 1.0

    // Set origin for liquid wave expansion (called from click handlers)
    function setClickPos(x, y) {
        originX = (x !== undefined && x >= 0) ? x : (root.cardRadius > 0 ? root.cardRadius : 35);
        originY = (y !== undefined && y >= 0) ? y : (root.height > 0 ? root.height / 2 : 35);
    }

    function calculateMaxRadius() {
        var ox = originX;
        var oy = originY;
        var w = root.width > 0 ? root.width : 180;
        var h = root.height > 0 ? root.height : 70;
        var d1 = Math.hypot(ox, oy);
        var d2 = Math.hypot(w - ox, oy);
        var d3 = Math.hypot(ox, h - oy);
        var d4 = Math.hypot(w - ox, h - oy);
        return Math.max(d1, d2, d3, d4) + 24;
    }

    function lerpColor(c1, c2, t) {
        return Qt.rgba(
            c1.r + (c2.r - c1.r) * t,
            c1.g + (c2.g - c1.g) * t,
            c1.b + (c2.b - c1.b) * t,
            c1.a + (c2.a - c1.a) * t
        );
    }

    onTargetColorChanged: {
        if (!root.visible || root.width <= 0) {
            fromColor = targetColor;
            toColor = targetColor;
            fillProgress = 1.0;
            return;
        }
        if (fillAnim.running) {
            fromColor = lerpColor(fromColor, toColor, fillProgress);
        } else {
            fromColor = toColor;
        }
        toColor = targetColor;
        maxRadius = calculateMaxRadius();
        fillProgress = 0.0;
        fillAnim.restart();
        pulseAnim.restart();
    }

    NumberAnimation {
        id: fillAnim
        target: root
        property: "fillProgress"
        from: 0.0
        to: 1.0
        duration: 520
        easing.type: Easing.BezierSpline
        easing.bezierCurve: [0.22, 1.0, 0.36, 1.0]
    }

    SequentialAnimation {
        id: pulseAnim
        NumberAnimation { target: root; property: "fluidPulse"; to: 1.018; duration: 180; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "fluidPulse"; to: 0.995; duration: 150; easing.type: Easing.InOutQuad }
        NumberAnimation { target: root; property: "fluidPulse"; to: 1.0; duration: 160; easing.type: Easing.OutBack }
    }

    // ── Smooth Tactile Hydraulic Press + Fluid Impulse ───────────────
    scale: (isPressed ? 0.965 : 1.0) * fluidPulse
    Behavior on scale {
        NumberAnimation {
            duration: root.isPressed ? 100 : 200
            easing.type: root.isPressed ? Easing.InQuad : Easing.OutBack
            easing.overshoot: 1.15
        }
    }

    // ── 1. Clean Solid Frosted Base Glass & Fallback ──────────────────
    Rectangle {
        id: glassBase
        anchors.fill: parent
        radius: root.cardRadius
        color: root.toColor

        border.color: root.isActive
            ? root.activeBorderColor
            : Theme.cardBorderColor
        border.width: 1.2

        Behavior on color { ColorAnimation { duration: 380; easing.type: Easing.OutCubic } }
        Behavior on border.color { ColorAnimation { duration: 380; easing.type: Easing.OutCubic } }
    }

    // ── 1b. GPU Liquid Wave Fill Shader ──────────────────────────────
    ShaderEffect {
        id: liquidShader
        anchors.fill: parent
        fragmentShader: Qt.resolvedUrl("shaders/liquid_fill.frag.qsb")

        property real radius: root.cardRadius
        property vector2d size: Qt.vector2d(Math.max(1, root.width), Math.max(1, root.height))
        property vector2d origin: Qt.vector2d(root.originX, root.originY)
        property real progress: root.fillProgress
        property real maxRadius: Math.max(1, root.maxRadius)
        property color fromColor: root.fromColor
        property color toColor: root.toColor
        property color highlightColor: Qt.rgba(1.0, 1.0, 1.0, 0.85)
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
            ? root.activeRimColor
            : Qt.rgba(1.0, 1.0, 1.0, 0.14)
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: 380; easing.type: Easing.OutCubic } }
    }

    // ── 5. Content Container ──────────────────────────────────────────
    Item {
        id: contentContainer
        anchors.fill: parent
        clip: root.clip
    }
}
