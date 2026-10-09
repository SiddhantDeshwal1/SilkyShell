import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

ShellRoot {
    PwObjectTracker {
        objects: {
            const arr = []
            if (Pipewire.defaultAudioSource) arr.push(Pipewire.defaultAudioSource)
            for (let n of Pipewire.nodes.values) arr.push(n)
            return arr
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: false
        onTriggered: {
            console.log("Current default:", Pipewire.defaultAudioSource ? Pipewire.defaultAudioSource.name : "null")
            const sources = Pipewire.nodes.values.filter(n => !n.isStream && !n.isSink && n.audio !== null)
            console.log("Found sources:", sources.length)
            for (let s of sources) {
                console.log("Source:", s.id, s.name, "isPreferred:", Pipewire.preferredDefaultAudioSource === s)
            }
            if (sources.length > 1) {
                const target = sources.find(s => s !== Pipewire.defaultAudioSource)
                console.log("Setting preferred to:", target.id, target.name)
                Pipewire.preferredDefaultAudioSource = target
            }
        }
    }

    Connections {
        target: Pipewire
        function onDefaultAudioSourceChanged() {
            console.log("DefaultAudioSource changed to:", Pipewire.defaultAudioSource ? Pipewire.defaultAudioSource.name : "null")
        }
    }
}
