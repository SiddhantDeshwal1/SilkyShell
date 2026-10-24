import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// CPU, memory, GPU, power, temp stats. Matches waybar cpu + memory + custom/gpu modules.
// CPU via /proc/stat delta. Memory via /proc/meminfo. GPU via drm card.
// Power via RAPL energy_uj delta. Temp via hwmon k10temp/dell_smm.
// Update interval: 2 seconds. Color: #fe8019 (gruvbox orange).
Item {
    id: root
    implicitWidth: statsText.implicitWidth + 16

    property int cpuUsage: 0
    property real memUsedGb: 0
    property string gpuText: "G: N/A"
    property string powerText: "P:--"
    property string tempText: "T:--"

    // CPU delta tracking
    property var prevCpu: null   // { total, idle }

    // ── Persistent Stats Daemon (single long-running process, no respawn overhead) ───
    // sys-stats.sh loops forever, emitting blocks every 3 s separated by '---END---'
    Process {
        id: statsProc
        command: [Paths.script("sys-stats.sh")]
        running: true
        stdout: SplitParser {
            property int memTotal: 0
            onRead: function(line) {
                const trimmed = line.trim()
                if (trimmed === "---END---") return   // block separator, ignore
                if (trimmed.startsWith("cpu ")) {
                    const parts = trimmed.split(/\s+/)
                    const user    = parseInt(parts[1])
                    const nice    = parseInt(parts[2])
                    const system  = parseInt(parts[3])
                    const idle    = parseInt(parts[4])
                    const iowait  = parseInt(parts[5])
                    const irq     = parseInt(parts[6])
                    const softirq = parseInt(parts[7])
                    const steal   = parseInt(parts[8]) || 0

                    const total    = user + nice + system + idle + iowait + irq + softirq + steal
                    const idleAll  = idle + iowait

                    if (root.prevCpu) {
                        const dt = total - root.prevCpu.total
                        const di = idleAll - root.prevCpu.idle
                        if (dt > 0)
                            root.cpuUsage = Math.round((1 - di / dt) * 100)
                    }
                    root.prevCpu = { total: total, idle: idleAll }
                } else if (trimmed.startsWith("MemTotal:") || trimmed.startsWith("MemAvailable:")) {
                    const m = trimmed.match(/^(\w+):\s+(\d+)/)
                    if (m) {
                        if (m[1] === "MemTotal")     memTotal = parseInt(m[2])
                        if (m[1] === "MemAvailable") {
                            const avail = parseInt(m[2])
                            root.memUsedGb = (memTotal - avail) / (1024 * 1024)
                        }
                    }
                } else if (trimmed.startsWith("G:")) {
                    root.gpuText = trimmed.replace("%", "").trim()
                } else if (trimmed.startsWith("P:")) {
                    root.powerText = trimmed.replace("W", "").trim()
                } else if (trimmed.startsWith("T:")) {
                    root.tempText = trimmed.trim()
                }
            }
        }
        onExited: function(code, status) {
            // Daemon exited unexpectedly — restart after 1 second
            restartTimer.start()
        }
    }

    Timer {
        id: restartTimer
        interval: 1000
        repeat: false
        onTriggered: if (!statsProc.running) statsProc.running = true
    }

    // ── Display ───────────────────────────────────────────────────────
    Text {
        id: statsText
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenter: parent.horizontalCenter
        font.family: "SF Pro Rounded"
        font.pixelSize: 17
        font.bold: false
        color: "#fe8019"
        text: "C:" + root.cpuUsage + "  M:" + (root.memUsedGb ? root.memUsedGb.toFixed(1) : "0.0") + "  " + root.gpuText + "  " + root.powerText + "  " + root.tempText
    }
}
