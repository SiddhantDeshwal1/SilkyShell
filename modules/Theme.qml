pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool darkMode: true
    property bool _isSaving: false

    property color cardIdleColor: darkMode ? "#90111a24" : "#22ffffff"
    property color panelBgColor: darkMode ? "#95111a24" : "#22ffffff"
    property color cardBorderColor: darkMode ? Qt.rgba(1.0, 1.0, 1.0, 0.16) : Qt.rgba(1.0, 1.0, 1.0, 0.22)
    property color panelBorderColor: darkMode ? "#30ffffff" : "#47ffffff"

    // Dynamic wallpaper-derived bar & accent colors (opaque, stable across workspaces)
    property color barBgColor: "#0d0f1e"
    property color wallpaperAccentColor: "#566cdb"

    Behavior on cardIdleColor { ColorAnimation { duration: 420; easing.type: Easing.OutCubic } }
    Behavior on panelBgColor { ColorAnimation { duration: 420; easing.type: Easing.OutCubic } }
    Behavior on cardBorderColor { ColorAnimation { duration: 420; easing.type: Easing.OutCubic } }
    Behavior on panelBorderColor { ColorAnimation { duration: 420; easing.type: Easing.OutCubic } }
    Behavior on barBgColor { ColorAnimation { duration: 350; easing.type: Easing.OutCubic } }
    Behavior on wallpaperAccentColor { ColorAnimation { duration: 350; easing.type: Easing.OutCubic } }

    Process {
        id: saveProc
        onExited: function() { root._isSaving = false }
    }

    // Startup process: runs wallpaper-theme.py once on Quickshell startup
    Process {
        id: wpThemeProc
        command: ["python3", Paths.script("wallpaper-theme.py")]
        running: true
        onExited: root.loadTheme()
    }

    function toggleDarkMode() {
        darkMode = !darkMode
        saveTheme()
    }

    function saveTheme() {
        _isSaving = true
        let existing = {}
        try {
            const text = themeFile.text()
            if (text && text.trim() !== "") existing = JSON.parse(text.trim())
        } catch(e) {}
        existing.darkMode = root.darkMode
        const json = JSON.stringify(existing, null, 2)
        saveProc.running = false
        saveProc.command = ["sh", "-c", "mkdir -p ~/.cache/quickshell && printf '%s\\n' '" + json.replace(/'/g, "'\\''") + "' > ~/.cache/quickshell/theme.json"]
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
                if (data && data.barBgColor) {
                    root.barBgColor = data.barBgColor
                }
                if (data && data.wallpaperAccentColor) {
                    root.wallpaperAccentColor = data.wallpaperAccentColor
                }
            }
        } catch(e) {}
    }

    Component.onCompleted: {
        loadTheme()
    }
}
