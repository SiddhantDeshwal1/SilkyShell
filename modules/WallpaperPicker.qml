// WallpaperPicker.qml — ilyamiro coverflow (parallelogram / skew cards)
// Ported to quickshell modules with smooth skew transforms and fast thumbnail browsing.
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import QtQuick.Effects
import Qt.labs.folderlistmodel

Scope {
    id: root
    property bool open: false
    property var targetScreen: null
    readonly property string home: Quickshell.env("HOME")
    readonly property string wallsDir: home + "/Pictures/wallpapers"
    readonly property string thumbsDir: home + "/.cache/wallpaper-thumbs"

    function updateActiveScreen() {
        let monName = ""
        if (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor) {
            monName = Hyprland.focusedMonitor.name
        }
        if (monName && Quickshell.screens) {
            for (let i = 0; i < Quickshell.screens.length; i++) {
                if (Quickshell.screens[i].name === monName) {
                    root.targetScreen = Quickshell.screens[i]
                    return
                }
            }
        }
        root.targetScreen = (Quickshell.screens && Quickshell.screens.length > 0) ? Quickshell.screens[0] : null
    }

    // Resolves thumbnail filename/URL back to original wallpaper path robustly
    function originalOf(thumbName) {
        if (!thumbName) return ""
        var str = String(thumbName)
        if (str.indexOf("file://") === 0) {
            str = str.substring(7)
        }
        try {
            str = decodeURIComponent(str)
        } catch (e) {}

        var slashIdx = str.lastIndexOf("/")
        var base = (slashIdx !== -1) ? str.substring(slashIdx + 1) : str
        var origName = base.replace(/\.jpg$/i, "")

        // 1. Check exact match in origModel
        for (var i = 0; i < origModel.count; ++i) {
            var fn = origModel.get(i, "fileName")
            if (fn === origName) {
                return root.wallsDir + "/" + fn
            }
        }

        // 2. Fallback: match by stem in case the thumbnail dropped or changed the original extension
        var dotIdx = origName.lastIndexOf(".")
        var stem = (dotIdx !== -1) ? origName.substring(0, dotIdx) : origName
        for (var j = 0; j < origModel.count; ++j) {
            var ofn = origModel.get(j, "fileName")
            var odot = ofn.lastIndexOf(".")
            var ostem = (odot !== -1) ? ofn.substring(0, odot) : ofn
            if (ostem === stem || ostem === origName) {
                return root.wallsDir + "/" + ofn
            }
        }

        // 3. Direct path fallback
        return root.wallsDir + "/" + origName
    }

    function apply(thumbName) {
        const mon = (root.targetScreen && root.targetScreen.name) ||
                    (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
        Quickshell.execDetached([root.home + "/.config/quickshell/scripts/set-wallpaper.sh", root.originalOf(thumbName), mon])
        root.open = false
    }

    // Refreshes the thumbnail cache: when the shell starts and every time the picker opens.
    Process {
        id: thumbsProc
        command: ["bash", root.home + "/.config/quickshell/scripts/wall-thumbs.sh"]
        onExited: {
            if (wallModel.count === 0) {
                wallModel.folder = ""
                wallModel.folder = "file://" + root.thumbsDir
            }
            if (origModel.count === 0) {
                origModel.folder = ""
                origModel.folder = "file://" + root.wallsDir
            }
        }
    }
    function refreshThumbs() {
        thumbsProc.running = false
        thumbsProc.running = true
    }

    // Opening the picker warms up transitions for wallpapers
    Process {
        id: warmProc
        command: ["nice", "-n", "19", "ionice", "-c", "3", root.home + "/.local/bin/wallfx", "warm"]
    }
    function warmTransitions() {
        if (!warmProc.running) warmProc.running = true
    }

    Component.onCompleted: {
        root.updateActiveScreen()
        root.refreshThumbs()
    }

    GlobalShortcut {
        name: "wallpaper"
        description: "Wallpaper picker"
        onPressed: {
            if (!root.open) {
                root.updateActiveScreen()
                root.open = true
            } else {
                root.open = false
            }
        }
    }

    IpcHandler {
        target: "wallpaper"
        function toggle() {
            if (!root.open) {
                root.updateActiveScreen()
                root.open = true
            } else {
                root.open = false
            }
        }
        function open(screenName: string) {
            if (screenName && Quickshell.screens) {
                for (let i = 0; i < Quickshell.screens.length; i++) {
                    if (Quickshell.screens[i].name === screenName) {
                        root.targetScreen = Quickshell.screens[i]
                        break
                    }
                }
            } else {
                root.updateActiveScreen()
            }
            root.open = true
        }
        function close()  { root.open = false }
    }

    HyprlandFocusGrab {
        windows: [win]
        active: root.open
        onCleared: root.open = false
    }

    FolderListModel {
        id: wallModel
        folder: "file://" + root.thumbsDir
        nameFilters: ["*.jpg"]
        showDirs: false
        sortField: FolderListModel.Name
    }

    FolderListModel {
        id: origModel
        folder: "file://" + root.wallsDir
        nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.heic", "*.JPG", "*.JPEG", "*.PNG", "*.WEBP", "*.HEIC"]
        showDirs: false
        sortField: FolderListModel.Name
    }

    PanelWindow {
        id: win
        screen: root.targetScreen
        visible: root.open || stage.opacity > 0
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusiveZone: 0
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "quickshell:wallpaper"

        Item {
            id: stage
            anchors.fill: parent
            focus: true
            opacity: root.open ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: root.open ? 210 : 110
                    easing.type: root.open ? Easing.OutCubic : Easing.InCubic
                }
            }

            Connections {
                target: root
                function onOpenChanged() {
                    if (!root.open) return
                    stage.forceActiveFocus()
                    root.refreshThumbs()
                    root.warmTransitions()
                }
            }

            Keys.onEscapePressed: root.open = false
            Keys.onLeftPressed:   carousel.decrementCurrentIndex()
            Keys.onRightPressed:  carousel.incrementCurrentIndex()
            Keys.onReturnPressed: carousel.applyCurrent()
            Keys.onEnterPressed:  carousel.applyCurrent()
            WheelHandler {
                onWheel: (e) => {
                    if (e.angleDelta.y > 0 || e.angleDelta.x > 0) carousel.decrementCurrentIndex()
                    else carousel.incrementCurrentIndex()
                }
            }

            // Click on empty area closes
            MouseArea {
                anchors.fill: parent
                z: -1
                onClicked: root.open = false
            }

            // ----- ilyamiro coverflow (parallelogram / skew cards) -----
            ListView {
                id: carousel
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    verticalCenterOffset: 12
                }
                height: 560
                orientation: ListView.Horizontal
                model: wallModel
                property real iw: 720                            // base width of the hero (fixed)
                property real ih: 406                            // base height of the hero (~16:9, fixed)
                property real skew: -0.35
                property real bw: 3
                property real slotW: 360                         // FIXED scroll step
                property real sideBase: 0.56                     // scale of the 1st neighbour
                readonly property real imgW: iw + ih * Math.abs(skew) + 12
                spacing: 0
                clip: false
                cacheBuffer: 2500
                highlightRangeMode: ListView.StrictlyEnforceRange
                preferredHighlightBegin: (width - slotW) / 2
                preferredHighlightEnd:   (width + slotW) / 2
                highlightMoveDuration: 380
                highlightMoveVelocity: -1
                snapMode: ListView.SnapToItem
                boundsBehavior: Flickable.StopAtBounds
                maximumFlickVelocity: 4000

                function applyCurrent() {
                    if (currentIndex < 0 || wallModel.count <= currentIndex) return
                    root.apply(wallModel.get(currentIndex, "fileName"))
                }

                delegate: Item {
                    id: slot
                    width: carousel.slotW
                    height: carousel.height
                    // continuous distance to the centre of the viewport, in slots.
                    readonly property real d: (x + width / 2 - (carousel.contentX + carousel.width / 2)) / carousel.slotW
                    readonly property real ad: Math.abs(d)
                    // Scale: 1.0 at the centre (sharp hero at real size) and it falls
                    // smoothly towards the back, symmetric on both sides.
                    readonly property real sc: ad <= 1
                        ? carousel.sideBase + (1 - carousel.sideBase) * Math.pow(1 - ad, 1.35)
                        : carousel.sideBase * Math.pow(0.86, ad - 1)
                    z: Math.round(100 - ad * 10)
                    opacity: Math.max(0, Math.min(1, 1.15 - 0.34 * ad))

                    Item {
                        id: card
                        anchors.centerIn: parent
                        width: carousel.iw
                        height: carousel.ih
                        scale: slot.sc                           // GPU transform only
                        transformOrigin: Item.Center
                        // Shear relative to the vertical CENTRE -> it centres itself.
                        transform: Matrix4x4 {
                            matrix: Qt.matrix4x4(1, carousel.skew, 0, -carousel.skew * carousel.ih / 2,
                                                0, 1,             0, 0,
                                                0, 0,             1, 0,
                                                0, 0,             0, 1)
                        }

                        // Frame: dark base + subtle edge.
                        Rectangle {
                            anchors.fill: parent
                            color: "#12161f"
                            border.width: 1
                            border.color: "#30ffffff"
                        }

                        // Straight content (inverse shear) + PreserveAspectCrop.
                        // FIXED size and sourceSize -> it always covers the
                        // parallelogram (no clipped corners) and keeps the same framing.
                        Item {
                            anchors.fill: parent
                            anchors.margins: carousel.bw
                            clip: true
                            Image {
                                anchors.centerIn: parent
                                width: carousel.imgW
                                height: carousel.ih
                                fillMode: Image.PreserveAspectCrop
                                source: model.fileUrl
                                asynchronous: true
                                cache: true
                                mipmap: true
                                sourceSize: Qt.size(carousel.imgW, carousel.ih)
                                transform: Matrix4x4 {
                                    matrix: Qt.matrix4x4(1, -carousel.skew, 0, carousel.skew * carousel.ih / 2,
                                                        0, 1,              0, 0,
                                                        0, 0,              1, 0,
                                                        0, 0,              0, 1)
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: slot.ad < 0.5 ? carousel.applyCurrent() : (carousel.currentIndex = index)
                        }
                    }
                }
            }

            // Empty state.
            Text {
                anchors.centerIn: parent
                visible: wallModel.count === 0
                text: "No wallpapers found in ~/Pictures/wallpapers"
                color: "#e0e0e0"
                font.pixelSize: 18
                opacity: 0.85
                layer.enabled: true
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: "#000000"
                    shadowBlur: 1.0
                    blurMax: 16
                    shadowVerticalOffset: 0
                }
            }
        }
    }
}
