import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "Model.mjs" as Model

// The one Posture brain. A keepLoaded service, so the helper process and the
// camera survive plugin hot-reloads and the bar widget on each monitor does
// not start its own helper.
//
// It runs the helper, judges every pose against the slate, and raises or
// takes down the card. Bar widgets push their settings in and read state out.
Item {
  id: root

  // Injected by the shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "mjasnikovs.posture"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/posture"
  readonly property string slatePath: stateDir + "/slates.json"
  readonly property string statePath: stateDir + "/state.json"

  // ---- Settings, pushed by the bar widgets.
  property var cfg: Model.settings({})
  // Empty means "omarchy-posture-helper" from PATH.
  property string helperPath: ""
  property string device: ""
  property string settingsKey: ""

  // ---- Helper.
  // starting | running | paused | no-camera | error | missing
  property string helperState: "starting"
  property string helperDetail: ""
  property real helperStartedAt: 0
  property int quickFailures: 0
  property bool restartRequested: false
  property bool stateDirReady: false
  property bool stateLoaded: false
  // The first start waits for the bar's settings (device, helperPath), or
  // for settingsFallback when no bar widget pushes any.
  property bool settingsApplied: false

  // ---- Pause. The user's choice persists; a screen lock pauses on its own.
  property bool userPaused: false
  property bool lockPaused: false
  readonly property bool paused: userPaused || lockPaused
  property bool sentPaused: false

  // ---- Latest frame and verdict.
  property var lastKp: null
  property real lastPoseAt: 0
  property var verdict: ({ kind: "unknown", why: "no-person" })
  property var tracker: Model.tracker()

  // ---- Slates.
  property var store: Model.emptyStore()
  readonly property string monitorName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
  // The camera the helper reports. Slates remember the camera they were made
  // on: a slate from another camera (dock unplugged, auto-pick fell back)
  // would judge every frame through a different lens.
  property string activeDevice: ""
  readonly property var storedSlate: Model.slateFor(store, cfg.sideMode, monitorName)
  readonly property bool slateOtherCamera: storedSlate !== null && !!storedSlate.cam && activeDevice !== ""
    && storedSlate.cam !== activeDevice
  readonly property var slate: slateOtherCamera ? null : storedSlate
  // In auto mode the helper tries the slate's camera first and switches back
  // to it when it returns (dock replugged).
  readonly property string preferredCamera: storedSlate && storedSlate.cam ? storedSlate.cam : ""
  onPreferredCameraChanged: root.send("prefer " + root.preferredCamera)
  readonly property string slateKey: Model.slateKey(cfg.sideMode, monitorName)

  // ---- Slate recording.
  property bool recording: false
  property var recordFrames: []
  property real recordUntil: 0
  property string recordError: ""
  // Fixed when recording starts: focus may move during the 5 s.
  property string recordKey: ""

  // Asks the bar widget on the focused monitor to open its panel.
  signal panelRequested()

  // One word for the bar glyph and the panel status line.
  readonly property string status: {
    if (helperState === "missing" || helperState === "error") return helperState
    if (paused) return "paused"
    if (helperState === "no-camera") return "no-camera"
    if (helperState !== "running") return "starting"
    if (recording) return "recording"
    if (!slate) return slateOtherCamera ? "other-camera" : "no-slate"
    if (tracker.alert) return "alert"
    return verdict.kind
  }

  // ---------------------------------------------------------------- settings

  // A new bar widget briefly holds placeholder settings ({}) before the shell
  // injects the real ones. Applying that placeholder would reset device and
  // helperPath and restart the helper. So those settle for a moment and only
  // the last ones pushed are applied.
  property var pendingSettings: null

  function applySettings(raw) {
    // Checks, strictness and delay apply at once, so panel controls track
    // their own clicks. Only device and helperPath wait.
    root.cfg = Model.settings(raw || ({}))
    root.pendingSettings = raw || ({})
    settingsTimer.restart()
  }

  function applyPendingSettings() {
    var src = root.pendingSettings || ({})
    var key = JSON.stringify(src)
    if (key === root.settingsKey) return
    root.settingsKey = key
    var path = String(src.helperPath || "").trim()
    // sh gets the path quoted, so a leading ~ would never expand.
    if (path === "~" || path.indexOf("~/") === 0) path = Quickshell.env("HOME") + path.slice(1)
    var dev = String(src.device || "").trim()
    // A new camera only needs the helper to reopen it. A new binary needs a restart.
    if (dev !== root.device) {
      root.device = dev
      root.send("device " + dev)
    }
    if (path !== root.helperPath) {
      root.helperPath = path
      root.restartHelper()
    }
    if (!root.settingsApplied) {
      root.settingsApplied = true
      root.startHelper()
    }
  }

  // ------------------------------------------------------------------ helper

  // Always through sh: exec keeps one process, so stdin, stdout and kill reach
  // the helper itself, and sh exits 127 when the helper is missing. Quickshell
  // reports nothing at all when it cannot exec a path itself.
  function helperCommand() {
    var args = ["--fps", "5"]
    if (root.device) args.push("--device", root.device)
    if (root.preferredCamera) args.push("--prefer", root.preferredCamera)
    if (root.paused) args.push("--paused")
    return ["sh", "-c", "exec \"$0\" \"$@\"", root.helperPath || "omarchy-posture-helper"].concat(args)
  }

  function startHelper() {
    if (helper.running || !root.stateDirReady || !root.stateLoaded || !root.settingsApplied) return
    helper.command = root.helperCommand()
    root.sentPaused = root.paused
    root.helperState = "starting"
    root.helperDetail = ""
    root.helperStartedAt = Date.now()
    helper.running = true
  }

  function restartHelper() {
    restartTimer.stop()
    root.quickFailures = 0
    if (helper.running) {
      root.restartRequested = true
      helper.running = false
    } else {
      root.startHelper()
    }
  }

  function send(line) {
    if (helper.running) helper.write(line + "\n")
  }

  function syncPause() {
    if (root.paused === root.sentPaused) return
    root.sentPaused = root.paused
    root.send(root.paused ? "pause" : "resume")
    if (root.paused) {
      root.recording = false
      root.clearPose()
    }
  }

  onPausedChanged: syncPause()

  function onHelperLine(line) {
    var msg
    try {
      msg = JSON.parse(line)
    } catch (e) {
      return
    }
    if (msg.ev === "status") {
      root.helperState = String(msg.state || "")
      root.helperDetail = String(msg.detail || "")
      if (root.helperState === "running") root.activeDevice = root.helperDetail
      if (root.helperState !== "running") root.clearPose()
      return
    }
    if (msg.ev === "pose") root.onPose(msg.kp)
  }

  function onHelperExited(code) {
    root.clearPose()
    if (root.restartRequested) {
      root.restartRequested = false
      // Inside onExited the Process still reads as running. Start next tick.
      Qt.callLater(root.startHelper)
      return
    }
    // A helper that dies within 30 s is broken (missing, or crashing on the
    // first frames). Back off. Reporting "running" first does not count.
    var quick = Date.now() - root.helperStartedAt < 30000
    root.quickFailures = quick ? root.quickFailures + 1 : 0
    if (code === 127 || (quick && root.quickFailures >= 3 && root.helperState === "starting")) {
      root.helperState = "missing"
      root.helperDetail = root.helperPath || "omarchy-posture-helper"
    } else if (root.helperState !== "error") {
      root.helperState = "starting"
    }
    restartTimer.interval = Math.min(60000, 2000 * Math.pow(2, Math.min(5, root.quickFailures)))
    restartTimer.restart()
  }

  // ------------------------------------------------------------------ judging

  // No frames are coming: drop the last pose so nothing draws it as live.
  function clearPose() {
    root.lastKp = null
    root.verdict = { kind: "unknown", why: "no-person" }
    root.tracker = Model.tracker()
    root.syncCard()
  }

  function onPose(kp) {
    // A frame already in flight when pause was sent must not be judged.
    if (root.paused || !Model.isKeypoints(kp)) return
    root.lastKp = kp
    root.lastPoseAt = Date.now()
    if (root.recording) {
      var frames = root.recordFrames.slice()
      frames.push(kp)
      root.recordFrames = frames
      return
    }
    var mode = Model.judgeMode(root.store, root.cfg.sideMode, root.monitorName)
    var cfg = mode === root.cfg.sideMode ? root.cfg : Object.assign({}, root.cfg, { sideMode: mode })
    var v = Model.judge(kp, root.slate, cfg, root.tracker.alert)
    root.verdict = v
    root.tracker = Model.step(root.tracker, v, root.lastPoseAt, root.cfg.delaySeconds * 1000)
    root.syncCard()
  }

  function cardOpen() {
    return !!(root.shell && typeof root.shell.isPluginOpen === "function" && root.shell.isPluginOpen(root.pluginId) === true)
  }

  // Show the card while the alert stands, fullscreen windows included.
  function syncCard() {
    if (!root.shell) return
    var want = root.tracker.alert && !root.paused
    var open = root.cardOpen()
    if (want && !open && typeof root.shell.summon === "function") root.shell.summon(root.pluginId, "{}")
    else if (!want && open && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function dismiss() {
    root.tracker = Model.dismiss(root.tracker, Date.now())
    root.syncCard()
  }

  // ------------------------------------------------------------------- slate

  function startRecording() {
    // A second request mid-recording would drop the frames and re-key the slate.
    if (root.recording || root.helperState !== "running" || root.paused) return
    root.recordError = ""
    root.recordFrames = []
    root.recordKey = root.slateKey
    root.recordUntil = Date.now() + Model.SLATE_SECONDS * 1000
    root.recording = true
    root.tracker = Model.tracker()
    root.syncCard()
    recordTimer.restart()
  }

  function finishRecording() {
    if (!root.recording) return
    root.recording = false
    var at = Date.now()
    var made = Model.buildSlate(root.recordFrames, at)
    root.recordFrames = []
    if (!made) {
      root.recordError = "Not enough clear frames. Sit in view and try again."
      return
    }
    made.cam = root.activeDevice
    root.store = Model.withSlate(root.store, root.recordKey, made)
    slateFile.setText(JSON.stringify(root.store))
  }

  // ------------------------------------------------------------------ state

  // Resuming is the user's call even while a lock pause is still standing
  // (the probe clears it up to 3 s after unlock): the screen is clearly in use.
  function setPaused(value) {
    var next = value === true
    if (!next) root.lockPaused = false
    if (next === root.userPaused) return
    root.userPaused = next
    stateFile.setText(JSON.stringify({ paused: next }))
  }

  // Flip what the user sees, which includes a lock pause.
  function togglePaused() { root.setPaused(!root.paused) }

  function statusJson() {
    return JSON.stringify({
      status: root.status,
      helper: root.helperState,
      detail: root.helperDetail,
      paused: root.paused,
      // The slate actually used: per-monitor mode may fall back to "*".
      slate: !root.slate ? "" : (Model.judgeMode(root.store, root.cfg.sideMode, root.monitorName) === "perMonitor" ? root.monitorName : "*"),
      alert: root.tracker.alert,
      verdict: root.verdict.kind === "unknown" ? root.verdict.why : root.verdict.kind,
      kp: root.lastKp,
      reasons: root.tracker.reasons.map(function(r) { return Model.reasonText(r) })
    })
  }

  // ------------------------------------------------------------------ plumbing

  Component.onCompleted: {
    ensureDirProc.running = true
  }

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: {
      root.stateDirReady = true
      stateFile.reload()
      slateFile.reload()
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onLoaded: {
      try {
        root.userPaused = JSON.parse(stateFile.text()).paused === true
      } catch (e) {
        root.userPaused = false
      }
      root.stateLoaded = true
      root.startHelper()
    }
    onLoadFailed: {
      root.stateLoaded = true
      root.startHelper()
    }
  }

  FileView {
    id: slateFile
    path: root.slatePath
    watchChanges: true
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onFileChanged: slateFile.reload()
    onLoaded: root.store = Model.parseStore(slateFile.text())
    // A deleted slate file means no slates.
    onLoadFailed: root.store = Model.emptyStore()
  }

  Process {
    id: helper
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(data) { root.onHelperLine(data) }
    }
    onExited: function(code) { root.onHelperExited(code) }
  }

  Timer {
    interval: 3000
    running: true
    repeat: false
    onTriggered: {
      if (root.settingsApplied) return
      root.settingsApplied = true
      root.startHelper()
    }
  }

  Timer {
    id: settingsTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingSettings()
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: root.startHelper()
  }

  Timer {
    id: recordTimer
    interval: Model.SLATE_SECONDS * 1000
    repeat: false
    onTriggered: root.finishRecording()
  }

  // A lock follows idle (or a lock key, after which the user is idle too),
  // so the lock is only probed while idle. Locked releases the camera. Only a
  // probe that says "unlocked" brings it back: input on the lock screen alone
  // does not.
  IdleMonitor {
    id: idleMonitor
    enabled: true
    timeout: 30
    respectInhibitors: false
    onIsIdleChanged: root.probeLock()
  }

  function probeLock() {
    if (!lockProbe.running) lockProbe.running = true
  }

  Timer {
    interval: root.lockPaused ? 3000 : 10000
    repeat: true
    running: root.lockPaused || idleMonitor.isIdle
    onTriggered: root.probeLock()
  }

  Process {
    id: lockProbe
    command: ["omarchy-shell", "lock", "isLocked"]
    stdout: StdioCollector { id: lockOut; waitForEnd: true }
    onExited: function(code) {
      if (code === 0) root.lockPaused = String(lockOut.text).trim() === "true"
    }
  }

  IpcHandler {
    target: "mjasnikovs.posture"

    function status(): string { return root.statusJson() }
    function pause(): void { root.setPaused(true) }
    function resume(): void { root.setPaused(false) }
    function toggle(): void { root.togglePaused() }
    function record(): void { root.startRecording() }
    function dismiss(): void { root.dismiss() }
    function panel(): void { root.panelRequested() }
  }
}
