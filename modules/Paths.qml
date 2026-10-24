pragma Singleton
import QtQuick

QtObject {
    id: root

    // Dynamically resolved root config directory (e.g. ~/.config/quickshell)
    // Works for any user and any installation location.
    readonly property string configDir: Qt.resolvedUrl("..").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
    readonly property string scriptsDir: configDir + "/scripts"
    readonly property string mediaDir: configDir + "/media"

    function script(name) {
        return scriptsDir + "/" + name
    }

    function mediaIcon(name) {
        return "file://" + mediaDir + "/icons/" + name
    }
}
