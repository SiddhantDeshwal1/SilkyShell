import QtQuick
import Quickshell
import "extra/shell/modules/launcher/services"

Item {
    Component.onCompleted: {
        console.log("Apps length:", Apps.search("fir").length)
        Qt.quit()
    }
}
