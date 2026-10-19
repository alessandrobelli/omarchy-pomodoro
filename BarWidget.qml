import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "alessandrobelli.pomodoro"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Always loaded: the timer and the music player live in the panel.
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

  readonly property string barText: panelLoader.item ? panelLoader.item.barLabel : "󰔛"
  readonly property bool showsTime: barText.length > 2

  // Reserve the width of the widest countdown so the bar doesn't shift every second.
  TextMetrics {
    id: countdownSlot
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: "󰔛 000:00"
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    dimmed: panelLoader.item ? panelLoader.item.paused : false
    fixedWidth: root.vertical || !root.showsTime ? -1 : Math.ceil(countdownSlot.advanceWidth + scaledHorizontalMargin * 2)
    tooltipText: ""

    onPressed: function(b) {
      var panel = panelLoader.item
      if (!panel) return
      // Right click starts or pauses without opening the panel.
      if (b === Qt.RightButton) panel.startOrPause()
      else root.togglePanel()
    }
  }
}
