// bounce-saver: OLED screensaver, a logo bouncing on pure black, every output.
// Own idle timer, so it runs with Noctalia caffeine on; Noctalia still does
// lock / screen-off. Run: qs -p /path/to/bounce-saver/shell.qml
// (the Noctalia plugin's service.luau does this for you).
// BOUNCE_LOGO=/abs/path.svg picks another logo (white art tints best),
// BOUNCE_TIMEOUT=<seconds> the idle time (default 120).
// BOUNCE_DEMO_CORNER=1 aims the first run into a corner, for testing.
import QtQuick
import QtQuick.Effects
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

    property bool demoCorner: Quickshell.env("BOUNCE_DEMO_CORNER") === "1"

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

            // DVD-player physics: constant speed, mirror bounces, new colour per wall hit.
            // Each start picks a random position and a random angle (25° to 65° off the walls).
            readonly property real speed: 210 // px per second, along the direction of travel
            property real hue: Math.random()
            property real vx: 150
            property real vy: 150
            property real lastHitX: -1e9 // ms timestamps of the last wall hits, for corner detection
            property real lastHitY: -1e9

            function restart() {
                const angle = (25 + Math.random() * 40) * Math.PI / 180
                win.vx = win.speed * Math.cos(angle) * (Math.random() < 0.5 ? -1 : 1)
                win.vy = win.speed * Math.sin(angle) * (Math.random() < 0.5 ? -1 : 1)
                win.hue = Math.random()
                // Screen size, not win.width: the layer surface is still 0×0 when visible flips, which pinned every start to the top-left.
                shown.x = Math.random() * Math.max(win.modelData.width - shown.width, 0)
                shown.y = Math.random() * Math.max(win.modelData.height - shown.height, 0)
                if (root.demoCorner) {
                    root.demoCorner = false
                    shown.x = 40; shown.y = 40; win.vx = -150; win.vy = -150
                }
            }

            onVisibleChanged: if (visible) restart()

            Image {
                id: logo
                source: Quickshell.env("BOUNCE_LOGO") ? "file://" + Quickshell.env("BOUNCE_LOGO") : "logo.svg"
                sourceSize.width: Math.round(win.modelData.width / 6) // height follows the art's aspect
                visible: false
            }

            MultiEffect {
                id: shown
                source: logo
                width: logo.width
                height: logo.height
                colorization: 1.0
                colorizationColor: Qt.hsva(win.hue, 1, 1, 1)
                // Wall hit: squash against the wall (pinned at the contact edge), spring back.
                transform: Scale { id: squash }
            }

            ParallelAnimation {
                id: squashX
                NumberAnimation { target: squash; property: "xScale"; from: 0.8; to: 1; duration: 280; easing.type: Easing.OutBack }
                NumberAnimation { target: squash; property: "yScale"; from: 1.1; to: 1; duration: 280; easing.type: Easing.OutBack }
            }
            ParallelAnimation {
                id: squashY
                NumberAnimation { target: squash; property: "yScale"; from: 0.8; to: 1; duration: 280; easing.type: Easing.OutBack }
                NumberAnimation { target: squash; property: "xScale"; from: 1.1; to: 1; duration: 280; easing.type: Easing.OutBack }
            }

            function squashOn(axisX, atStart) {
                if (axisX) {
                    squash.origin.x = atStart ? 0 : shown.width
                    squash.origin.y = shown.height / 2
                    squashX.restart()
                } else {
                    squash.origin.x = shown.width / 2
                    squash.origin.y = atStart ? 0 : shown.height
                    squashY.restart()
                }
            }

            Item { id: fx; anchors.fill: parent } // corner sparks and rings live here, above the logo

            SequentialAnimation {
                id: pop
                NumberAnimation { target: shown; property: "scale"; to: 1.35; duration: 120; easing.type: Easing.OutQuad }
                NumberAnimation { target: shown; property: "scale"; to: 1; duration: 420; easing.type: Easing.OutBack }
            }

            // New hue at least 1/6 turn away, so every hit is a visible change.
            function bounce() {
                win.hue = (win.hue + 1 / 6 + Math.random() * 2 / 3) % 1
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
                        win.squashOn(true, x < 0)
                        win.vx = -win.vx; x = Math.min(Math.max(x < 0 ? -x : 2 * maxX - x, 0), maxX); hit = true
                        if (now - win.lastHitY < 150) win.corner(cx, win.vy > 0 ? 0 : win.height)
                        win.lastHitX = now
                    }
                    if (y < 0 || y > maxY) {
                        const cy = y < 0 ? 0 : win.height
                        win.squashOn(false, y < 0)
                        win.vy = -win.vy; y = Math.min(Math.max(y < 0 ? -y : 2 * maxY - y, 0), maxY); hit = true
                        if (now - win.lastHitX < 150) win.corner(win.vx > 0 ? 0 : win.width, cy)
                        win.lastHitY = now
                    }
                    if (hit) win.bounce()
                    shown.x = x
                    shown.y = y
                }
            }
        }
    }
}
