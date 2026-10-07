import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// The bar face of Posture. One glyph, coloured by status. Click opens the
// panel. Middle-click pauses or resumes.
//
// The bar mounts one of these per monitor. They hold no posture state: the
// service does. Each pushes its settings into the service (the service
// ignores repeats) and reads status back.
BarWidget {
  id: root
  moduleName: "mjasnikovs.posture"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property string status: service ? service.status : "missing"

  readonly property string glyphText: "󰀄"
  readonly property color baseForeground: bar ? bar.barForeground : Color.foreground
  readonly property color glyphColor: {
    if (status === "alert" || status === "bad") return bar ? bar.urgent : Color.urgent
    if (status === "no-slate" || status === "recording") return Color.accent
    return baseForeground
  }
  readonly property bool glyphDimmed: status === "paused" || status === "no-camera" || status === "missing"
    || status === "error" || status === "starting" || status === "unknown"

  function pushSettings() {
    if (root.service) root.service.applySettings(root.settings)
  }

  onServiceChanged: pushSettings()
  onSettingsChanged: {
    pushSettings()
    injectPanel()
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function togglePaused() { if (root.service) root.service.togglePaused() }

  function screenName() {
    var w = root.QsWindow ? root.QsWindow.window : null
    return w && w.screen ? String(w.screen.name || "") : ""
  }

  // `omarchy-shell mjasnikovs.posture panel` toggles the panel on the focused monitor.
  Connections {
    target: root.service
    function onPanelRequested() {
      if (root.screenName() === root.service.monitorName) root.togglePanel()
    }
  }

  // ---- Panel plumbing. Shape contract for shell summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyphText
    foreground: root.glyphColor
    dimmed: root.glyphDimmed
    tooltipText: "Posture: " + Model.statusText(root.status, root.service ? root.service.helperDetail : "")

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.togglePaused()
      else root.togglePanel()
    }
  }
}
