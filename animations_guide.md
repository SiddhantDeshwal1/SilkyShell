# Caelestia Shell: Complete Animation, Motion & CSS/Styling Architecture Guide

> **Target Repository**: `quickshell/extra/shell` (Caelestia Shell)  
> **Framework**: Quickshell (Qt 6 / QML / C++ / GLSL)  
> **Design Philosophy**: Material Design 3 (Material You) Expressive Motion, Kinetic Physics, Parametric SDF Shaders, and Fluid Shape Morphing.

---

## Table of Contents
1. [Core Motion Design Philosophy & Easing Curves](#1-core-motion-design-philosophy--easing-curves)
2. [Animation Primitives & Helpers (QML & C++)](#2-animation-primitives--helpers-qml--c)
3. [Design Tokens, Styling & CSS System](#3-design-tokens-styling--css-system)
4. [Control Components & Interactive Micro-Interactions](#4-control-components--interactive-micro-interactions)
5. [Organic SDF Blobs & Shader-Level Motion](#5-organic-sdf-blobs--shader-level-motion)
6. [Module-by-Module Animation Catalog](#6-module-by-module-animation-catalog)
   - [Taskbar / Bar & Popouts](#taskbar--bar--popouts)
   - [Dashboard & Media](#dashboard--media)
   - [Launcher & Wallpaper Picker](#launcher--wallpaper-picker)
   - [Lock Screen & PAM Authentication](#lock-screen--pam-authentication)
   - [Nexus (Settings & Control Center)](#nexus-settings--control-center)
   - [Notifications & Sidebar](#notifications--sidebar)
   - [Utilities, Screen Recorder & Toasts](#utilities-screen-recorder--toasts)
   - [OSD (On-Screen Display)](#osd-on-screen-display)
   - [Session (Power Menu)](#session-power-menu)
7. [Attention-to-Detail Summary Matrix](#7-attention-to-detail-summary-matrix)

---

## 1. Core Motion Design Philosophy & Easing Curves

Caelestia Shell implements **Material Design 3 (M3) Expressive Motion**. Motion is not treated as cosmetic decoration, but as an organic physical medium with weight, spring momentum, and continuous fluidity.

### 1.1 Cubic Bézier Curves (`AnimCurves`)
Defined in C++ (`extra/shell/plugin/src/Caelestia/Config/tokens.hpp` & `anim.cpp`):

| Curve Token | Control Points $(P_1, P_2)$ / Bézier Segments | Character & Purpose |
| :--- | :--- | :--- |
| **`emphasized`** | Multi-segment cubic spline: `(0.05, 0, 0.133, 0.06)`, `(0.167, 0.4, 0.208, 0.82)`, `(0.25, 1, 1, 1)` | Signature M3 curve with deep anticipation, sudden acceleration, and graceful deceleration. |
| **`emphasizedAccel`** | `(0.3, 0, 0.8, 0.15)` to `(1, 1)` | Rapid exit velocity curve for elements leaving the screen. |
| **`emphasizedDecel`** | `(0.05, 0.7, 0.1, 1)` to `(1, 1)` | Soft landing curve for incoming popups and dismissals snapping back. |
| **`standard`** | `(0.2, 0, 0, 1)` to `(1, 1)` | Utility curve for simple state shifts and standard properties. |
| **`standardAccel`** | `(0.3, 0, 1, 1)` to `(1, 1)` | Linear-biased acceleration curve. |
| **`standardDecel`** | `(0, 0, 0, 1)` to `(1, 1)` | Immediate deceleration curve for direct feedback. |
| **`expressiveFastSpatial`** | `(0.42, 1.67, 0.21, 0.9)` to `(1, 1)` | **Spring overshoot curve**: reaches $167\%$ progress before settling. Used for snappy physical feedback. |
| **`expressiveDefaultSpatial`** | `(0.38, 1.21, 0.22, 1)` to `(1, 1)` | **Natural spring overshoot**: overshoots by $21\%$. Used for drawer slides, resizing, and movements. |
| **`expressiveSlowSpatial`** | `(0.39, 1.29, 0.35, 0.98)` to `(1, 1)` | **Heavy spring curve**: overshoots by $29\%$. Used for large dialogs and major surface expansions. |
| **`expressiveFastEffects`** | `(0.31, 0.94, 0.34, 1)` to `(1, 1)` | Snappy fade/dissolve curve (150ms). |
| **`expressiveDefaultEffects`** | `(0.34, 0.8, 0.34, 1)` to `(1, 1)` | Default crossfade and opacity curve (200ms). |
| **`expressiveSlowEffects`** | `(0.34, 0.88, 0.34, 1)` to `(1, 1)` | Smooth color and shader blending curve (300ms). |

### 1.2 Duration Tokens (`AnimDurationTokens`)
Base durations are scaled globally via `Config.appearance.anim.durations.scale`:

- **Small**: `200ms`
- **Normal**: `400ms`
- **Large**: `600ms`
- **ExtraLarge**: `1000ms`
- **Expressive Fast Spatial**: `350ms`
- **Expressive Default Spatial**: `500ms`
- **Expressive Slow Spatial**: `650ms`
- **Expressive Fast Effects**: `150ms`
- **Expressive Default Effects**: `200ms`
- **Expressive Slow Effects**: `300ms`

---

## 2. Animation Primitives & Helpers (QML & C++)

### 2.1 `Anim.qml` (`NumberAnimation` Wrapper)
The foundational building block throughout the shell.
- **Enum Types**: `StandardSmall`, `Standard`, `StandardLarge`, `StandardExtraLarge`, `EmphasizedSmall`, `Emphasized`, `EmphasizedLarge`, `EmphasizedExtraLarge`, `FastSpatial`, `DefaultSpatial`, `SlowSpatial`, `FastEffects`, `DefaultEffects`, `SlowEffects`.
- **Default**: `type: Anim.DefaultSpatial` (500ms duration, `expressiveDefaultSpatial` overshoot easing).

### 2.2 `AnchorAnim.qml` (`AnchorAnimation` Wrapper)
Animates QML anchor re-attachments with full support for expressive spatial/standard/emphasized curves.

### 2.3 `CAnim.qml` (`ColorAnimation` Wrapper)
Universal color interpolator:
```qml
ColorAnimation {
    duration: Tokens.anim.durations.expressiveSlowEffects // 300ms
    easing: Tokens.anim.expressiveSlowEffects
}
```

### 2.4 `AnimLoader.qml`
Asynchronous component loader that automatically orchestrates exit and entrance animations when switching components:
1. `Anim { property: "opacity"; to: 0; type: outAnimType /* FastEffects */ }`
2. `ScriptAction { root.sourceComponent = root.sourceComp }`
3. `Anim { property: "opacity"; to: 1; type: inAnimType /* DefaultEffects */ }`

---

## 3. Design Tokens, Styling & CSS System

Caelestia uses a tokenized CSS/theming architecture driven by Material Design 3 and variable fonts.

### 3.1 Color Palette & Dynamic Transparency (`Colours.qml`)
- **Full M3 Semantic Palette**: `primary`, `onPrimary`, `primaryContainer`, `onPrimaryContainer`, `secondary`, `tertiary`, `surface`, `surfaceDim`, `surfaceBright`, `surfaceContainerLowest` through `surfaceContainerHighest`, `outline`, `outlineVariant`, `error`, `success`, `shadow`, `scrim`.
- **Luminance-Aware Dynamic Alpha Offsetting (`alterColour`)**:
  Calculates wallpaper luminance using the perceived luminance formula:
  $$\text{Luminance} = \sqrt{0.299 R^2 + 0.587 G^2 + 0.114 B^2}$$
  Alters layered colors dynamically against wallpaper brightness so contrast is preserved when transparency is enabled.
- **Hyprland Layer Rule Live Blur Sync**:
  Sends IPC commands to Hyprland on color or transparency changes to adjust background blur and `ignore_alpha` in real-time.

### 3.2 Dynamic Elevation & Drop Shadows (`Elevation.qml`)
Material elevation levels $[0, 1, 3, 6, 8, 12]\,\text{dp}$ calculate drop shadows using parabolic formulas:
- `blur: (dp * 5) ** 0.7`
- `spread: -dp * 0.3 + (dp * 0.1) ** 2`
- `offset.y: dp / 2`
- `color: Qt.alpha(Colours.palette.m3shadow, 0.7)`
- **Animation**: `Behavior on dp { Anim { type: Anim.SlowEffects } }` smoothly animates shadow elevation levels on hover/press!

### 3.3 Geometry & Radius Tokens
- **Corner Rounding**: `extraSmall` (4px), `small` (8px), `medium` (12px), `large` (16px), `largeIncreased` (20px), `extraLarge` (28px), `extraLargeIncreased` (32px), `extraExtraLarge` (48px), `full` (pill/circle).
- Scaled globally with `Tokens.rounding.scale`.

### 3.4 Typography & Variable Font Optical Axes
- **Variable Font**: `Google Sans Flex` & `Material Symbols Rounded`.
- **Variable Axes**:
  - `ROND` (Roundness axis): Set to `25` for rounded letterforms.
  - `FILL` (Material Symbols fill): Animated smoothly between `0.0` and `1.0`.
  - `GRAD` (Optical grade): Automatically shifts between `0` (light theme) and `-25` (dark theme) for optical weight compensation.

### 3.5 Auto-Animated Base Elements
- **`StyledRect.qml` & `StyledClippingRect.qml`**: Background color changes automatically run `Behavior on color { CAnim {} }`.
- **`StyledText.qml`**: Color changes transition via `CAnim {}`. When `animate: true`, text content changes execute a two-stage sequential opacity fade (fade out in 150ms, swap text string, fade in in 200ms).

---

## 4. Control Components & Interactive Micro-Interactions

### 4.1 StateLayer (`StateLayer.qml`) — Material 3 Custom Ripple Engine
Implements authentic Material 3 touch/click ripple physics without relying on heavy external libraries:
- **Geometry**: Rendered via `QtQuick.Shapes` `Shape` using curved paths (`PathArc` and `PathLine`) matching the parent's corner radii (`topLeftRadius`, `bottomRightRadius`, etc.).
- **Ripple Expansion**: Originates at exact press coordinates $(x, y)$. Computes maximum corner distance:
  $$\text{endRadius} = \left(\max(\text{dist}(0,0), \text{dist}(w,0), \text{dist}(0,h), \text{dist}(w,h))^{0.5} + \text{morph}\right) \times 1.3$$
- **Radial Gradient Dissipation**:
  - Inner stop: Fully opaque `base.color`.
  - Middle stop: Interpolated dynamically based on current expansion percentage.
  - Outer stop: Alpha fades out as circle approaches `endRadius`.
- **Timing**: Expands over `600ms` (`expressiveSlowEffects * 2`), fades out over `300ms` (`Anim.SlowEffects`), hover layer transitions opacity `0.08 <-> 0` over `200ms`.

### 4.2 Button Family (`ButtonBase.qml`, `IconButton.qml`, `IconTextButton.qml`, `SplitButton.qml`)
- **Corner Radius Morphing**:
  - Default: `16px` (`large`) or fully round.
  - On Checked: Morphs to `12px` (`medium`).
  - On Pressed: Physically compresses corner radius to `8px` (`small`) with `Anim.DefaultEffects` (200ms)!
- **Shape Morph Expansion**: When `shapeMorph: true`, pressing the button expands the bounding box by `24px` with `Anim.FastSpatial` (350ms overshoot curve).
- **Icon Fill Animation**: Icon `fill` axis animates between `0.0` (unselected) and `1.0` (selected) with `Anim.DefaultEffects`.
- **SplitButton**: Expand chevron smoothly rotates $0^\circ \leftrightarrow 180^\circ$, while adjacent inner corners morph from `6px` to `height / 2` when open!

### 4.3 `StyledSwitch.qml` — Vector Morphing Toggle
- **Squash & Stretch**: Thumb `implicitWidth` stretches from `height` to `height * 1.2` while pressed, snapping into position on release with `Anim.FastSpatial`.
- **Vector Shape Morphing Path**: The thumb's internal glyph morphs via dynamic vector endpoints:
  - **Unchecked ('X' cross)**: Two crossing diagonals.
  - **Checked (Checkmark)**: Morphs coordinates into checkmark vector `(0.15, 0.5) -> (0.4, 0.7) -> (0.85, 0.2)`.
  - **Pressed (Dash pill)**: Flattens into a single horizontal bar `(0.2, 0.5) -> (0.8, 0.5)`.
  - All 4 points animate simultaneously using `PropertyAnimation` (`expressiveFastSpatial`, 350ms).

### 4.4 `StyledTextField.qml` — Floating Label with Dynamic Notch Cutout
- **Floating Label Transition**: On focus or text entry, placeholder text floats from center to top border (`scale: 0.85`, anchor shift) using `AnchorAnim` (200ms) and `Anim.DefaultEffects`.
- **Dynamic Outline Notch Cutout**: In outlined mode, the border is rendered via `ShapePath`. When the label floats up, `outlineGapScale` animates from `0` to `1`, dynamically cutting an exact open gap in the top stroke to house the label text without colliding!
- **Border Stroke & Color**: Stroke width expands from 1px to 2px (`Anim {}`), color transitions to `m3primary` or `m3error` (`CAnim {}`).

### 4.5 `StyledSlider.qml` & `WavyLine` — Squiggly Audio Seek Bar
- **Sinusoidal Wave Mode**: Implements Android 13/14's squiggly wave progress bar via C++ `WavyLine` component.
- **Wave Phase Loop**: `waveProgress` continuously animates from `0` to `1` over `1000ms` (Linear loop) when playing.
- **Wave Amplitude Transition**: `amplitudeMultiplier` morphs between `0.0` (straight line) and `0.5` (wave) via `Anim.DefaultEffects`.
- **Handle Expansion**: On press/drag, handle height expands $3.5\times$ with `Anim.FastSpatial`.

### 4.6 `LoadingIndicator.qml` — Physics Spring Shape Morphing Spinner
Implements Android's flagship shape-morphing loading spinner powered by a **real damped harmonic oscillator spring simulation**:
- **Spring Parameters**: Stiffness $\omega_n^2 = 180$, Damping ratio $\zeta = 0.6$.
- **Equations of Motion (evaluated per frame in `FrameAnimation`)**:
  $$x(t) = 1 - e^{-\zeta \omega_n t} \left(\cos(\omega_d t) + \frac{\zeta \omega_n}{\omega_d} \sin(\omega_d t)\right)$$
  $$v(t) = e^{-\zeta \omega_n t} \left(\frac{\omega_n^2}{\omega_d}\right) \sin(\omega_d t)$$
- **Shape Morphing Sequence**: Morphs through 7 Material shapes (`SoftBurst` $\rightarrow$ `Cookie9Sided` $\rightarrow$ `Pentagon` $\rightarrow$ `Pill` $\rightarrow$ `Sunny` $\rightarrow$ `Cookie4Sided` $\rightarrow$ `Oval`) every `650ms`.
- **Velocity Squish/Stretch**: Scale squishes along instantaneous velocity $1 + v(t) \cdot \frac{\text{morphScale}}{v_{\max}}$.
- **Rotational Impulse**: Background rotation (0 to $360^\circ$ over 4666ms) combined with a $+60^\circ$ rotational impulse on each shape morph.

### 4.7 `StyledProgressBar.qml` & `CircularIndicator.qml`
- **Linear Indeterminate Segments**: Multi-segment indicator bounds expand and contract with gap ramp-downs at edges (`LinearIndicatorManager`).
- **Graceful Exit**: On completion, animates `completeEndProgress` to 1 instead of abruptly vanishing.

### 4.8 `VerticalFadeListView.qml` / `VerticalFadeFlickable.qml`
- Shader mask-based top and bottom edge fading gradients.
- Detects scroll boundaries and rebound overscroll physics, fading out gradient edges with `Anim.SlowEffects` (300ms) when reaching ends.

---

## 5. Organic SDF Blobs & Shader-Level Motion

One of the most advanced visual features in Caelestia Shell is the **Signed Distance Field (SDF) Fluid Blob Engine** (`Caelestia.Blobs` & `blob.frag`).

```
┌────────────────────────────────────────────────────────┐
│                   SDF BLOB GROUP                       │
│                                                        │
│  [Bar Frame] ─── (Circular smin) ───► [Drawer Panel]   │
│       │                                     │          │
│       ▼                                     ▼          │
│  Border Sink Pocket                   Deform Matrix    │
│  (Smooth recess cutout)               (Velocity Squish)│
└────────────────────────────────────────────────────────┘
```

### 5.1 Circular Smooth Minimum (`smin`) & Smooth Maximum (`smax`)
Unlike traditional polynomial / squircle blends that distort entire bounding boxes, Caelestia uses **Circular `smin`** in GLSL:
```glsl
float smin(float a, float b, float k) {
    return max(k, min(a, b)) - length(max(vec2(k) - vec2(a, b), vec2(0.0)));
}
```
- Creates true circular-arc blend fillets of radius $k$ between the taskbar and sliding panels.
- Surfaces merge organically like liquid mercury / metaballs as drawers slide out.

### 5.2 Dynamic Velocity Deformation Matrices (`Matrix4x4`)
- When any drawer panel (Dashboard, Launcher, Session, Sidebar, OSD, Utilities, Popouts) moves, the C++ engine computes an instantaneous velocity deformation matrix (`deformMatrix`).
- The panel background blob and all UI elements inside the panel apply `transform: Matrix4x4 { matrix: panelBg.deformMatrix }`, physically squishing, stretching, and tilting UI contents in real-time in sync with the fluid blob!

### 5.3 Asymmetric Border Sinks
When a panel closes into the screen border, `blob.frag` tracks the opposite edge and generates a recessed pocket (`dInner -= sinkValue`) so the border smoothly swallows the drawer without causing unsightly bulge artifacts.

---

## 6. Module-by-Module Animation Catalog

### Taskbar / Bar & Popouts

#### `ActiveIndicator.qml` — Stretchy Rubber-Band Workspace Pill
- **Asymmetric Leading/Trailing Edge Timing**:
  - When moving **up**: Leading top edge moves at `500ms` (`expressiveDefaultSpatial`), trailing bottom edge stretches at `750ms` ($1.5\times$).
  - When moving **down**: Leading bottom edge moves at `500ms`, trailing top edge stretches at `750ms`.
  - **Result**: The active workspace indicator physically stretches like rubber while moving between workspaces, then catches up and snaps into place!
- **`Colouriser` Live Shader**: Inverts and recolors the underlying workspace text/icons from `m3onSurface` to `m3onPrimary` in real-time as the pill slides over them.

#### `Workspace.qml` — Dynamic Shape Morphing
- When a workspace is focused, the indicator shape morphs into a randomized Material Shape from 18 shapes (`Slanted`, `Sunny`, `Diamond`, `Ghostish`, `Clover4Leaf`, `SoftBurst`, etc.) over `500ms`.
- Unfocused occupied workspace morphs to `Square`, empty workspace morphs to `Circle`.
- Shape scale transitions: Focused ($2/3$), Occupied ($1/3$), Empty ($1/4$).

#### `OccupiedBg.qml` — Connected Morphing Background Pill
- Bridges adjacent occupied workspaces into a single continuous pill.
- When neighboring workspaces are occupied, corner radii morph from `width / 2` (rounded cap) to `0` (continuous join) with `Anim.DefaultEffects`.

#### `GapMarkers.qml` — Non-Consecutive Workspace Separator
- Separator line dynamically shifts vertical position (`shift`) when adjacent workspaces gain focus with `Anim {}`.

#### `ActiveWindow.qml` — Rotated Dual-Buffer Title Crossfade
- Window title rotated $90^\circ$ or $270^\circ$.
- Uses two title buffers (`text1`, `text2`) that crossfade opacities (`Anim.DefaultEffects`) on window focus/title changes while the bar height animates with `Anim {}`.

#### `ClipWrapper.qml` — Fluid Popout Tracking
- When switching between popout modules on the bar, the popout window does not close and re-open; it smoothly slides vertically along the bar (`Behavior on y { Anim {} }`) to align with the newly clicked icon center.

---

### Dashboard & Media

#### `Tabs.qml` — Sliding Active Pill Indicator
- Tab indicator bar slides along the X-axis (`Behavior on x { Anim {} }`) and morphs width (`Behavior on implicitWidth { Anim {} }`).
- Tab icons animate their variable font `fill` axis $0.0 \leftrightarrow 1.0$.

#### `CoverVisualiser.qml` — Parametric Shape-Conforming Audio Visualizer
- 360-degree radial CAVA audio visualizer bars surround the rotating album cover.
- Calls `cover.shape.distanceAtAngle(angle)` in real-time so the audio bars conform to the exact rotating 9-sided cookie shape perimeter!

#### `CoverArt.qml` — Continuous Subtle Vinyl Rotation
- Rotating `MaterialShape.Cookie12Sided` album cover spins continuously ($360^\circ \rightarrow 0^\circ$ over 23.5 seconds, linear loop) while music is playing (`paused: !Players.active?.isPlaying`).
- Glowing drop shadow (`MultiEffect` blurMax 1, opacity 0.3).

#### `BackgroundShapes.qml` — Ambient Drifting Particles
- 14 procedural Material shapes drift across 2D space with physics velocities ($v_x, v_y, v_r$) evaluated on `FrameAnimation` with toroidal screen wrapping. Active only during music playback.

#### `BatteryTank.qml` — Liquid Tank & Two-Tier Typography
- Liquid level fill height animates with `Anim {}`.
- Uses two layered text layouts: as the liquid level rises, text characters change color at the liquid boundary line from `m3onSurface` to inverse `m3onSecondary`!
- Charging bolt icon pops in with `Anim.FastSpatial` scale overshoot and `Anim.FastEffects` opacity.

---

### Launcher & Wallpaper Picker

#### `Wrapper.qml` & `ContentList.qml`
- **Sliding Drawer**: Slides from screen edge with `offsetScale` (`Anim {}`, 500ms overshoot).
- **Mode Crossfade**: Switching between App List and Wallpaper Carousel runs a sequential fade-out $\rightarrow$ mode switch $\rightarrow$ fade-in (`Anim.DefaultEffects`).
- **Dynamic Dimension Morphing**: `implicitWidth` and `implicitHeight` smoothly resize as search results filter down.
- **Empty Search Feedback**: Empty state icon and message bounce in with `scale: 0.5 -> 1.0` (`Anim {}`) and `opacity: 0 -> 1` (`Anim.DefaultEffects`).

---

### Lock Screen & PAM Authentication

#### `InputField.qml` — Android 14/15 Shape-Morphing Password Dots
- **Character Keypress (`initAnim`)**:
  1. Spawns as a random playful Material shape from 15 shapes (`Arch`, `Fan`, `Arrow`, `ClamShell`, `Gem`, `Sunny`, `SoftBurst`, etc.).
  2. Expands: `scale 0 -> 1` (`Anim.FastSpatial`), `width height -> height * 1.3`.
  3. Pauses for `180ms`.
  4. Morphs shape into `MaterialShape.Circle`, scales down to `2/3`, and compresses width back to `height`.
- **Backspace Removal (`removeAnim`)**: Uses `ListView.delayRemove`, shrinking scale to `0.5` and opacity to `0`.
- **Password Reveal**: Shape dots fade out while plaintext characters fade in (`Anim.DefaultEffects`).

#### `PasswordInput.qml` — Enter Button Shape Morph
- Enter button shape morphs from `Circle` to `Arrow` (rotated $90^\circ$) when characters exist in the password buffer.
- Scale interaction: $0.8$ on hover, $0.6$ on press with `Anim.FastSpatial`.
- Pill container expands width smoothly from compact to typing mode.

#### `StateMessage.qml` — Authentication Error Flash
- On authentication error, plays a **2-cycle opacity flashing alarm** (`0.3 \leftrightarrow 1.0`, linear, 200ms per cycle) followed by a scale-down exit fade (`Anim.StandardLarge`, 600ms).

---

### Nexus (Settings & Control Center)

#### `AnimatedLogo.qml` — Celestial Constellation Intro & Breathing Loop
- **Intro Sequence**:
  - **Spin & Settle**: Logo spins $0^\circ \rightarrow 750^\circ$ (1000ms OutCubic) $\rightarrow 710^\circ$ (300ms) $\rightarrow 725^\circ$ (350ms) $\rightarrow 720^\circ$ (250ms) (two full rotations with overshoot and settle).
  - **Scale Spring**: Scales $0.0 \rightarrow 1.08 \rightarrow 0.96 \rightarrow 1.0$ (`OutBack` overshoot: 1.05).
  - **Motion Blur**: `MultiEffect` blur fades from 60px to 0px over 900ms.
  - **Staggered Star Pop-Ins**: Star 1 (1100ms), Star 2 (1250ms), and Star 3 (1400ms) pop in with scale bounce and fade.
- **Infinite Ambient Floating Loop**:
  - Star 1 floats $y -5\text{px}$ and scales $1.0 \leftrightarrow 1.08$ (period: 2500ms).
  - Star 2 floats $y +5\text{px}$ and scales $1.0 \leftrightarrow 1.12$ (period: 3000ms).
  - Star 3 floats $y -5\text{px}$ and scales $1.0 \leftrightarrow 1.08$ (period: 2800ms).
  - Out-of-phase periods create an organic twinkling celestial constellation effect.

#### `Pages.qml` & `StackPage.qml` — Directional Navigation Transitions
- **`Pages.qml`**: Navigating between top-level sections slides vertically based on forward/backward index comparison with `Anim.SlowEffects`.
- **`StackPage.qml`**: Sub-pages slide horizontally ($\pm 96\text{px}$) with sequential fade out $\rightarrow$ pause $\rightarrow$ slide in.

#### `BlobPopup.qml` — Gooey Budding Popups
- Popups bud organically off trigger buttons using SDF smooth-min blending, expanding with `expressiveFastSpatial` easing.

---

### Notifications & Sidebar

#### `Notification.qml` — Physics Swipe-to-Dismiss & Accordions
- **Swipe-to-Dismiss Gesture**: Draggable on X-axis with `Tokens.anim.emphasizedDecel` return curve. Releasing beyond `clearThreshold` dismisses; otherwise snaps back.
- **Vertical Drag Expand**: Dragging on Y-axis expands/collapses notification.
- **Expand/Collapse Accordion**:
  - Summary shifts anchors and line count with `AnchorAnim` and `height` animation.
  - Chevron rotates $180^\circ$ and shifts vertical offset.
  - Single-line preview crossfades into multiline body and action buttons.
- **App Icon Progress Ring**: `sweepAngle` animates with `emphasizedDecel`.
- **Copy Feedback**: Action icon morphs from `content_copy` to `inventory` with timer reset.

---

### Utilities, Screen Recorder & Toasts

#### `Record.qml` — REC Breathing & Mode Swap
- **REC Status Breathing**: Infinite pulsating opacity loop ($1 \rightarrow 0$ over 600ms `emphasizedAccel`, $0 \rightarrow 1$ over 1000ms `emphasizedDecel`).
- **Controls Swap**: Sequential fade-out of recording controls, animated height transition, and fade-in of recording list (`Anim.SlowEffects`).

#### `Toasts.qml` & `ToastItem.qml` — Floating Toast Stack
- New toasts pop in with simultaneous opacity and scale animation (`0.7 \rightarrow 1.0`).
- Remaining toasts calculate bottom margins dynamically and slide down smoothly (`Behavior on anchors.bottomMargin { Anim {} }`) when a toast is closed.

#### `RecordingDeleteModal.qml`
- Center confirmation modal scales in $0 \rightarrow 1$ (`Anim {}`) over a custom SDF scrim backdrop with smoothed corner cutouts.

---

### OSD (On-Screen Display)

#### `FilledSlider.qml`
- Slider value transitions smoothly via `Behavior on value { Anim { type: Anim.StandardLarge } }` (600ms).
- When dragged or adjusted, the handle icon shrinks to scale `0.3` (`standardAccel`, 100ms), transforms into percentage text, then expands back to `1.0` (`standardDecel`, 200ms).
- Elevation shadow switches between Level 1 and Level 2 on hover.

---

### Session (Power Menu)

#### `Content.qml`
- Focus navigation between power actions (Logout, Shutdown, Hibernate, Reboot) animates corner radius morphing from `20px` to `28px` (`extraLarge`) on focus, and compressing to `12px` (`medium`) on press.
- Background screen dimming scrim smoothly fades in (`Anim.SlowEffects`).

---

## 7. Attention-to-Detail Summary Matrix

| Visual / Kinetic Feature | Implementation File | Key Mechanism & Easing |
| :--- | :--- | :--- |
| **Material 3 Ripple Effect** | `components/StateLayer.qml` | `QtQuick.Shapes` `RadialGradient` dynamic corner distance calculation |
| **Squash & Stretch Switch** | `components/controls/StyledSwitch.qml` | `implicitWidth` expansion on press + vector path endpoint morphing |
| **Floating Label Notch Cutout** | `components/controls/StyledTextField.qml` | `ShapePath` outline notch gap opening (`outlineGapScale`) |
| **Physics Spring Morphing Spinner**| `components/controls/LoadingIndicator.qml` | Damped harmonic oscillator differential equation on `FrameAnimation` |
| **Squiggly Wave Audio Bar** | `components/controls/StyledSlider.qml` | C++ `WavyLine` with continuous `waveProgress` phase loop |
| **SDF Organic Blob Merging** | `plugin/.../Blobs/shaders/blob.frag` | Circular `smin` fillet blending with velocity `Matrix4x4` deformation |
| **Rubber-Band Workspace Pill** | `modules/bar/.../ActiveIndicator.qml` | Asymmetric 500ms leading / 750ms trailing edge stretching + `Colouriser` |
| **Shape-Morphing Workspace Icons**| `modules/bar/.../Workspace.qml` | 18 randomized Material Shapes morphing on focus |
| **Connected Occupied Bg** | `modules/bar/.../OccupiedBg.qml` | Corner radius morphing ($r \rightarrow 0$) between adjacent occupied items |
| **Shape-Morphing Password Dots** | `modules/lock/.../InputField.qml` | Keypress spawns 15 random shapes $\rightarrow$ pauses 180ms $\rightarrow$ morphs to Circle |
| **Enter Button Shape Morph** | `modules/lock/.../PasswordInput.qml` | `MaterialShape.Circle` $\rightarrow$ `MaterialShape.Arrow` (rotated $90^\circ$) |
| **Auth Error Alarm Flash** | `modules/lock/.../StateMessage.qml` | 2-cycle opacity flash loop (`0.3 \leftrightarrow 1.0`, linear) |
| **Constellation Logo & Breathing** | `modules/nexus/.../AnimatedLogo.qml` | $750^\circ$ rotation overshoot, 60px blur fade, 3 out-of-phase floating stars |
| **Conforming Audio Visualizer** | `modules/dashboard/.../CoverVisualiser.qml`| `cover.shape.distanceAtAngle()` parametric cookie shape boundary tracking |
| **Rotating Album Art** | `modules/dashboard/.../CoverArt.qml` | 12-sided cookie shape rotating over 23.5s linear loop |
| **Drifting Ambient Particles** | `modules/dashboard/.../BackgroundShapes.qml`| 14 procedural shapes with $(v_x, v_y, v_r)$ physics & toroidal wrapping |
| **Liquid Battery Tank** | `modules/dashboard/.../BatteryTank.qml` | Clipped liquid fill with two-tier inverse typography split |
| **Swipe-to-Dismiss Notifications** | `modules/notifications/Notification.qml`| X-axis drag threshold physics with `emphasizedDecel` return curve |
| **REC Pulsating Breath** | `modules/utilities/.../Record.qml` | Asymmetric 600ms `emphasizedAccel` / 1000ms `emphasizedDecel` loop |
| **OSD Value Morphing Handle** | `components/controls/FilledSlider.qml` | Scale compression to 0.3 $\rightarrow$ number swap $\rightarrow$ scale expansion to 1.0 |
