import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    Process {
        id: proc
    }

    function run(cmd) {
        console.log("Before: proc.running =", proc.running)
        proc.command = cmd
        proc.running = false
        proc.running = true
        console.log("After: proc.running =", proc.running)
    }

    Timer {
        interval: 100
        running: true
        onTriggered: {
            run(["echo", "hello 1"])
            run(["echo", "hello 2"])
        }
    }
}
