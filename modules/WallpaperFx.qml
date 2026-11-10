// WallpaperFx.qml — the wallpaper transitions, drawn by the shell instead of awww.
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick

Scope {
    id: root

    // ─── test hooks: a second qs on a headless output, without awww ───
    readonly property string onlyScreen: Quickshell.env("WALLFX_ONLY") || ""
    readonly property bool dry: Quickshell.env("WALLFX_DRY") === "1"

    // ─── tuning ───
    property int msContagio: 1800
    property int msPerfil: 2000
    property int msFade: 130
    property real glow: 0.9
    property real lineW: 2.2
    property color ember: "#ff8040"
    property color ink: "#ffffff"

    // ─── one change ───
    property string targetScreen: ""
    property string oldPath: ""
    property string newPath: ""
    property string kind: "contagio"
    property string fieldPath: ""
    property string linePath: ""
    property bool autoGo: true
    // idle → loading → run (→ held, until awww has switched) → fadeout → idle;
    // in the lab (dry) loading → ready, held there until `go`.
    property string phase: "idle"
    property real t: 0
    property real fade: 0
    property bool swapped: false
    property int gen: 0               // one per change: late news from an older one is ignored
    property int swapGen: -1

    property real seed: 0
    property int readyCount: 0
    readonly property int screenCount: screens.instances.length
    readonly property bool active: phase !== "idle"
    property bool startupReady: false

    Timer {
        id: startupGuard
        interval: 1500
        running: true
        repeat: false
        onTriggered: {
            root.startupReady = true
            if (root.phase === "loading") {
                root.readyCount = 0
                watchdog.restart()
                checkReadyTimer.restart()
            }
        }
    }

    function lifted(c) {
        // A palette colour can be dark; the burning edge has to light up.
        return Qt.hsla(c.hslHue, Math.max(c.hslSaturation, 0.55),
                       Math.min(Math.max(c.hslLightness, 0.62), 0.82), 1)
    }

    function prepare(o, n, k, f, l, go, screen) {
        if (root.active) root.finish()
        root.targetScreen = screen || ""
        root.oldPath = o; root.newPath = n
        root.kind = k === "perfil" ? "perfil" : "contagio"
        root.fieldPath = f; root.linePath = l || f
        root.autoGo = go
        root.t = 0; root.fade = 0; root.readyCount = 0; root.swapped = false
        root.gen++
        root.phase = "loading"
        watchdog.restart()
        if (root.startupReady) {
            checkReadyTimer.restart()
        }
    }
    Timer {
        id: checkReadyTimer
        interval: 16
        repeat: false
        onTriggered: {
            if (root.phase !== "loading") return
            if (!root.startupReady || root.screenCount === 0) return
            for (let i = 0; i < screens.instances.length; i++) {
                const inst = screens.instances[i]
                if (inst && inst.isTarget && inst.loaded) {
                    root.screenReady()
                }
            }
        }
    }
    function screenReady() {
        if (root.phase !== "loading") return
        if (root.screenCount === 0) return
        if (!root.startupReady) return
        root.readyCount++
        const needed = root.targetScreen ? 1 : Math.max(1, root.screenCount)
        if (root.readyCount < needed) return
        watchdog.stop()
        if (root.dry) { root.fade = 1; root.phase = "ready"; if (root.autoGo) root.go(); return }
        root.go()
    }
    function go() {
        if (root.phase !== "ready" && root.phase !== "loading") return
        if (typeof Colors !== "undefined") {
            const pal = [Colors.bg, Colors.c1, Colors.c2, Colors.c3, Colors.c4, Colors.c5, Colors.dim, Colors.fg]
            const chroma = c => c.hslSaturation * (1 - Math.abs(2 * c.hslLightness - 1))
            const light = c => 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
            root.ember = root.lifted(pal.reduce((a, b) => chroma(b) > chroma(a) ? b : a))
            root.ink = pal.reduce((a, b) => light(b) > light(a) ? b : a)
        } else if (typeof Theme !== "undefined" && Theme.wallpaperAccentColor) {
            root.ember = root.lifted(Theme.wallpaperAccentColor)
            root.ink = "#ffffff"
        } else {
            root.ember = root.lifted(root.ember)
            root.ink = "#ffffff"
        }
        root.seed = Math.random() * 100
        root.phase = "run"
        run.duration = root.kind === "perfil" ? root.msPerfil : root.msContagio
        run.restart()
        if (!root.dry) fadeIn.restart()
    }
    // Uncover only when the transition has ended AND awww shows the new one.
    function maybeFinish() {
        if (root.dry) { if (!run.running) root.phase = "done"; return }
        if (run.running) return
        if (!root.swapped) { root.phase = "held"; watchdog.restart(); return }
        root.phase = "fadeout"
        fadeOut.restart()
    }
    // In the lab (WALLFX_ONLY) awww may only touch that output: the others are
    // the real desktop.
    function awwwImg(path, extra) {
        const outScreen = root.targetScreen || root.onlyScreen
        const outArgs = outScreen ? ["--outputs", outScreen] : []
        return ["awww", "img", path, "--resize", "crop", "--filter", "Lanczos3"].concat(outArgs, extra)
    }
    function swap() {
        root.swapGen = root.gen
        awww.command = root.awwwImg(root.newPath, ["--transition-type", "none"])
        awww.running = true
    }
    function finish() {
        fadeIn.stop(); run.stop(); fadeOut.stop(); watchdog.stop(); settle.stop()
        root.phase = "idle"; root.fade = 0; root.t = 0
        root.oldPath = ""; root.newPath = ""; root.fieldPath = ""; root.linePath = ""
    }

    NumberAnimation { id: fadeIn; target: root; property: "fade"; from: 0; to: 1
        duration: root.msFade; easing.type: Easing.OutQuad
        onFinished: root.swap() }
    // `t` is TIME, so it runs linear; each phase eases its own stretch in the
    // shader with the motion language's curves.
    NumberAnimation { id: run; target: root; property: "t"; from: 0; to: 1
        easing.type: Easing.Linear
        onFinished: root.maybeFinish() }
    // How the last transition ran: `qs ipc call wallfx stats`. A scene change
    // that stutters is worse than the plain fade it replaced, so this is
    // measured on the real screen, not assumed.
    property int statFrames: 0
    property real statWorst: 0
    property string lastStats: ""
    FrameAnimation {
        running: root.phase === "run"
        onRunningChanged: if (running) { root.statFrames = 0; root.statWorst = 0 }
                          else if (root.statFrames > 0)
                              root.lastStats = root.kind + ": " + root.statFrames + " frames in "
                                  + run.duration + " ms (" + Math.round(root.statFrames * 1000 / run.duration)
                                  + " fps), worst frame: " + Math.round(root.statWorst * 1000) + " ms"
        onTriggered: { root.statFrames++; if (root.statFrames > 2) root.statWorst = Math.max(root.statWorst, frameTime) }
    }

    NumberAnimation { id: fadeOut; target: root; property: "fade"; from: 1; to: 0
        duration: root.msFade; easing.type: Easing.OutQuad
        onFinished: root.finish() }

    Process {
        id: awww
        // If awww did not switch, uncovering would bring the OLD one back at the
        // end: better to stop here and let awww try on its own.
        // An awww from a change that has since been replaced is left to finish
        // on its own: killing it, or reacting to it, would cut the new one.
        onExited: (code) => {
            if (root.swapGen !== root.gen) return
            if (code === 0) { settle.restart(); return }
            const n = root.newPath
            root.finish()
            Quickshell.execDetached(root.awwwImg(n, ["--transition-type", "fade", "--transition-duration", "0.5"]))
        }
    }
    // awww has the new image; give it two frames to present it before anything
    // can uncover it.
    Timer { id: settle; interval: 40; onTriggered: { root.swapped = true; root.maybeFinish() } }

    // Two ways to get stuck, two ways out: the images never load (awww changes
    // on its own), or awww never answers (the layer, already showing the new
    // wallpaper, steps aside anyway instead of staying on top for good).
    Timer {
        id: watchdog; interval: 8000
        onTriggered: {
            console.warn("WallpaperFx: Watchdog timed out loading textures for:", root.newPath)
            const n = root.newPath, loading = root.phase === "loading"
            root.finish()
            if (loading && !root.dry && n)
                Quickshell.execDetached(root.awwwImg(n, ["--transition-type", "fade", "--transition-duration", "0.5"]))
        }
    }

    // ─── WallFx Background Model Daemon ───
    Process {
        id: daemonProc
        command: [Paths.script("wallfx-daemon.py")]
        running: true

        onExited: (code, status) => {
            if (code !== 42) {
                console.warn("[WallpaperFx] wallfx-daemon exited with code", code, "- restarting in 3s")
                daemonRestartTimer.restart()
            }
        }
    }

    Timer {
        id: daemonRestartTimer
        interval: 3000
        repeat: false
        onTriggered: {
            daemonProc.running = true
        }
    }

    IpcHandler {
        target: "wallfx"
        function play(oldImg: string, newImg: string, kind: string, field: string, line: string, targetMon: string): string {
            root.prepare(oldImg, newImg, kind, field, line, true, targetMon); return "ok"
        }
        // For tests: load and hold the first frame; `go` starts it.
        function prepare(oldImg: string, newImg: string, kind: string, field: string, line: string, targetMon: string): string {
            root.prepare(oldImg, newImg, kind, field, line, false, targetMon); return "ok"
        }
        function go(): string { root.go(); return root.phase }
        function state(): string { return root.phase }
        function stats(): string { return root.lastStats }
        function stop(): string { root.finish(); return "ok" }
        function tune(key: string, value: string): string {
            root[key] = Number(value)
            return key + "=" + root[key]
        }
    }

    Variants {
        id: screens
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            visible: root.active && (!root.targetScreen || modelData.name === root.targetScreen)
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            anchors { top: true; bottom: true; left: true; right: true }
            mask: Region {}                       // clicks go through to the desktop
            WlrLayershell.layer: root.active ? WlrLayer.Overlay : WlrLayer.Bottom
            WlrLayershell.namespace: "quickshell:wallfx"

            readonly property bool isTarget: !root.targetScreen || modelData.name === root.targetScreen
            readonly property bool loaded: !isTarget || (oldImg.status === Image.Ready && newImg.status === Image.Ready
                && fieldImg.status === Image.Ready && lineImg.status === Image.Ready)
            onLoadedChanged: if (loaded && isTarget) root.screenReady()

            // Decoded at 100% original resolution with smooth trilinear mipmap filtering (fill entire screen, no borders)
            Image { id: oldImg; visible: false; asynchronous: true; cache: false
                smooth: true; mipmap: true
                source: root.oldPath ? "file://" + root.oldPath : ""
                fillMode: Image.PreserveAspectCrop }
            Image { id: newImg; visible: false; asynchronous: true; cache: false
                smooth: true; mipmap: true
                source: root.newPath ? "file://" + root.newPath : ""
                fillMode: Image.PreserveAspectCrop }
            // The maps hold numbers, not colours: contagion's are read texel by
            // texel (no filtering), the outline's are interpolated on purpose.
            Image { id: fieldImg; visible: false; asynchronous: true; cache: false
                smooth: root.kind === "perfil"
                source: root.fieldPath ? "file://" + root.fieldPath : "" }
            Image { id: lineImg; visible: false; asynchronous: true; cache: false
                source: root.linePath ? "file://" + root.linePath : "" }

            // awww's "crop": scale to cover the entire screen with no borders, centred.
            function crop(img) {
                const iw = Math.max(img.implicitWidth, 1), ih = Math.max(img.implicitHeight, 1)
                const s = Math.max(win.width / iw, win.height / ih)
                const w = win.width / (iw * s), h = win.height / (ih * s)
                return Qt.vector4d((1 - w) / 2, (1 - h) / 2, w, h)
            }

            ShaderEffect {
                anchors.fill: parent
                visible: win.loaded
                opacity: root.fade
                property var oldTex: oldImg
                property var newTex: newImg
                property var fieldTex: fieldImg
                property var lineTex: lineImg
                property real t: root.t
                property real mode: root.kind === "perfil" ? 1 : 0
                property real sw: win.width
                property real sh: win.height
                property real fw: Math.max(fieldImg.implicitWidth, 1)
                property real fh: Math.max(fieldImg.implicitHeight, 1)
                property real lw: Math.max(lineImg.implicitWidth, 1)
                property real lh: Math.max(lineImg.implicitHeight, 1)
                property real glow: root.glow
                property real lineW: root.lineW
                property real sdRange: 16
                property real seed: root.seed
                property vector4d cropOld: win.crop(oldImg)
                property vector4d cropNew: win.crop(newImg)
                property color ember: root.ember
                property color ink: root.ink
                // Versioned name: Qt caches compiled shaders by URL (see TopShell).
                fragmentShader: Qt.resolvedUrl("shaders/wallfx.v16.frag.qsb")
            }
        }
    }
}
