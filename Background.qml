// Oma Easel's per-screen background renderer. It replaces Omarchy's
// omarchy.background while this plugin is enabled (see "clonedFrom" in
// manifest.json) and keeps the same IPC target, so `omarchy-theme-bg-set`
// and theme switches work as before.
//
// Based on Omarchy's shell/plugins/background/Background.qml
// (https://github.com/omacom/omarchy, MIT License, see LICENSE-omarchy).
// The changes are the per-screen versions, the screen overrides, and the IPC
// functions rescanVersions, setScreen, clearScreens, and shown; the same
// changes are in oma-easel's contrib/per-screen-backgrounds.patch.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property bool suspended: false
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string currentThemeBackgrounds: stateHome + "/omarchy/current/theme/backgrounds"

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  // A theme switch names its next background before it has staged the rest of
  // the theme, so the incoming frame can decode while that work runs. A large
  // WebP takes ~130ms to decode at any sourceSize, which the reveal would
  // otherwise wait out after the transition arrives.
  property string preparedBackground: ""
  // The prepare and transition calls travel as separate IPC clients, so a
  // prepare can land after its transition. The path it names then must not be
  // decoded again.
  property string lastTransitionPath: ""
  // Native pixel size per wallpaper path, read from the file header before
  // the image loads. Decoding at screen size only saves memory for wallpapers
  // at least as large as the screen: with PreserveAspectCrop Qt scales the
  // decode up to cover sourceSize, so a smaller wallpaper would cost the
  // screen's worth of pixels instead of its own.
  property var nativeSizes: ({})

  // Per-screen versions. A background can have versions for other screen
  // shapes: a file of the same name in a folder named for the shape, beside
  // it in the theme's or the user's backgrounds ("9x16/7-add-boat.webp").
  // Each screen shows the version closest to its own shape, or the
  // background itself when that fits better. Base name -> [{ aspect, path }].
  property var screenVersions: ({})
  // Images shown on one screen only, by screen name, for previews.
  property var screenOverrides: ({})

  function baseName(path) {
    var name = String(path).split("/").pop()
    var dot = name.lastIndexOf(".")
    return dot > 0 ? name.slice(0, dot) : name
  }

  function pathForScreen(path, screenName, aspect) {
    if (screenOverrides[screenName]) return screenOverrides[screenName]
    if (!path || isVideo(path) || !(aspect > 0)) return path
    var versions = screenVersions[baseName(path)]
    if (!versions || versions.length === 0) return path
    // Until the background's own size is known, it can't be compared.
    var native = nativeSizes[path]
    if (!native || !(native.width > 0)) return path
    var best = path
    var bestScore = Math.abs(Math.log(native.width / native.height / aspect))
    for (var i = 0; i < versions.length; i++) {
      var score = Math.abs(Math.log(versions[i].aspect / aspect))
      if (score < bestScore - 0.01) {
        best = versions[i].path
        bestScore = score
      }
    }
    return best
  }

  function rescanVersions() {
    if (versionScan.running) versionScan.pending = true
    else versionScan.running = true
  }

  function loadVersions(text) {
    var found = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var path = lines[i].trim()
      if (!path) continue
      var parts = path.split("/")
      var shape = /^(\d+)x(\d+)$/.exec(parts[parts.length - 2])
      if (!shape || Number(shape[2]) === 0) continue
      var base = baseName(path)
      if (!found[base]) found[base] = []
      found[base].push({ aspect: Number(shape[1]) / Number(shape[2]), path: path })
      requestNativeSize(path)
    }
    screenVersions = found
  }

  // A version that fails to load is dropped, so its screen falls back to
  // the background itself.
  function dropVersion(path) {
    var kept = {}
    for (var base in screenVersions)
      kept[base] = screenVersions[base].filter(function(version) { return version.path !== path })
    screenVersions = kept
    var overrides = Object.assign({}, screenOverrides)
    for (var name in overrides)
      if (overrides[name] === path) delete overrides[name]
    screenOverrides = overrides
  }

  function setScreenOverride(screenName, path) {
    var overrides = Object.assign({}, screenOverrides)
    if (path) {
      overrides[screenName] = path
      requestNativeSize(path)
    } else {
      delete overrides[screenName]
    }
    screenOverrides = overrides
  }
  property var sizeQueue: []
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int reloadVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1
  readonly property bool ready: {
    if (isVideo(displayedBackground)) return true
    if (backgrounds.instances.length === 0) return false
    for (var panel of backgrounds.instances) {
      if (!panel.backgroundReady) return false
    }
    return true
  }

  function isVideo(path) {
    return Util.isVideoPath(path)
  }

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function refreshBackground() {
    rescanVersions()
    if (!readlinkProc.running) readlinkProc.running = true
  }

  onDisplayedBackgroundChanged: rescanVersions()

  // The desktop must never be left without a wallpaper. A path that stops
  // loading, say one that ran through a theme since replaced, is resolved
  // again from the background link, which a theme switch always repoints.
  // Only a different path is taken, so a file that is there but unreadable
  // cannot loop. Resolving runs out of process, so a background chosen in the
  // meantime wins over what it finds; if that one fails too, it is resolved
  // in turn once the running lookup is done.
  property string failedBackground: ""
  property int recoverVersion: -1

  function recoverBackground(failedPath) {
    if (!failedPath || failedPath !== displayedBackground) return
    failedBackground = failedPath
    if (recoverProc.running) return
    recoverVersion = backgroundVersion
    recoverProc.running = true
  }

  function finishRecovery(path) {
    path = String(path || "").trim()
    var failedPath = failedBackground
    failedBackground = ""
    if (recoverVersion !== backgroundVersion) {
      recoverBackground(failedPath)
      return
    }
    if (!path || path === failedPath) return
    setBackground(path, true)
  }

  function setBackground(path, instant) {
    if (instant) reloadVersion += 1
    transitionBackground("", path, path, instant, instant)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    if (path !== preparedBackground) preparedBackground = ""
    preparedBackgroundTimer.stop()
    lastTransitionPath = path
    // The incoming frame gates the reveal, so its size is read first.
    requestNativeSize(path)
    requestNativeSize(fromPath || displayedBackground)
    requestNativeSize(finalPath)
    currentBackground = finalPath
    backgroundVersion += 1
    failedBackground = ""
    revealStartedVersion = -1

    // OWE draws a video background and fades the last still into it. That
    // still stays on screen until OWE has the first frame and suspends this
    // layer, so the desktop does not show an empty background meanwhile. A
    // running reveal finishes on its incoming still, which OWE fades from.
    if (!instant && !root.suspended && displayedBackground && isVideo(path) && !isVideo(displayedBackground)) return

    revealAnimation.stop()
    finishingTransition = false

    // Video frames are not fed through the image-only reveal stack. Switching
    // instantly also avoids decoding two full videos during a transition.
    if (instant || !displayedBackground || isVideo(path) || isVideo(displayedBackground)) {
      oldBackground = ""
      incomingBackground = ""
      preparedBackground = ""
      displayedBackground = finalPath
      revealProgress = 1
      return
    }

    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    // Background polling can advance backgroundVersion while a theme switch is
    // pending; the latest theme payload should still apply.
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Commons.Color.loadColors(pendingColorsRaw)
    // Commons.Color.loadShell also refreshes Style so the type scale flips with the
    // background reveal instead of waiting for a separate reload path.
    Commons.Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  function startReveal(panel) {
    if (!incomingBackground) return
    panel.maskReady = true
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  function prepareBackground(path) {
    path = String(path || "").trim()
    // Only a still that is not already on screen is worth decoding ahead.
    if (!path || isVideo(path) || path === lastTransitionPath || path === displayedBackground) return
    requestNativeSize(path)
    preparedBackground = path
    preparedBackgroundTimer.restart()
  }

  function requestNativeSize(path) {
    if (!path || isVideo(path) || nativeSizes[path] !== undefined || sizeQueue.indexOf(path) !== -1) return
    sizeQueue = sizeQueue.concat([path])
    probeNextSize()
  }

  function probeNextSize() {
    if (sizeProbe.running || sizeQueue.length === 0) return
    sizeProbe.path = sizeQueue[0]
    sizeProbe.command = ["magick", "identify", "-ping", "-format", "%w %h", sizeProbe.path]
    sizeProbe.running = true
  }

  // Each theme switch names fresh snapshot paths, so keep only the sizes of
  // the wallpapers still in play.
  function pruneNativeSizes() {
    var kept = {}
    var paths = [displayedBackground, incomingBackground, oldBackground, preparedBackground]
    for (var base in screenVersions)
      for (var v = 0; v < screenVersions[base].length; v++) paths.push(screenVersions[base][v].path)
    for (var name in screenOverrides) paths.push(screenOverrides[name])
    for (var i = 0; i < paths.length; i++) {
      if (paths[i] && nativeSizes[paths[i]] !== undefined) kept[paths[i]] = nativeSizes[paths[i]]
    }
    nativeSizes = kept
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    var payload = JSON.stringify({ source: "themes" })

    // A cloned background may not summon the picker in-process, so it takes
    // the IPC route instead.
    if (!root.shell || !root.shell.summon("omarchy.image-picker", payload))
      Util.execArgv(["omarchy-shell", "shell", "summon", "omarchy.image-picker", payload])
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: sizeProbe
    property string path: ""
    stdout: StdioCollector { id: sizeProbeOut }
    onExited: function(exitCode) {
      var parts = String(sizeProbeOut.text || "").trim().split(/\s+/)
      var width = exitCode === 0 ? parseInt(parts[0], 10) : 0
      var height = exitCode === 0 ? parseInt(parts[1], 10) : 0
      var known = Object.assign({}, root.nativeSizes)
      // An unreadable header records 0x0, which decodes at screen size.
      known[path] = { width: width > 0 ? width : 0, height: height > 0 ? height : 0 }
      root.nativeSizes = known
      root.sizeQueue = root.sizeQueue.filter(function(queued) { return queued !== sizeProbe.path })
      root.probeNextSize()
    }
  }

  // Versions live one folder down, which Omarchy's background cycle never
  // reads, so they don't turn up in it as backgrounds of their own.
  Process {
    id: versionScan
    property bool pending: false
    command: [
      "bash", "-c",
      'theme=$(cat "$1" 2>/dev/null); for dir in "$2/$theme" "$3"; do [[ -n $theme && -d $dir ]] || continue; ' +
      'find -L "$dir" -mindepth 2 -maxdepth 2 -type f -regex ".*/[0-9]+x[0-9]+/[^/]*" ' +
      '\\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \\) -print; done',
      "scan", root.stateHome + "/omarchy/current/theme.name", root.home + "/.config/omarchy/backgrounds",
      root.currentThemeBackgrounds
    ]
    stdout: StdioCollector {
      onStreamFinished: root.loadVersions(text)
    }
    onExited: {
      if (!pending) return
      pending = false
      running = true
    }
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  // The link's target when it exists, or else the theme's first background,
  // so a link left dangling still finds a wallpaper.
  Process {
    id: recoverProc
    command: [
      "bash", "-c",
      'target=$(readlink -f "$1"); if [[ -e $target ]]; then echo "$target"; else ' +
      'find "$2" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \\) | sort | head -n 1; fi',
      "resolve", root.currentBackgroundLink, root.currentThemeBackgrounds
    ]
    stdout: StdioCollector {
      onStreamFinished: root.finishRecovery(text)
    }
  }

  ShellIpc {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function setSuspended(value: string): void {
      root.suspended = value === "true"
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }

    function prepare(path: string): void {
      root.prepareBackground(path)
    }

    function rescanVersions(): void {
      root.rescanVersions()
    }

    // Shows `path` on one screen only, until cleared with an empty path.
    function setScreen(screenName: string, path: string): void {
      root.setScreenOverride(screenName, path)
    }

    function clearScreens(): void {
      root.screenOverrides = ({})
    }

    // What each screen shows, as "name<TAB>path" lines. Oma Easel reads this
    // to tell that per-screen versions are supported.
    function shown(): string {
      var lines = []
      for (var i = 0; i < backgrounds.instances.length; i++) {
        var panel = backgrounds.instances[i]
        lines.push((panel.modelData ? panel.modelData.name : "") + "\t" + panel.shownPath)
      }
      return lines.join("\n")
    }
  }

  // A prepared frame that no transition claims, say from a theme switch that
  // failed after naming it, must not hold its decoded texture indefinitely.
  Timer {
    id: preparedBackgroundTimer
    interval: 5000
    repeat: false
    onTriggered: root.preparedBackground = ""
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: Style.duration(840)
    easing.type: Easing.OutCubic
    onFinished: {
      if (root.incomingBackground) {
        // After a video was chosen during the reveal, the incoming still
        // stays until OWE takes the background.
        root.displayedBackground = root.currentBackground && !root.isVideo(root.currentBackground)
          ? root.currentBackground : root.incomingBackground
        root.finishingTransition = true
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: refreshBackground()

  Variants {
    id: backgrounds
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: !remapGuard.remapping && !root.suspended
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. A still
      // wallpaper costs nothing to keep enabled. OWE manages video layers.
      updatesEnabled: true

      property bool maskReady: false
      property int readyFrames: 0
      readonly property bool backgroundReady: base.ready && readyFrames >= 2

      FrameAnimation {
        running: base.ready && panel.readyFrames < 2
        onTriggered: panel.readyFrames += 1
      }

      // Decode the wallpaper at the size this screen can show, not the size
      // it was shipped at. With PreserveAspectCrop Qt takes sourceSize as the
      // area to cover, so this is the smallest decode that still fills the
      // screen. Stock wallpapers go up to 10456x3455 (144 MB as RGBA); a
      // 1080p laptop paid all of that for the 8 MB it can display, and paid
      // it up to three times over during a transition. The images wait for
      // the window's size and the wallpaper's native size so nothing is ever
      // decoded at native size first, and a wallpaper smaller than the screen
      // is decoded at its own size rather than scaled up to cover the screen.
      readonly property bool sized: width > 0 && height > 0
      readonly property int decodeWidth: sized ? Math.ceil(width * screen.devicePixelRatio) : 0
      readonly property int decodeHeight: sized ? Math.ceil(height * screen.devicePixelRatio) : 0
      readonly property real screenAspect: sized ? width / height : 0
      readonly property string shownPath: base.path
      // This screen's version of a background, when it has one.
      function forScreen(path) {
        return root.pathForScreen(path, panel.modelData ? panel.modelData.name : "", panel.screenAspect)
      }

      function decodeSize(path) {
        if (!sized || !path) return Qt.size(0, 0)
        var native = root.nativeSizes[path]
        if (native === undefined) return Qt.size(0, 0)
        if (native.width > 0 && (native.width < decodeWidth || native.height < decodeHeight)) return Qt.size(native.width, native.height)
        return Qt.size(decodeWidth, decodeHeight)
      }

      function maybeStartReveal() {
        if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
          if (incomingFrame.status !== Image.Ready) return
          root.startReveal(panel)
        })
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // OWE owns video backgrounds. This layer draws stills, and stays empty
      // behind a video so OWE's own layer shows through.
      BackgroundMedia {
        id: base
        anchors.fill: parent
        path: panel.forScreen(root.displayedBackground)
        version: root.reloadVersion
        cached: true
        constrainDecode: true
        decodeSize: panel.decodeSize(path)
        onFailedChanged: {
          if (!failed) return
          if (path !== root.displayedBackground) root.dropVersion(path)
          else root.recoverBackground(path)
        }
        onReadyChanged: {
          panel.readyFrames = 0
          if (ready && root.finishingTransition) {
            root.incomingBackground = ""
            root.oldBackground = ""
            root.preparedBackground = ""
            root.finishingTransition = false
            root.pruneNativeSizes()
          }
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        readonly property string framePath: panel.forScreen(root.oldBackground)
        readonly property size decode: panel.decodeSize(framePath)
        source: decode.width > 0 ? root.imageUrl(framePath) : ""
        sourceSize.width: decode.width
        sourceSize.height: decode.height
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: root.oldBackground !== "" && root.revealProgress < 1
        onStatusChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: root.incomingBackground !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || panel.maskReady)
        layer.enabled: root.incomingBackground !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          // The same URL and size as a prepared frame keeps its decoded
          // image, so a transition to it can reveal at once.
          readonly property string framePath: panel.forScreen(root.incomingBackground || root.preparedBackground)
          readonly property size decode: panel.decodeSize(framePath)
          source: decode.width > 0 ? root.imageUrl(framePath) : ""
          sourceSize.width: decode.width
          sourceSize.height: decode.height
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.maybeStartReveal()
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
