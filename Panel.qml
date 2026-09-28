import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A clock button in the bar. Opens a dropdown that arms a scheduled shutdown:
// pick a preset (10 min .. 1 hour) and the session powers off when it fires.
// While armed the panel shows a live countdown and a Cancel button.
//
// The timer is a transient user unit (omarchy-shutdown-timer.timer) that runs
// omarchy-system-shutdown at expiry — the same command as the power menu — so
// cancel works even after a shell restart. See bar/scripts/shutdown-timer.
Panel {
  id: root
  moduleName: "robbie.shutdown-timer"
  ipcTarget: "robbie.shutdown-timer"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string scriptBase: "~/.config/omarchy/bar/scripts/shutdown-timer"

  property bool armed: false
  property int target: 0
  property int remaining: 0
  property var menuRows: []
  property int cursorIndex: 0
  property bool customMode: false
  property string customError: ""
  property real pulse: 0.0
  readonly property int yearSeconds: 31536000

  readonly property var presets: [
    { seconds: 600, label: "10 minutes" },
    { seconds: 900, label: "15 minutes" },
    { seconds: 1800, label: "30 minutes" },
    { seconds: 3600, label: "1 hour" }
  ]

  function expandPath(s) {
    if (String(s).charAt(0) === "~") return (Quickshell.env("HOME") || "/root") + String(s).substring(1)
    return String(s)
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(raw) {
    var data = {}
    try { data = JSON.parse(raw) } catch (e) { data = {} }
    if (data.armed !== undefined) root.armed = !!data.armed
    if (data.target !== undefined) root.target = Number(data.target || 0)
    root.tick()
  }

  function tick() {
    root.remaining = Math.max(0, root.target - Math.floor(Date.now() / 1000))
    if (root.armed && root.remaining <= 0) {
      root.armed = false
      // Let the system actually shut down; recheck in a moment.
      recheckTimer.restart()
    }
    root.rebuildMenu()
  }

  function arm(seconds) {
    armProc.command = ["bash", "-lc", root.expandPath(root.scriptBase) + " arm " + Number(seconds)]
    if (!armProc.running) armProc.running = true
  }

  function cancel() {
    if (!cancelProc.running) cancelProc.running = true
  }

  function parseDuration(text) {
    var t = String(text || "").trim().toLowerCase()
    if (t === "") return 0
    var secs = 0
    var re = /(\d+(?:\.\d+)?)\s*(s|m|h|d|w|y)/g
    var found = false
    var match
    while ((match = re.exec(t)) !== null) {
      found = true
      var v = parseFloat(match[1])
      var unit = match[2]
      if (unit === "m") secs += v * 60
      else if (unit === "h") secs += v * 3600
      else if (unit === "d") secs += v * 86400
      else if (unit === "w") secs += v * 604800
      else if (unit === "y") secs += v * 31536000
      else secs += v
    }
    if (!found && /^\d+$/.test(t)) secs = parseInt(t, 10)
    return Math.floor(secs)
  }

  function customSeconds() {
    return root.parseDuration(customInput.text)
  }

  function exitCustom() {
    root.customMode = false
    root.customError = ""
    customInput.text = ""
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
    })
  }

  function armCustom() {
    var secs = root.customSeconds()
    if (secs < 1 || secs > root.yearSeconds) {
      root.customError = "Enter a time from 1 second to 1 year"
      return
    }
    root.customError = ""
    root.customMode = false
    root.arm(secs)
  }

  function menuItems() {
    var items = []
    for (var i = 0; i < root.presets.length; i++) {
      items.push({
        id: "preset:" + i,
        icon: "\uf017",
        label: root.presets[i].label,
        hint: "Schedule shutdown in " + root.presets[i].label,
        seconds: root.presets[i].seconds
      })
    }
    items.push({
      id: "custom",
      icon: "\uf044",
      label: "Custom time\u2026",
      hint: "Enter any delay from 1 second to 1 year"
    })
    if (root.armed) {
      items.push({ id: "cancel", icon: "\uf05e", label: "Cancel Timer", hint: "Abort the scheduled shutdown", dangerous: true })
    }
    return items
  }

  function rebuildMenu() {
    root.menuRows = root.menuItems()
    if (root.cursorIndex >= root.menuRows.length) root.cursorIndex = Math.max(0, root.menuRows.length - 1)
  }

  function currentRow() {
    return (root.cursorIndex >= 0 && root.cursorIndex < root.menuRows.length) ? root.menuRows[root.cursorIndex] : null
  }

  function moveCursor(step) {
    if (root.menuRows.length === 0) return
    root.cursorIndex = Math.max(0, Math.min(root.menuRows.length - 1, root.cursorIndex + step))
  }

  function activateRow(row) {
    if (!row) return
    if (row.id === "cancel") {
      root.cancel()
      return
    }
    if (row.id === "custom") {
      root.customMode = true
      root.customError = ""
      Qt.callLater(function() {
        customInput.forceActiveFocus()
      })
      return
    }
    if (row.seconds) root.arm(row.seconds)
  }

  function clickIndex(index) {
    if (index < 0 || index >= root.menuRows.length) return
    root.cursorIndex = index
    root.activateRow(root.menuRows[index])
  }

  // Linear color mix for the armed-timer pulse (accent -> urgent).
  function mixColor(a, b, t) {
    t = Math.max(0, Math.min(1, Number(t) || 0))
    return Qt.rgba(
      a.r + (b.r - a.r) * t,
      a.g + (b.g - a.g) * t,
      a.b + (b.b - a.b) * t,
      a.a + (b.a - a.a) * t)
  }

  // Scrolls the keyboard-cursor row into view when the content overflows the
  // screen-capped panel (e.g. the Cancel Timer row while armed).
  function revealRow(rowIndex) {
    if (!menuRepeater || !timerScroll) return
    if (rowIndex < 0 || rowIndex >= menuRepeater.count) return
    var item = menuRepeater.itemAt(rowIndex)
    if (!item) return
    var pos = item.mapToItem(column, 0, 0)
    var pad = Style.space(8)
    var top = timerScroll.contentY
    var bottom = top + timerScroll.height
    if (pos.y < top) timerScroll.contentY = Math.max(0, pos.y - pad)
    else if (pos.y + item.height > bottom) timerScroll.contentY = pos.y + item.height - timerScroll.height + pad
  }

  function formatRemaining(s) {
    var total = Math.max(0, Number(s) || 0)
    var h = Math.floor(total / 3600)
    var m = Math.floor((total % 3600) / 60)
    var sec = total % 60
    function p(v) { return (v < 10 ? "0" + v : "" + v) }
    if (h > 0) return h + ":" + p(m) + ":" + p(sec)
    return p(m) + ":" + p(sec)
  }

  function fireTimeLabel() {
    if (root.target <= 0) return ""
    return new Date(root.target * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
  }

  function barTooltip() {
    return root.armed ? "Shutdown in " + root.formatRemaining(root.remaining) + " \u00b7 click to manage" : "Shutdown Timer \u00b7 click to manage"
  }

  Process {
    id: statusProc
    command: ["bash", "-lc", root.expandPath(root.scriptBase) + " status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: armProc
    command: ["bash", "-lc", root.expandPath(root.scriptBase) + " status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  Process {
    id: cancelProc
    command: ["bash", "-lc", root.expandPath(root.scriptBase) + " cancel"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  Timer {
    id: countdown
    interval: 1000
    repeat: true
    running: root.armed || root.opened
    onTriggered: root.tick()
  }

  Timer {
    id: recheckTimer
    interval: 2000
    onTriggered: root.refresh()
  }

  // Pulses root.pulse 0..1 while armed so the bar clock flashes accent-red.
  SequentialAnimation {
    running: root.armed
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "pulse"; to: 1.0; duration: 520; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "pulse"; to: 0.0; duration: 520; easing.type: Easing.InOutQuad }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): void {
      root.refresh()
    }
    function cancel(): void {
      root.cancel()
    }
    function arm(seconds: int): void {
      root.arm(Number(seconds))
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.refresh()
      root.cursorIndex = 0
    }
  }

  onCursorIndexChanged: root.revealRow(root.cursorIndex)

  Component.onCompleted: root.refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf017"
    tooltipText: root.barTooltip()
    active: root.armed
    activeColor: root.armed ? root.mixColor(root.accent, "#e5484d", root.pulse) : root.accent
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(280))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: customInput.activeFocus && root.customMode
      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx) }
      onActivateRequested: root.activateRow(root.currentRow())
      onDeleteRequested: root.activateRow(root.currentRow())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: timerScroll
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: column.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
          policy: ScrollBar.AsNeeded
          width: 6
        }

        Column {
          id: column
          width: timerScroll.width
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: Math.max(timerIcon.implicitHeight, timerLabels.implicitHeight)

            Text {
              id: timerIcon
              text: root.armed ? "\uf017" : "\uf017"
              color: root.armed ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: timerLabels
              anchors.left: timerIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Shutdown Timer"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: root.armed ? "SHUTDOWN IN " + root.formatRemaining(root.remaining) : "NO TIMER SET"
                color: root.armed ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Rectangle {
            visible: root.armed
            width: parent.width
            implicitHeight: countdownBox.implicitHeight + Style.space(10) * 2
            radius: Style.cornerRadius
            border.width: Math.max(1, Style.space(2))
            border.color: Util.alpha(root.urgent, 0.45)
            color: Util.alpha(root.urgent, 0.08)

            Column {
              id: countdownBox
              anchors.centerIn: parent
              spacing: Style.space(2)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.formatRemaining(root.remaining)
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "POWER OFF AT " + root.fireTimeLabel().toUpperCase()
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }
          }

          Column {
            visible: !root.customMode
            width: parent.width
            spacing: Style.space(6)

Repeater {
            id: menuRepeater
            model: root.menuRows

              Button {
                required property var modelData
                required property int index

                readonly property bool danger: modelData.id === "cancel"
                readonly property bool active: root.armed

                width: parent.width
                leftAlign: true
                iconText: modelData.icon
                text: modelData.label
                fontSize: Style.font.body
                iconSize: Style.font.title
                foreground: danger ? root.urgent : root.foreground
                accent: danger ? root.urgent : root.accent
                fontFamily: root.fontFamily
                hasCursor: root.cursorIndex === index
                bordered: danger
                horizontalPadding: Style.spacing.controlPaddingX + Style.space(4)
                verticalPadding: Style.space(11)
                onClicked: root.clickIndex(index)
                onHovered: function(h) {
                  if (h && index !== root.cursorIndex) root.moveCursor(index - root.cursorIndex)
                }
              }
            }
          }

          Column {
            visible: root.customMode
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: "Set a custom shutdown delay"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              width: parent.width
            }

            Text {
              text: "Type a duration: 45s \u00b7 5m \u00b7 2h \u00b7 3d \u00b7 1y"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.controlHeight
              radius: Style.cornerRadius
              border.width: Math.max(1, Style.space(2))
              border.color: customInput.activeFocus ? root.accent : root.dim
              color: Util.alpha(customInput.activeFocus ? root.accent : root.foreground, 0.06)

              TextInput {
                id: customInput
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                focus: true
                Keys.onEscapePressed: root.exitCustom()
                Keys.onReturnPressed: root.armCustom()
                Keys.onEnterPressed: root.armCustom()
              }

              Text {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                verticalAlignment: TextInput.AlignVCenter
                text: "e.g. 90m  2h  3d  120s  1y"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                visible: customInput.text.length === 0
              }
            }

            Text {
              text: "1 second \u00b7 1 year  \u00b7  s / m / h / d / w / y"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
            }

            Text {
              text: root.customError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
              visible: root.customError.length > 0
            }

            Button {
              width: parent.width
              iconText: "\uf017"
              text: "Set Timer"
              fontSize: Style.font.body
              iconSize: Style.font.title
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX + Style.space(4)
              verticalPadding: Style.space(11)
              onClicked: root.armCustom()
            }
          }

          Text {
            width: parent.width
            text: root.customMode
              ? "type a delay like 90m / 2h / 1y \u00b7 Enter set \u00b7 Esc back"
              : root.armed
                ? "Cancel stops the timer \u00b7 presets re-arm"
                : "Pick a delay or Custom time \u00b7 \u2191\u2193 select \u00b7 Enter run \u00b7 Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}