// bounce-saver: OLED screensaver, a logo bouncing on pure black, every output.
// Own idle timer, so it runs with Noctalia caffeine on; Noctalia still does
// lock / screen-off. Run: qs -p /path/to/bounce-saver/shell.qml
// (the Noctalia plugin's service.luau does this for you).
// BOUNCE_LOGO=/abs/path: one image, or a folder to pick a random image from on every start
// (default: the bundled logos/; white art tints best). BOUNCE_TIMEOUT=<seconds> the idle
// time (default 120). BOUNCE_DEMO_CORNER=1 aims the first run into a corner, for testing.
import QtQuick
import QtQuick.Effects
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // Idle: show, unless that screen has a fullscreen window (video). Inhibitors are
    // ignored: a static music page inhibits too, and X11 players cannot inhibit at all.
    IdleMonitor {
        id: idle
        timeout: Number(Quickshell.env("BOUNCE_TIMEOUT")) || 120 // seconds without input
        respectInhibitors: false
    }

    // Outputs showing a fullscreen window, from niri IPC. Quickshell's ToplevelManager
    // lists no windows under niri, and niri has no fullscreen flag, so a window whose
    // size equals its output's logical size on an active workspace counts as fullscreen.
    // No niri (or IPC error): empty list, so the screensaver shows. OLED-safe default.
    property var fullscreenOutputs: []
    property bool probed: false
    readonly property bool idleNow: idle.isIdle
    onIdleNowChanged: idleNow ? fsProbe.running = true : probed = false

    function parseFullscreen(text) {
        const [outputs, workspaces, windows] = text.trim().split("\n").map(l => JSON.parse(l))
        const found = []
        for (const ws of workspaces) {
            const out = outputs[ws.output]
            if (!ws.is_active || !out || !out.logical) continue
            if (windows.some(w => w.workspace_id === ws.id
                    && Math.abs(w.layout.window_size[0] - out.logical.width) <= 1
                    && Math.abs(w.layout.window_size[1] - out.logical.height) <= 1))
                found.push(ws.output)
        }
        return found
    }

    Process {
        id: fsProbe
        command: ["sh", "-c", "niri msg -j outputs && niri msg -j workspaces && niri msg -j windows"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.fullscreenOutputs = root.parseFullscreen(text) }
                catch (e) { root.fullscreenOutputs = [] }
                root.probed = true            }
        }
        onExited: code => { if (code !== 0) { root.fullscreenOutputs = []; root.probed = true } }
    }
    Timer {
        interval: 2000
        repeat: true
        running: root.idleNow
        onTriggered: fsProbe.running = true
    }

    readonly property string logoEnv: Quickshell.env("BOUNCE_LOGO") || ""
    property bool demoCorner: Quickshell.env("BOUNCE_DEMO_CORNER") === "1"

    // Lists the logo folder; stays empty when BOUNCE_LOGO names a single file.
    FolderListModel {
        id: logoFolder
        folder: root.logoEnv === "" ? Qt.resolvedUrl("logos") : "file://" + root.logoEnv
        nameFilters: ["*.svg", "*.png", "*.webp"]
        showDirs: false
    }

    function randomLogo() {
        if (logoFolder.count === 0)
            return root.logoEnv !== "" ? "file://" + root.logoEnv : Qt.resolvedUrl("logos/moon.svg")
        return logoFolder.get(Math.floor(Math.random() * logoFolder.count), "fileUrl")
    }

    // One corner-hit spark: flies from the corner into the screen and fades out.
    Component {
        id: sparkComponent
        Rectangle {
            id: spark
            property real dx
            property real dy
            property int life
            width: 6 + Math.random() * 8
            height: width
            radius: width / 2
            ParallelAnimation {
                running: true
                NumberAnimation { target: spark; property: "x"; to: spark.x + spark.dx; duration: spark.life; easing.type: Easing.OutCubic }
                NumberAnimation { target: spark; property: "y"; to: spark.y + spark.dy; duration: spark.life; easing.type: Easing.OutCubic }
                NumberAnimation { target: spark; property: "opacity"; to: 0; duration: spark.life; easing.type: Easing.InQuad }
                onFinished: spark.destroy()
            }
        }
    }

    // Expanding ring from the corner.
    Component {
        id: ringComponent
        Rectangle {
            id: ring
            property real cx
            property real cy
            color: "transparent"
            border.width: 4
            width: 0
            height: width
            radius: width / 2
            x: cx - width / 2
            y: cy - width / 2
            ParallelAnimation {
                running: true
                NumberAnimation { target: ring; property: "width"; to: 900; duration: 1100; easing.type: Easing.OutCubic }
                NumberAnimation { target: ring; property: "opacity"; to: 0; duration: 1100; easing.type: Easing.InQuad }
                onFinished: ring.destroy()
            }
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            visible: root.idleNow && root.probed
                && !root.fullscreenOutputs.includes(win.modelData.name)
            color: "black"
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "bounce-saver"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            // Re-rolled on every start: logo, angle, speed, size, colour mode, trail.
            // Motion is always the old DVD-player physics: constant speed, mirror bounces.
            property real hue: Math.random()
            property real vx: 150 // px per second
            property real vy: 150
            property real sizeDiv: 6 // logo width = screen width / sizeDiv
            property bool rainbow: false // hue drifts all the time instead of changing per hit
            property bool trail: false
            property var history: [] // recent positions, newest first, for the trail
            property real lastHitX: -1e9 // ms timestamps of the last wall hits, for corner detection
            property real lastHitY: -1e9

            function restart() {
                logo.source = root.randomLogo()
                const angle = (Math.random() < 0.3 ? 45 : 25 + Math.random() * 40) * Math.PI / 180
                const speed = 110 + Math.random() * 100
                win.vx = speed * Math.cos(angle) * (Math.random() < 0.5 ? -1 : 1)
                win.vy = speed * Math.sin(angle) * (Math.random() < 0.5 ? -1 : 1)
                win.sizeDiv = 5 + Math.random() * 2.5
                win.rainbow = Math.random() < 0.3
                win.trail = Math.random() < 0.3
                win.hue = Math.random()
                win.history = []
                shown.x = Math.random() * Math.max(win.width - win.width / win.sizeDiv, 0)
                shown.y = Math.random() * Math.max(win.height - win.height / 3, 0)
                if (root.demoCorner) {
                    root.demoCorner = false
                    shown.x = 40; shown.y = 40; win.vx = -150; win.vy = -150
                }
            }

            onVisibleChanged: if (visible) restart()

            Image {
                id: logo
                sourceSize.width: Math.round(win.modelData.width / win.sizeDiv) // height follows the art
                visible: false
            }

            // Trail: fading copies at older positions.
            Repeater {
                model: win.trail ? 5 : 0
                MultiEffect {
                    required property int index
                    readonly property var pos: win.history[(index + 1) * 12]
                    source: logo
                    width: logo.width
                    height: logo.height
                    visible: pos !== undefined
                    x: pos ? pos.x : 0
                    y: pos ? pos.y : 0
                    opacity: 0.45 * (1 - index / 5)
                    colorization: 1.0
                    colorizationColor: Qt.hsva(win.hue, 1, 1, 1)
                }
            }

            MultiEffect {
                id: shown
                source: logo
                width: logo.width
                height: logo.height
                colorization: 1.0
                colorizationColor: Qt.hsva(win.hue, 1, 1, 1)
            }

            Item { id: fx; anchors.fill: parent } // corner sparks and rings live here, above the logo

            SequentialAnimation {
                id: pop
                NumberAnimation { target: shown; property: "scale"; to: 1.35; duration: 120; easing.type: Easing.OutQuad }
                NumberAnimation { target: shown; property: "scale"; to: 1; duration: 420; easing.type: Easing.OutBack }
            }

            // New hue at least 1/6 turn away, so every hit is a visible change.
            function bounce() {
                if (!win.rainbow) win.hue = (win.hue + 1 / 6 + Math.random() * 2 / 3) % 1
            }

            // Both walls within 150 ms counts as a corner: sparks, a ring and a pop.
            function corner(cx, cy) {
                const sx = cx === 0 ? 1 : -1, sy = cy === 0 ? 1 : -1
                for (let i = 0; i < 40; i++) {
                    const a = Math.random() * Math.PI / 2, dist = 250 + Math.random() * 450
                    sparkComponent.createObject(fx, {
                        x: cx, y: cy, color: Qt.hsva(Math.random(), 1, 1, 1),
                        dx: sx * Math.cos(a) * dist, dy: sy * Math.sin(a) * dist,
                        life: 900 + Math.random() * 700
                    })
                }
                ringComponent.createObject(fx, { cx: cx, cy: cy, "border.color": Qt.hsva(win.hue, 1, 1, 1) })
                pop.restart()
            }

            FrameAnimation {
                running: win.visible
                onTriggered: {
                    const dt = Math.min(frameTime, 0.1), now = Date.now()
                    const maxX = Math.max(win.width - shown.width, 0), maxY = Math.max(win.height - shown.height, 0)
                    let x = shown.x + win.vx * dt, y = shown.y + win.vy * dt, hit = false
                    // Mirror reflection: overshoot past a wall is folded back, no energy lost.
                    if (x < 0 || x > maxX) {
                        const cx = x < 0 ? 0 : win.width
                        win.vx = -win.vx; x = Math.min(Math.max(x < 0 ? -x : 2 * maxX - x, 0), maxX); hit = true
                        if (now - win.lastHitY < 150) win.corner(cx, win.vy > 0 ? 0 : win.height)
                        win.lastHitX = now
                    }
                    if (y < 0 || y > maxY) {
                        const cy = y < 0 ? 0 : win.height
                        win.vy = -win.vy; y = Math.min(Math.max(y < 0 ? -y : 2 * maxY - y, 0), maxY); hit = true
                        if (now - win.lastHitX < 150) win.corner(win.vx > 0 ? 0 : win.width, cy)
                        win.lastHitY = now
                    }
                    if (hit) win.bounce()
                    if (win.rainbow) win.hue = (win.hue + dt * 0.06) % 1
                    shown.x = x
                    shown.y = y
                    if (win.trail) win.history = [{ x: x, y: y }].concat(win.history.slice(0, 64))
                }
            }
        }
    }
}
