pragma Singleton
import QtQuick

// AnimStyle — Caelestia duration tokens & animation helpers
QtObject {
    // Duration tokens (ms) — mirrors Caelestia AnimDurations
    readonly property int short1:     50
    readonly property int short2:    100
    readonly property int short3:    150
    readonly property int short4:    200
    readonly property int medium1:   250
    readonly property int medium2:   300
    readonly property int medium3:   350
    readonly property int medium4:   400
    readonly property int long1:     450
    readonly property int long2:     500
    readonly property int extraLong1: 700
    readonly property int extraLong2: 900

    // Standard overshoot for Caelestia spatial springs
    readonly property real springOvershootFast: 1.25
    readonly property real springOvershootDefault: 1.15
    readonly property real springOvershootSubtle: 1.08
}
