import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// AppleWifiIcon — Apple SF Symbols style Wi-Fi icon component.
// Features solid bottom circle and concentric bold curvy semi-circles.
// Dynamically routes to correct signal bars (3, 2, 1, 0) and slashed off state.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    property int size: 24
    property string variant: "white" // "white" | "blue" | "grey" | "black"
    property int signal: 100
    property bool enabled: true
    property bool connected: true

    implicitWidth: size
    implicitHeight: size

    readonly property string iconSource: {
        if (!enabled) {
            if (variant === "blue") return Paths.mediaIcon("wifi_off_blue.svg")
            if (variant === "white") return Paths.mediaIcon("wifi_off_white.svg")
            if (variant === "black") return Paths.mediaIcon("wifi_off.svg")
            return Paths.mediaIcon("wifi_off_grey.svg")
        }
        const suffix = variant === "black" ? ".svg" : ("_" + variant + ".svg")
        const prefix = "wifi_"
        if (signal > 75) return Paths.mediaIcon(prefix + "3" + suffix)
        if (signal > 45) return Paths.mediaIcon(prefix + "2" + suffix)
        if (signal > 20) return Paths.mediaIcon(prefix + "1" + suffix)
        return Paths.mediaIcon(prefix + "0" + suffix)
    }

    Image {
        anchors.centerIn: parent
        width: root.size
        height: root.size
        sourceSize.width: root.size * 2
        sourceSize.height: root.size * 2
        source: root.iconSource
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }
}
