import QtQuick
import Quickshell

Item {
    Timer {
        interval: 1000
        running: true
        onTriggered: {
            console.log("Found apps:", DesktopEntries.applications.values.length);
            const first = DesktopEntries.applications.values[0];
            if (first) console.log("First app:", first.name, first.icon, first.id);
            Qt.quit();
        }
    }
}
