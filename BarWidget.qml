import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar companion for the Oma Easel app. It opens (or focuses) the app, shows
// how many images are generating, and offers the install command when the
// app is missing. It only reads the status file the app writes at
// $XDG_RUNTIME_DIR/oma-easel/status.json; it never touches the app's data.
BarWidget {
  id: root
  moduleName: "io.github.lutzlstein.oma-easel"

  readonly property string statusPath: (Quickshell.env("OMA_EASEL_STATUS") || (Quickshell.env("XDG_RUNTIME_DIR") + "/oma-easel/status.json"))
  property bool installed: true
  property bool running: false
  property int generating: 0
  property int total: 0
  property string themeName: ""

  readonly property string glyph: "󰏘"
  readonly property string label: root.generating > 0
    ? root.glyph + " " + (root.total - root.generating) + "/" + root.total
    : root.glyph

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function parse(text) {
    var status = null
    try { status = JSON.parse(text) } catch (e) { status = null }
    if (!status || !status.pid) { clear(); return }
    // A file left by a crash names a process that is gone.
    aliveCheck.pending = status
    aliveCheck.command = ["test", "-d", "/proc/" + status.pid]
    aliveCheck.running = true
  }

  function clear() {
    root.running = false
    root.generating = 0
    root.total = 0
    root.themeName = ""
  }

  function activate() {
    if (!root.installed) {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "omarchy pkg aur add oma-easel"])
      return
    }
    if (root.running)
      Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"class:^oma-easel$\" })"])
    else
      Quickshell.execDetached(["oma-easel"])
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.clear()
  }

  Process {
    id: aliveCheck
    property var pending: null
    onExited: function(code) {
      if (code === 0 && pending) {
        root.running = true
        root.generating = pending.generating || 0
        root.total = pending.total || 0
        var batches = pending.batches || []
        root.themeName = batches.length > 0 ? (batches[0].themeName || "") : ""
      } else {
        root.clear()
      }
    }
  }

  // Whether the app is installed decides between open and install.
  Process {
    id: installCheck
    command: ["sh", "-c", "command -v oma-easel"]
    running: true
    onExited: function(code) { root.installed = code === 0 }
  }
  Timer {
    interval: 30000
    repeat: true
    running: !root.installed
    onTriggered: installCheck.running = true
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? root.glyph : root.label
    active: root.generating > 0
    dimmed: !root.installed
    tooltipText: !root.installed
      ? "Oma Easel isn't installed. Click to install it (omarchy pkg aur add oma-easel)."
      : root.generating > 0
        ? "Oma Easel · generating " + (root.total - root.generating) + " of " + root.total + (root.themeName ? " for " + root.themeName : "")
        : root.running ? "Oma Easel is open. Click to switch to it." : "Open Oma Easel"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.activate()
    }
  }
}
