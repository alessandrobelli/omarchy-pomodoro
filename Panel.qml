import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "alessandrobelli.pomodoro"
  ipcTarget: "alessandrobelli.pomodoro"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
  }

  function openFromHotkey() {
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

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

  // ---- Settings, stored inline on this widget's shell.json entry.

  readonly property var defaultChannels: [
    { name: "Lofi hip hop", url: "https://www.youtube.com/watch?v=rFZHOHl-L8A" },
    { name: "Lofi house", url: "https://www.youtube.com/watch?v=3PFJ9SETS4M" },
    { name: "Final Fantasy lofi", url: "https://www.youtube.com/watch?v=gEGQciAcSnI" }
  ]

  // Built-in sounds that need no internet: mpv generates the noise itself,
  // the rain loops are CC0 field recordings shipped with the plugin.
  readonly property var ambientSounds: [
    { name: "Rain", icon: "󰖗", url: Qt.resolvedUrl("sounds/rain.oga").toString().replace(/^file:\/\//, "") },
    { name: "Rain on roof", icon: "󰖗", url: Qt.resolvedUrl("sounds/rain-roof.oga").toString().replace(/^file:\/\//, "") },
    { name: "White noise", icon: "󰔊", url: "av://lavfi:anoisesrc=color=white:amplitude=0.06" },
    { name: "Brown noise", icon: "󰔊", url: "av://lavfi:anoisesrc=color=brown:amplitude=0.25" }
  ]

  // Writes land in shell.json asynchronously; keep them here so a second
  // change made before the first round-trips doesn't read stale values.
  property var pendingSettings: ({})

  function pref(name, fallback) {
    if (pendingSettings[name] !== undefined) return pendingSettings[name]
    return setting(name, fallback)
  }

  function saveSettings(patch) {
    var next = {}
    var current = root.settings || {}
    for (var k in current) next[k] = current[k]
    for (var p in pendingSettings) next[p] = pendingSettings[p]
    for (var q in patch) next[q] = patch[q]
    var pending = {}
    for (var r in pendingSettings) pending[r] = pendingSettings[r]
    for (var s in patch) pending[s] = patch[s]
    pendingSettings = pending
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  // Drop pending values once shell.json has caught up with them.
  onSettingsChanged: {
    var pending = {}
    var changed = false
    for (var k in pendingSettings) {
      var saved = root.settings ? root.settings[k] : undefined
      if (JSON.stringify(saved) === JSON.stringify(pendingSettings[k])) changed = true
      else pending[k] = pendingSettings[k]
    }
    if (changed) pendingSettings = pending
  }

  function clampInt(value, low, high, fallback) {
    var n = parseInt(value, 10)
    if (isNaN(n)) return fallback
    return Math.max(low, Math.min(high, n))
  }

  readonly property var channels: {
    var list = pref("channels", null)
    return Array.isArray(list) ? list : defaultChannels
  }
  // "" means no music.
  readonly property string channelUrl: pref("channel", channels.length > 0 ? channels[0].url : "")
  readonly property int focusMinutes: clampInt(pref("focusMinutes", 25), 1, 600, 25)
  readonly property int breakMinutes: clampInt(pref("breakMinutes", 5), 1, 120, 5)
  readonly property bool stopMusicOnBreak: pref("stopMusicOnBreak", true) === true
  readonly property bool autoContinue: pref("autoContinue", true) === true
  readonly property bool chime: pref("chime", true) === true
  readonly property bool ticktickLogging: pref("ticktick", true) === true
  // { id, projectId, title, project } or null.
  readonly property var task: pref("task", null)
  readonly property int volume: clampInt(pref("volume", 60), 0, 100, 60)
  readonly property var presets: [25, 30, 50]
  readonly property bool customDuration: presets.indexOf(focusMinutes) === -1

  function channelName(url) {
    var all = channels.concat(ambientSounds)
    for (var i = 0; i < all.length; i++)
      if (all[i].url === url) return all[i].name
    return ""
  }

  // ---- Timer state.

  property string phase: "idle"     // idle | focus | break
  property bool running: false
  property double endsAt: 0
  property double remainingMs: 0
  property int sessionsDone: 0
  property double nowMs: Date.now()
  // For the TickTick focus record: when this focus began and how long it sat paused.
  property double focusStartedAt: 0
  property double pauseMs: 0
  property double pausedAt: 0

  readonly property bool paused: phase !== "idle" && !running
  readonly property double phaseTotalMs: (phase === "break" ? breakMinutes : focusMinutes) * 60000
  readonly property double leftMs: phase === "idle" ? focusMinutes * 60000 : (running ? Math.max(0, endsAt - nowMs) : remainingMs)
  readonly property real progress: phase === "idle" || phaseTotalMs <= 0 ? 0 : Math.min(1, 1 - leftMs / phaseTotalMs)
  readonly property string timeText: formatTime(leftMs)

  readonly property string phaseIcon: phase === "break" ? "󰅶" : (paused ? "󰏤" : "󰔛")
  readonly property string barLabel: phase === "idle" ? "󰔛" : phaseIcon + " " + timeText

  // Buttons don't elide, so long labels are cut to fit the column.
  function fit(text, max) {
    var t = String(text || "")
    return t.length > max ? t.slice(0, max - 1).trim() + "…" : t
  }

  function formatTime(ms) {
    var total = Math.max(0, Math.ceil(ms / 1000))
    var m = Math.floor(total / 60)
    var s = total % 60
    return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
  }

  function beginPhase(next) {
    var minutes = next === "break" ? breakMinutes : focusMinutes
    if (next === "focus") {
      focusStartedAt = Date.now()
      pauseMs = 0
    }
    phase = next
    remainingMs = minutes * 60000
    endsAt = Date.now() + remainingMs
    nowMs = Date.now()
    running = true
    saveState()
  }

  function startOrPause() {
    if (phase === "idle") {
      beginPhase("focus")
    } else if (running) {
      remainingMs = Math.max(0, endsAt - Date.now())
      pausedAt = Date.now()
      running = false
      saveState()
    } else {
      if (pausedAt > 0) pauseMs += Date.now() - pausedAt
      pausedAt = 0
      // A focus that started paused (break ended without auto-start) begins now.
      if (phase === "focus" && focusStartedAt === 0) {
        focusStartedAt = Date.now()
        pauseMs = 0
      }
      endsAt = Date.now() + remainingMs
      nowMs = Date.now()
      running = true
      saveState()
    }
  }

  function reset() {
    phase = "idle"
    running = false
    remainingMs = 0
    sessionsDone = 0
    focusStartedAt = 0
    pauseMs = 0
    pausedAt = 0
    saveState()
  }

  // ---- TickTick: log each finished focus as a pomodoro record.

  readonly property string ticktickScript: Qt.resolvedUrl("ticktick.sh").toString().replace(/^file:\/\//, "")
  property bool hasToken: false

  // TickTick wants "yyyy-MM-dd'T'HH:mm:ssZ", e.g. 2026-10-19T17:00:00+0200.
  function ticktickTime(ms) {
    var d = new Date(ms)
    function pad(n) { return (n < 10 ? "0" : "") + n }
    var offset = -d.getTimezoneOffset()
    var sign = offset >= 0 ? "+" : "-"
    offset = Math.abs(offset)
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
      + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds())
      + sign + pad(Math.floor(offset / 60)) + pad(offset % 60)
  }

  function logFocus(endMs) {
    if (!ticktickLogging || !hasToken) return
    var paused = pauseMs + (pausedAt > 0 ? endMs - pausedAt : 0)
    // Sessions from before logging existed have no start; work it back from the clock.
    var start = focusStartedAt > 0 ? focusStartedAt : endMs - (phaseTotalMs - leftMs) - paused
    var activeMs = endMs - start - paused
    // A skip in the first minute isn't worth a record.
    if (activeMs < 60000) return
    var record = {
      type: 0,
      startTime: ticktickTime(start),
      endTime: ticktickTime(endMs),
      duration: Math.round(activeMs / 1000),
      pauseDuration: Math.round(paused / 1000)
    }
    if (task && task.id) record.taskId = task.id
    focusLogs.push(JSON.stringify(record))
    sendNextFocusLog()
  }

  property var focusLogs: []

  function sendNextFocusLog() {
    if (logProc.running || focusLogs.length === 0) return
    var next = focusLogs.shift()
    logProc.command = [ticktickScript, "focus", next]
    logProc.running = true
  }

  Process {
    id: logProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = String(text || "").trim()
        if (result === "queued")
          root.notify("󰔟", "TickTick unreachable", "The session is saved and will be sent with the next one.")
        else if (result !== "ok")
          root.notify("󰀦", "TickTick logging failed", "Check the token in ~/.config/omarchy/ticktick-token.")
      }
    }
    onExited: Qt.callLater(root.sendNextFocusLog)
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/ticktick-token"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.hasToken = text().trim().length > 0
    onLoadFailed: root.hasToken = false
  }

  // ---- TickTick task picker.

  property bool pickerOpen: false
  property var taskResults: []
  property string taskStatus: ""   // "", "loading", "empty", "error"
  property string taskQuery: ""

  function openPicker() {
    pickerOpen = true
    taskQuery = ""
    loadTasks()
    Qt.callLater(function() { taskSearchField.forceActiveFocus() })
  }

  function loadTasks() {
    if (taskProc.running) taskProc.running = false
    taskStatus = "loading"
    var q = taskQuery.trim()
    taskProc.command = q === "" ? [ticktickScript, "upcoming"] : [ticktickScript, "search", q]
    taskProc.running = true
  }

  function chooseTask(t) {
    saveSettings({ task: t ? { id: t.id, projectId: t.projectId, title: t.title, project: t.project || "" } : null })
    pickerOpen = false
    keyCatcher.forceActiveFocus()
  }

  // Done, next task: log the focus so far to the finished task, complete it in
  // TickTick, and let the countdown carry on for whatever gets picked next.
  function completeTaskAndContinue() {
    var t = task
    if (!t || !t.id) return
    if (phase === "focus" && focusStartedAt > 0) {
      var now = Date.now()
      logFocus(now)
      focusStartedAt = now
      pauseMs = 0
      if (pausedAt > 0) pausedAt = now
      saveState()
    }
    completeProc.title = t.title
    completeProc.command = [ticktickScript, "complete", t.projectId, t.id]
    completeProc.running = true
    saveSettings({ task: null })
    openPicker()
  }

  Process {
    id: completeProc
    property string title: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() === "ok")
          root.notify("󰄬", "Task done", completeProc.title)
        else
          root.notify("󰀦", "Couldn't complete task", "Mark \"" + completeProc.title + "\" done in TickTick.")
      }
    }
  }

  Process {
    id: taskProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        try {
          var list = JSON.parse(raw)
          root.taskResults = Array.isArray(list) ? list : []
          root.taskStatus = root.taskResults.length > 0 ? "" : "empty"
        } catch (e) {
          root.taskResults = []
          root.taskStatus = "error"
        }
      }
    }
  }

  Timer {
    id: searchDebounce
    interval: 400
    onTriggered: root.loadTasks()
  }

  function skip() {
    if (phase !== "idle") finishPhase()
  }

  function finishPhase() {
    if (phase === "focus") {
      logFocus(Date.now())
      sessionsDone += 1
      notify("󰅶", "Focus done", "Take a " + breakMinutes + " minute break.")
      beginPhase("break")
    } else if (phase === "break") {
      if (autoContinue) {
        notify("󰔛", "Break over", "Back to focus for " + focusMinutes + " minutes.")
        beginPhase("focus")
      } else {
        notify("󰔛", "Break over", "Start the next focus session when you're ready.")
        phase = "focus"
        running = false
        remainingMs = focusMinutes * 60000
        focusStartedAt = 0
        pauseMs = 0
        pausedAt = 0
        saveState()
      }
    }
  }

  // The plugin bar API has run() but no shellQuote().
  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  readonly property string chimePath: Qt.resolvedUrl("chime.oga").toString().replace(/^file:\/\//, "")

  function notify(glyph, title, body) {
    if (!root.bar) return
    root.bar.run("omarchy-notification-send -g " + shellQuote(glyph) + " "
      + shellQuote(title) + " " + shellQuote(body))
    if (root.chime) root.bar.run("pw-play --volume 0.7 " + shellQuote(root.chimePath))
  }

  Timer {
    interval: 250
    repeat: true
    running: root.running
    onTriggered: {
      root.nowMs = Date.now()
      if (root.endsAt - root.nowMs <= 0) root.finishPhase()
    }
  }

  // ---- Persist the timer across shell restarts.

  property bool stateRestored: false

  function saveState() {
    stateFile.setText(JSON.stringify({
      phase: phase,
      running: running,
      endsAt: endsAt,
      remainingMs: remainingMs,
      sessionsDone: sessionsDone,
      focusStartedAt: focusStartedAt,
      pauseMs: pauseMs,
      pausedAt: pausedAt
    }) + "\n")
  }

  function restoreState(raw) {
    if (stateRestored) return
    stateRestored = true
    var saved
    try { saved = JSON.parse(raw) } catch (e) { return }
    if (!saved || (saved.phase !== "focus" && saved.phase !== "break")) return
    sessionsDone = saved.sessionsDone || 0
    focusStartedAt = saved.focusStartedAt || 0
    pauseMs = saved.pauseMs || 0
    pausedAt = saved.pausedAt || 0
    if (saved.running) {
      // A phase that ended while the shell was down is dropped quietly.
      if (saved.endsAt <= Date.now()) return
      phase = saved.phase
      endsAt = saved.endsAt
      remainingMs = saved.endsAt - Date.now()
      nowMs = Date.now()
      running = true
    } else {
      phase = saved.phase
      remainingMs = saved.remainingMs || 0
      running = false
    }
  }

  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/pomodoro.json"
    printErrors: false
    onLoaded: root.restoreState(text())
    onLoadFailed: root.stateRestored = true
  }

  // ---- Music: mpv plays the YouTube live stream through yt-dlp.

  readonly property string mpvSocket: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/alessandrobelli-pomodoro-mpv.sock"
  readonly property bool musicShouldPlay: running && channelUrl !== ""
    && (phase === "focus" || (phase === "break" && !stopMusicOnBreak))
  property bool musicStopping: false
  property string playingUrl: ""
  property int musicFailures: 0

  onMusicShouldPlayChanged: syncMusic()
  onChannelUrlChanged: if (mpvProc.running) restartMusic()

  function syncMusic() {
    if (musicShouldPlay && !mpvProc.running) startMusic()
    else if (!musicShouldPlay && mpvProc.running) stopMusic()
  }

  function startMusic() {
    musicStopping = false
    playingUrl = channelUrl
    mpvProc.command = [
      "mpv", "--no-video", "--no-terminal", "--sid=no", "--loop-file=inf",
      "--ytdl-format=bestaudio/best",
      "--volume=" + root.volume,
      "--input-ipc-server=" + root.mpvSocket,
      "--force-media-title=Pomodoro · " + (channelName(playingUrl) || "music"),
      playingUrl
    ]
    mpvProc.running = true
  }

  function stopMusic() {
    musicStopping = true
    mpvProc.running = false
  }

  function restartMusic() {
    stopMusic()
    restartTimer.restart()
  }

  // For when the audio went away underneath mpv, e.g. Bluetooth headphones
  // switching to call mode and pausing it; a fresh mpv also rejoins a live stream.
  function replayMusic() {
    musicFailures = 0
    restartMusic()
  }

  function applyVolume(value) {
    if (!mpvProc.running) return
    volumeProc.command = [
      "python3", "-I", "-c",
      "import socket,sys\ns=socket.socket(socket.AF_UNIX)\ns.connect(sys.argv[1])\ns.sendall(sys.argv[2].encode()+b'\\n')",
      root.mpvSocket,
      JSON.stringify({ command: ["set_property", "volume", value] })
    ]
    volumeProc.running = true
  }

  Process {
    id: mpvProc
    onExited: function(exitCode) {
      if (root.musicStopping || !root.musicShouldPlay) return
      // The stream dropped or never started; retry a couple of times.
      root.musicFailures += 1
      if (root.musicFailures <= 2) {
        retryTimer.restart()
      } else {
        root.musicFailures = 0
        root.notify("󰝛", "Music stopped", "Couldn't play " + (root.channelName(root.playingUrl) || "the stream") + ". The timer keeps running.")
      }
    }
  }

  Process { id: volumeProc }

  Timer {
    id: retryTimer
    interval: 5000
    onTriggered: if (root.musicShouldPlay && !mpvProc.running) root.startMusic()
  }

  Timer {
    id: restartTimer
    interval: 300
    onTriggered: root.syncMusic()
  }

  // A stream that has been playing for a while counts as healthy again.
  Timer {
    interval: 60000
    repeat: true
    running: mpvProc.running
    onTriggered: root.musicFailures = 0
  }

  Component.onDestruction: if (mpvProc.running) stopMusic()

  // ---- Channel list editing.

  function addChannel(name, url) {
    var trimmedUrl = String(url || "").trim()
    if (trimmedUrl === "") return false
    var trimmedName = String(name || "").trim() || "Channel " + (channels.length + 1)
    var next = channels.slice()
    next.push({ name: trimmedName, url: trimmedUrl })
    var patch = { channels: next }
    if (channels.length === 0) patch.channel = trimmedUrl
    saveSettings(patch)
    return true
  }

  function removeChannel(index) {
    var removed = channels[index]
    var next = channels.slice()
    next.splice(index, 1)
    var patch = { channels: next }
    if (removed && removed.url === channelUrl) patch.channel = next.length > 0 ? next[0].url : ""
    saveSettings(patch)
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function startOrPause(): void { root.startOrPause() }
    function reset(): void { root.reset() }
    function skip(): void { root.skip() }
    function pickTask(): void { root.openFromHotkey(); root.openPicker() }
    function doneNext(): void { root.openFromHotkey(); root.completeTaskAndContinue() }
    function restartMusic(): void { root.replayMusic() }
  }

  // ---- Panel UI.

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property bool typing: customField.activeFocus || nameField.activeFocus || urlField.activeFocus || taskSearchField.activeFocus

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(680))
    contentHeight: panel.fittedContentHeight(Math.max(timerColumn.implicitHeight, settingsColumn.implicitHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.typing
      onActivateRequested: root.startOrPause()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // ---- Left: the timer.
      Column {
        id: timerColumn
        anchors.left: parent.left
        anchors.top: parent.top
        width: Math.round(parent.width * 0.48)
        spacing: Style.space(14)

        PanelSectionHeader {
          text: root.phase === "idle" ? "READY"
            : (root.phase === "break" ? "BREAK" : "FOCUS · SESSION " + (root.sessionsDone + 1))
              + (root.paused ? " · PAUSED" : "")
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          text: root.timeText
          color: root.phase === "break" ? Commons.Color.accent : root.fg
          opacity: root.paused ? 0.6 : 1
          font.family: root.fontFamily
          // Hero countdown; deliberately outside the Style.font.* scale.
          font.pixelSize: 64
          font.bold: true
        }

        Rectangle {
          width: parent.width
          height: Style.space(4)
          radius: height / 2
          color: Style.selectedFillFor(root.fg, Commons.Color.accent)

          Rectangle {
            width: parent.width * root.progress
            height: parent.height
            radius: parent.radius
            color: Commons.Color.accent
            Behavior on width { NumberAnimation { duration: 250 } }
          }
        }

        Row {
          spacing: Style.space(8)

          Button {
            iconText: root.running ? "󰏤" : "󰐊"
            text: root.running ? "Pause" : (root.phase === "idle" ? "Start" : "Resume")
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.startOrPause()
          }
          Button {
            iconText: "󰒭"
            text: "Skip"
            enabled: root.phase !== "idle"
            opacity: enabled ? 1 : 0.4
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.skip()
          }
          Button {
            iconText: "󰑐"
            text: "Reset"
            enabled: root.phase !== "idle"
            opacity: enabled ? 1 : 0.4
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.reset()
          }
        }

        // ---- TickTick task this session counts towards.
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.hasToken && root.ticktickLogging

          PanelSeparator { width: parent.width; foreground: root.fg }

          PanelSectionHeader {
            text: "WORKING ON"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Item {
            width: parent.width
            height: taskButton.height

            Button {
              id: taskButton
              anchors.left: parent.left
              anchors.right: clearTask.visible ? clearTask.left : parent.right
              anchors.rightMargin: clearTask.visible ? Style.space(6) : 0
              leftAlign: true
              iconText: root.task ? "󰄲" : "󰐕"
              text: root.task ? root.fit(root.task.title, 34) : "Pick a TickTick task"
              selected: root.pickerOpen
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.pickerOpen ? (root.pickerOpen = false) : root.openPicker()
            }

            PanelActionButton {
              id: clearTask
              visible: !!root.task
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅖"
              tooltipText: "No task"
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.chooseTask(null)
            }
          }

          Text {
            visible: !!root.task && !!root.task.project && !root.pickerOpen
            textFormat: Text.PlainText
            text: root.task ? root.task.project : ""
            color: root.dim
            leftPadding: Style.space(10)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            visible: !!root.task && !root.pickerOpen
            iconText: "󰄬"
            text: "Done, next task"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.completeTaskAndContinue()
          }

          // Picker: search box plus results; empty search lists the next two weeks.
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.pickerOpen

            TextField {
              id: taskSearchField
              width: parent.width
              placeholderText: "Search tasks… (empty = due soon)"
              text: root.taskQuery
              foreground: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              onTextEdited: {
                root.taskQuery = text
                searchDebounce.restart()
              }
              onAccepted: if (root.taskResults.length > 0) root.chooseTask(root.taskResults[0])
              Keys.onEscapePressed: {
                root.pickerOpen = false
                keyCatcher.forceActiveFocus()
              }
            }

            Text {
              visible: root.taskStatus !== ""
              textFormat: Text.PlainText
              text: root.taskStatus === "loading" ? "Loading…"
                : (root.taskStatus === "empty" ? "No matching tasks" : "Couldn't reach TickTick")
              color: root.dim
              topPadding: Style.space(4)
              leftPadding: Style.space(10)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.taskStatus === "" ? root.taskResults.slice(0, 8) : []

              Button {
                required property var modelData
                width: parent.width
                leftAlign: true
                iconText: "󰄱"
                text: root.fit(modelData.title + (modelData.project ? "  · " + modelData.project : ""), 38)
                selected: !!root.task && root.task.id === modelData.id
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.chooseTask(modelData)
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(14)
          visible: !root.pickerOpen

        PanelSeparator { width: parent.width; foreground: root.fg }

        PanelSectionHeader {
          text: "FOCUS LENGTH"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Row {
          spacing: Style.space(8)

          ButtonGroup {
            id: presetGroup
            property bool customOpen: false
            anchors.verticalCenter: parent.verticalCenter
            options: [
              { value: "25", label: "25" },
              { value: "30", label: "30" },
              { value: "50", label: "50" },
              { value: "custom", label: "Custom" }
            ]
            value: presetGroup.customOpen || root.customDuration ? "custom" : String(root.focusMinutes)
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(v) {
              if (v === "custom") {
                presetGroup.customOpen = true
                customField.forceActiveFocus()
              } else {
                presetGroup.customOpen = false
                root.saveSettings({ focusMinutes: parseInt(v, 10) })
              }
            }
          }

          TextField {
            id: customField
            visible: presetGroup.customOpen || root.customDuration
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(64)
            placeholderText: "min"
            text: root.customDuration ? String(root.focusMinutes) : ""
            validator: IntValidator { bottom: 1; top: 600 }
            foreground: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            onAccepted: {
              if (acceptableInput) root.saveSettings({ focusMinutes: parseInt(text, 10) })
              keyCatcher.forceActiveFocus()
            }
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
          }
        }

        Text {
          visible: root.phase !== "idle"
          textFormat: Text.PlainText
          text: "Changes apply from the next session."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        PanelSectionHeader {
          text: "MUSIC"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Button {
          visible: root.musicShouldPlay
          iconText: "󰑐"
          text: "Restart music"
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.replayMusic()
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.channels

            Button {
              required property var modelData
              width: parent.width
              leftAlign: true
              iconText: root.channelUrl === modelData.url && mpvProc.running ? "󰝚" : "󰎈"
              text: modelData.name
              selected: root.channelUrl === modelData.url
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.saveSettings({ channel: modelData.url })
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "AMBIENT"
            color: root.dim
            topPadding: Style.space(6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Repeater {
            model: root.ambientSounds

            Button {
              required property var modelData
              width: parent.width
              leftAlign: true
              iconText: modelData.icon
              text: modelData.name
              selected: root.channelUrl === modelData.url
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.saveSettings({ channel: modelData.url })
            }
          }

          Button {
            width: parent.width
            leftAlign: true
            iconText: "󰝛"
            text: "No music"
            selected: root.channelUrl === ""
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.saveSettings({ channel: "" })
          }
        }
        }
      }

      // ---- Divider between timer and settings.
      Rectangle {
        anchors.left: timerColumn.right
        anchors.leftMargin: Style.space(18)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.spacing.hairline
        color: root.fg
        opacity: 0.12
      }

      // ---- Right: settings.
      Column {
        id: settingsColumn
        anchors.right: parent.right
        anchors.top: parent.top
        width: parent.width - timerColumn.width - Style.space(37)
        spacing: Style.space(12)

        PanelSectionHeader {
          text: "SETTINGS"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        NumberField {
          label: "Break length (minutes)"
          value: root.breakMinutes
          from: 1
          to: 120
          foreground: root.fg
          fontFamily: root.fontFamily
          onModified: function(v) { root.saveSettings({ breakMinutes: v }) }
        }

        Toggle {
          width: parent.width
          label: "Stop music during breaks"
          description: "Resumes live when focus starts"
          checked: root.stopMusicOnBreak
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.saveSettings({ stopMusicOnBreak: !root.stopMusicOnBreak })
        }

        Toggle {
          width: parent.width
          label: "Auto-start next focus"
          description: "Right after the break"
          checked: root.autoContinue
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.saveSettings({ autoContinue: !root.autoContinue })
        }

        Toggle {
          width: parent.width
          label: "Chime when a timer ends"
          description: "Soft two-note sound"
          checked: root.chime
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.saveSettings({ chime: !root.chime })
        }

        Toggle {
          visible: root.hasToken
          width: parent.width
          label: "Log sessions to TickTick"
          description: "Pomodoro on the chosen task"
          checked: root.ticktickLogging
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.saveSettings({ ticktick: !root.ticktickLogging })
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: "Music volume  " + Math.round(volumeSlider.liveValue) + "%"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          PanelSlider {
            id: volumeSlider
            bar: root.bar
            width: parent.width
            height: Style.space(20)
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.volume
            onMoved: function(v) { root.applyVolume(Math.round(v)) }
            onReleased: function(v) { root.saveSettings({ volume: Math.round(v) }) }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        PanelSectionHeader {
          text: "CHANNELS"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.channels

            Item {
              required property var modelData
              required property int index
              width: parent.width
              height: Math.max(channelText.implicitHeight, removeButton.height)

              Column {
                id: channelText
                anchors.left: parent.left
                anchors.right: removeButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: modelData.name
                  color: root.fg
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: modelData.url.replace(/^https?:\/\/(www\.)?/, "")
                  color: root.dim
                  elide: Text.ElideMiddle
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              PanelActionButton {
                id: removeButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰆴"
                tooltipText: "Remove"
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.removeChannel(index)
              }
            }
          }
        }

        TextField {
          id: nameField
          width: parent.width
          placeholderText: "Name (e.g. Jazz radio)"
          foreground: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          onAccepted: urlField.forceActiveFocus()
          Keys.onEscapePressed: keyCatcher.forceActiveFocus()
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: urlField
            width: parent.width - addButton.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "YouTube link"
            foreground: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            onAccepted: addButton.add()
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
          }

          Button {
            id: addButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰐕"
            text: "Add"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            function add() {
              if (root.addChannel(nameField.text, urlField.text)) {
                nameField.text = ""
                urlField.text = ""
                keyCatcher.forceActiveFocus()
              }
            }
            onClicked: add()
          }
        }
      }
    }
  }
}
