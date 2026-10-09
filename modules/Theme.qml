pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool darkMode: true
    property bool _isSaving: false

    readonly property color cardIdleColor: darkMode ? "#90111a24" : "#22ffffff"
    readonly property color panelBgColor: darkMode ? "#95111a24" : "#22ffffff"
    readonly property color cardBorderColor: darkMode ? Qt.rgba(1.0, 1.0, 1.0, 0.16) : Qt.rgba(1.0, 1.0, 1.0, 0.22)
    readonly property color panelBorderColor: darkMode ? "#30ffffff" : "#47ffffff"

    Process {
        id: saveProc
        onExited: function() { root._isSaving = false }
    }

    function toggleDarkMode() {
        darkMode = !darkMode
        saveTheme()
    }

    function saveTheme() {
        _isSaving = true
        const json = JSON.stringify({ darkMode: root.darkMode })
        saveProc.running = false
        saveProc.command = ["sh", "-c", "mkdir -p ~/.cache/quickshell && printf '%s\\n' '" + json + "' > ~/.cache/quickshell/theme.json"]
        saveProc.running = true
    }

    FileView {
        id: themeFile
        path: "/home/banana/.cache/quickshell/theme.json"
        watchChanges: true
        onLoadedChanged: {
            if (!root._isSaving && loaded) root.loadTheme()
        }
        onFileChanged: {
            if (!root._isSaving) root.loadTheme()
        }
    }

    function loadTheme() {
        try {
            const text = themeFile.text()
            if (text && text.trim() !== "") {
                const data = JSON.parse(text.trim())
                if (data && data.darkMode !== undefined) {
                    root.darkMode = !!data.darkMode
                }
            }
        } catch(e) {}
    }

    Component.onCompleted: {
        loadTheme()
    }
}
