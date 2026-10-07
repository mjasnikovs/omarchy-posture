import QtQuick
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// Settings for Posture: watch on/off, a live stick figure, slate recording,
// the four checks, strictness, alert delay, and side-monitor mode.
//
// This panel owns no state. It reads the service through `hostWidget` (the
// BarWidget on this screen) and writes settings through it.
Panel {
  id: root
  moduleName: "mjasnikovs.posture"
  ipcTarget: "mjasnikovs.posture.panel"
  manageIpc: false

  property var anchorItem: null

  // The bar identifies this panel by the widget mounted in its slot, not by
  // this nested item. Bare (no host) only during the bar's own instantiation.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var service: hostWidget ? hostWidget.service : null
  readonly property var cfg: service ? service.cfg : Model.settings({})
  readonly property bool watching: service ? !service.paused : false
  readonly property string status: service ? service.status : "missing"
  readonly property bool canRecord: service ? (service.helperState === "running" && !service.paused && !service.recording) : false

  readonly property color contentForeground: Color.popups.text
  readonly property string contentFontFamily: Style.font.family
  readonly property color dim: Qt.darker(contentForeground, 1.5)

  // Seconds left while a slate is being recorded.
  property real now: Date.now()
  readonly property int recordLeft: service && service.recording ? Math.max(0, Math.ceil((service.recordUntil - now) / 1000)) : 0

  Timer {
    interval: 250
    repeat: true
    // triggeredOnStart: a panel opened mid-recording must not show a stale clock.
    triggeredOnStart: true
    running: root.opened && root.service !== null && root.service.recording
    onTriggered: root.now = Date.now()
  }

  // The figure's frame. Held while closed, so the fade-out does not flash
  // "NO SIGNAL", and not repainted for frames nobody sees.
  property var scopeKp: null

  Connections {
    target: root.service
    function onLastKpChanged() { if (root.opened) root.scopeKp = root.service.lastKp }
  }

  onOpenedChanged: if (root.opened) root.scopeKp = root.service ? root.service.lastKp : null

  function open() {
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    root.controller.hide()
    root.setCenterHoverRevealSuppressed(false)
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function persist(values) { if (root.hostWidget) root.hostWidget.persistSettings(values) }
  function flipWatching() { if (root.service) root.service.togglePaused() }
  function record() {
    if (!root.canRecord) return
    root.now = Date.now()
    root.service.startRecording()
  }

  readonly property var checkRows: [
    { id: "leanIn", key: "checkLeanIn" },
    { id: "headDrop", key: "checkHeadDrop" },
    { id: "headTilt", key: "checkHeadTilt" },
    { id: "sideLean", key: "checkSideLean" }
  ]

  component Label: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.bodySmall
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onActivateRequested: root.flipWatching()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---- Title and watch switch
        Item {
          width: parent.width
          height: Math.max(title.implicitHeight, watchSwitch.implicitHeight)

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Posture"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          ToggleSwitch {
            id: watchSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.watching
            foreground: root.contentForeground
            onToggled: root.flipWatching()
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.recordLeft > 0
            ? "Recording your slate. Sit well and hold still. " + root.recordLeft + " s"
            : Model.statusText(root.status, root.service ? root.service.helperDetail : "")
          color: root.dim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        // ---- Live figure and slate
        PoseScope {
          width: parent.width
          height: Style.space(220)
          visible: root.watching
          kp: root.scopeKp
          slateKp: root.service && root.service.slate ? root.service.slate.kp : null
          slateFeatures: root.service && root.service.slate ? root.service.slate.f : null
          bad: root.status === "bad" || root.status === "alert"
          good: root.status === "ok"
          // A standing alert keeps its reasons through good and turned frames.
          badChecks: !root.service ? []
            : root.status === "alert" ? root.service.tracker.reasons.map(function(r) { return r.id })
            : root.status === "bad" ? root.service.verdict.bad : []
          accentColor: Color.accent
          alertColor: Color.urgent
          mutedColor: Color.muted
          textColor: root.contentForeground
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
        }

        Item {
          width: parent.width
          height: Math.max(slateHint.implicitHeight, recordButton.implicitHeight)

          Label {
            id: slateHint
            anchors.left: parent.left
            anchors.right: recordButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            wrapMode: Text.WordWrap
            text: root.cfg.sideMode === "perMonitor" && root.service && root.service.monitorName
              ? "Slate for " + root.service.monitorName : "Sit well, look at your main screen."
          }

          Button {
            id: recordButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // In per-monitor mode the fallback default slate is not this monitor's.
            text: root.service && root.service.store.slates[root.service.slateKey] ? "Re-record slate" : "Record slate"
            bordered: true
            enabled: root.canRecord
            // The shell's Button draws no disabled state of its own.
            opacity: enabled ? 1 : 0.4
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.record()
          }
        }

        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: root.service ? root.service.recordError : ""
          color: Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
        }

        // ---- Checks
        Repeater {
          model: root.checkRows

          Item {
            required property var modelData
            width: column.width
            height: Math.max(checkLabel.implicitHeight, checkSwitch.implicitHeight)

            Text {
              id: checkLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: Model.checkLabel(modelData.id)
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            ToggleSwitch {
              id: checkSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.cfg.checks[modelData.id] === true
              foreground: root.contentForeground
              onToggled: {
                var v = {}
                v[modelData.key] = !(root.cfg.checks[modelData.id] === true)
                root.persist(v)
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
        }

        // ---- Strictness
        Item {
          width: parent.width
          height: strictLabel.implicitHeight

          Label {
            id: strictLabel
            anchors.left: parent.left
            text: "Strictness"
          }

          Label {
            anchors.right: parent.right
            text: ["lax", "relaxed", "normal", "firm", "strict"][Math.round(strictSlider.liveValue) - 1] || ""
            color: root.contentForeground
          }
        }

        PanelSlider {
          id: strictSlider
          width: parent.width
          bar: root.bar
          minimum: Model.MIN_STRICTNESS
          maximum: Model.MAX_STRICTNESS
          step: 1
          integer: true
          value: root.cfg.strictness
          onReleased: function(v) { root.persist({ strictness: Math.round(v) }) }
        }

        // ---- Delay
        Item {
          width: parent.width
          height: delayLabel.implicitHeight

          Label {
            id: delayLabel
            anchors.left: parent.left
            text: "Alert after"
          }

          Label {
            anchors.right: parent.right
            // A drag lands on a step of 10. A stored value shows as it is.
            readonly property int secs: delaySlider.dragging ? Math.round(delaySlider.liveValue / 10) * 10 : Math.round(delaySlider.liveValue)
            text: secs < 60 ? secs + " s" : Math.floor(secs / 60) + " min" + (secs % 60 ? " " + (secs % 60) + " s" : "")
            color: root.contentForeground
          }
        }

        PanelSlider {
          id: delaySlider
          width: parent.width
          bar: root.bar
          minimum: Model.MIN_DELAY_SECONDS
          maximum: Model.MAX_DELAY_SECONDS
          step: 10
          integer: true
          value: root.cfg.delaySeconds
          onReleased: function(v) { root.persist({ delaySeconds: Math.round(v / 10) * 10 }) }
        }

        // ---- Side monitors
        Item {
          width: parent.width
          height: Math.max(sideLabel.implicitHeight, sideSwitch.implicitHeight)

          Text {
            id: sideLabel
            anchors.left: parent.left
            anchors.right: sideSwitch.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Slate per monitor"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          ToggleSwitch {
            id: sideSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.cfg.sideMode === "perMonitor"
            foreground: root.contentForeground
            onToggled: root.persist({ sideMode: root.cfg.sideMode === "perMonitor" ? "ignore" : "perMonitor" })
          }
        }

        Label {
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.cfg.sideMode === "perMonitor"
            ? "Record a slate while facing each monitor. The focused monitor picks the slate."
            : "Looking at a side monitor is not judged."
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "space/enter watch on/off   esc close   middle-click icon pauses"
          color: Qt.darker(root.contentForeground, 2.0)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
