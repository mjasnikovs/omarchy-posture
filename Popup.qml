import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// The posture card. One small centered window per monitor. It shows your
// slate (faint) and your posture now, and says which checks failed.
//
// The service opens and closes it. It closes on its own once posture is back
// to the slate. Dismiss closes it and starts the delay over.
Item {
  id: root

  // Injected by the shell's panel loader. `service` is this plugin's service.
  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false

  readonly property string pluginId: (manifest && manifest.id) || "mjasnikovs.posture"
  readonly property var reasons: service ? service.tracker.reasons : []
  readonly property var slate: service ? service.slate : null

  readonly property string fontFamily: Style.font.family
  readonly property color foreground: Color.popups.text
  readonly property color background: Color.popups.background
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  function open(payloadJson) {
    root.opened = true
  }

  // Called by the shell when the service (or anything else) hides the card.
  function close() {
    root.opened = false
  }

  function dismiss() {
    if (root.service) root.service.dismiss()
    else root.opened = false
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.dismiss()
      event.accepted = true
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: window
        required property var modelData

        // Hyprland gives an OnDemand layer keyboard focus when it maps and
        // when the pointer passes over it, which would take the user's
        // typing. So the card takes no keys until it is clicked, and lets go
        // again once focus moves away. A click primes with Exclusive, since
        // a mapped layer turning OnDemand is not focused (as KeyboardPanel).
        property bool armed: false
        property bool primed: false
        onVisibleChanged: {
          window.armed = false
          window.primed = false
        }

        Timer {
          id: primeTimer
          interval: 75
          onTriggered: window.primed = window.armed
        }

        screen: modelData
        visible: root.opened
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: card.implicitWidth
        implicitHeight: card.implicitHeight
        WlrLayershell.namespace: "omarchy-posture"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: !window.armed ? WlrKeyboardFocus.None
          : window.primed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive

        BorderSurface {
          id: card
          anchors.centerIn: parent
          color: root.background
          radius: Style.cornerRadius
          borderSpec: root.borderSpec
          padding: Style.space(24)
          implicitWidth: column.implicitWidth + padding * 2
          implicitHeight: column.implicitHeight + padding * 2

          Item {
            id: keyCatcher
            anchors.fill: parent
            focus: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) { root.handleKey(event) }
            onActiveFocusChanged: if (!activeFocus && window.primed) {
              window.armed = false
              window.primed = false
            }
          }

          MouseArea {
            anchors.fill: parent
            onPressed: function(mouse) {
              if (!window.armed) {
                window.armed = true
                primeTimer.restart()
              }
              keyCatcher.forceActiveFocus()
              mouse.accepted = false
            }
          }

          Column {
            id: column
            anchors.centerIn: parent
            spacing: Style.space(14)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "Check your posture"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            PoseScope {
              anchors.horizontalCenter: parent.horizontalCenter
              width: Style.space(340)
              height: Style.space(230)
              kp: root.opened && root.service ? root.service.lastKp : null
              slateKp: root.slate ? root.slate.kp : null
              slateFeatures: root.slate ? root.slate.f : null
              bad: true
              badChecks: root.reasons.map(function(r) { return r.id })
              accentColor: Color.accent
              alertColor: Color.urgent
              mutedColor: Color.muted
              textColor: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
            }

            // Sized for every check failing at once, so the card keeps its
            // size as reasons come and go. One line each, so none can wrap.
            Item {
              anchors.horizontalCenter: parent.horizontalCenter
              width: Style.space(320)
              height: Model.CHECKS.length * reasonMetrics.height
                + (Model.CHECKS.length - 1) * reasonColumn.spacing

              FontMetrics {
                id: reasonMetrics
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Column {
                id: reasonColumn
                width: parent.width
                spacing: Style.space(14)

                Repeater {
                  model: root.reasons

                  Text {
                    required property var modelData
                    width: reasonColumn.width
                    height: reasonMetrics.height
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Model.reasonText(modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "Muted is your slate. Sit back into it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Dismiss"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.dismiss()
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "click, then esc dismisses"
              color: Qt.darker(root.foreground, 2.0)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
