import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Displays todo count from todo.sh. Matches waybar custom/todo module.
// Watches tasks.txt for real-time updates. Left-click opens the TUI.
Text {
    id: root
    Layout.fillHeight: true

    property int todoCount: 0
    property string todoClass: "todo-none"

    font.family: "SF Pro Rounded"
    font.pixelSize: 17
    font.bold: false
    verticalAlignment: Text.AlignVCenter
    // Format mirrors waybar: " {icon} {count} |"
    text: "  " + todoCount + "  |  "

    color: {
        switch (todoClass) {
            case "todo-low":    return "#b8bb26"
            case "todo-medium": return "#fabd2f"
            case "todo-high":   return "#fb4934"
            default:            return "#928374"   // todo-none
        }
    }

    Behavior on color {
        ColorAnimation { duration: 250; easing.type: Easing.InOutCubic }
    }

    function refresh() {
        // Guard: don't start a new poll if one is already running
        if (!todoProc.running)
            todoProc.running = true
    }

    Component.onCompleted: refresh()

    // Watch tasks.txt so the count updates right after the TUI closes
    // and when todo.sh writes changes during background operation.
    FileView {
        id: tasksWatcher
        path: "/home/banana/.config/quickshell/scripts/tasks.txt"
        watchChanges: true
        onFileChanged: root.refresh()
    }

    Process {
        id: todoProc
        command: ["/home/banana/.config/quickshell/scripts/todo.sh"]
        stdout: SplitParser {
            onRead: function(line) {
                try {
                    const obj = JSON.parse(line.trim())
                    root.todoCount = parseInt(obj.text) || 0
                    root.todoClass = obj.class || "todo-none"
                } catch (e) {}
            }
        }
    }

    // Left-click: open TUI; refresh count once the foot window closes
    Process {
        id: menuProc
        command: ["foot", "--app-id=todo-input", "-e",
                  "/home/banana/.config/quickshell/scripts/todo.sh", "--tui"]
        onExited: function(code, status) { root.refresh() }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: menuProc.running = true
    }
}
