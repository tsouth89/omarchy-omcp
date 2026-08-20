import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The engine behind the ghost. Two instances exist: one the panel owns, and one
// the shell mounts as kind: "service". For a third-party plugin that service is
// only created while this widget is on the bar; `omcp pause` (the CLI) is the
// path that still works with the ghost unplaced.
//
// It holds no state of its own. The MCP server owns everything on disk and this
// watches those four files. A slow timer reloads them as a backstop when an
// atomic replace drops an inotify watch.
Item {
  id: root

  // Set by the panel on its own copy, so the headless instance knows not to
  // claim the IPC target the panel wants.
  property bool panelOwned: false

  // Injected by shell.qml when mounted as a service. Unused, but declaring them
  // keeps the shell from warning about missing properties.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string home: Quickshell.env("HOME")
  // Same paths the server uses: passwd-home `~/.config/omcp` and
  // `~/.local/state/omcp`. Honouring a client-injected XDG_* on the server
  // while the panel read the shell's would split the permission file from the
  // ghost, so neither side follows XDG.
  readonly property string configPath: home + "/.config/omcp/config.json"
  readonly property string statePath: home + "/.local/state/omcp"
  readonly property string cli: {
    var raw = Qt.resolvedUrl("bin/omcp").toString()
    if (raw.indexOf("file://") === 0) raw = raw.substring(7)
    if (raw.indexOf("localhost/") === 0) raw = raw.substring(9)
    try { return decodeURIComponent(raw) } catch (e) { return raw }
  }

  // ------------------------------------------------------------------ state
  property bool paused: false
  property string profile: "operate"
  property string catalogProfile: "operate"
  property var permissions: ({})
  property var agentsRaw: []
  // Derived, not stored: a SIGKILLed agent never rewrites the registry, so if
  // the filter only ran on file change its entry stayed lit forever — and kept
  // the poll timer in its fast mode on an idle machine.
  readonly property var agents: {
    var live = []
    for (var i = 0; i < agentsRaw.length; i++)
      if (now - (agentsRaw[i].lastSeen || 0) < 60) live.push(agentsRaw[i])
    return live
  }
  property var activity: []
  property var pending: null
  property var catalog: []
  property var profilePermissions: ({})
  property int now: Math.floor(Date.now() / 1000)
  property int feedLength: 40

  // The most recent record's outcome, so the bar icon can mark a refusal.
  property string lastState: ""

  readonly property bool connected: agents.length > 0
  readonly property int callCount: Model.callCount(agents)
  readonly property string agentSummary: Model.agentSummary(agents)
  readonly property bool awaitingApproval: pending !== null && pending.expires > now
  readonly property int approvalRemaining: awaitingApproval ? Math.max(0, pending.expires - now) : 0

  // The one line the tooltip and the hero both want.
  readonly property string statusLine: paused ? "paused — nothing can run"
    : awaitingApproval ? "waiting for you to answer"
    // Shared shell components own the Text items behind the hero and tooltip,
    // so this value deliberately contains counts only, never client text.
    : connected ? agents.length + (agents.length === 1 ? " agent" : " agents")
      + " connected · " + callCount + " calls"
    : "no agent connected"

  signal activityArrived(string tool, string state)
  signal commandFinished(var args, bool succeeded)

  // What the user just asked for, shown immediately and dropped as soon as the
  // config file confirms it. Without this the badge and the switch only move
  // once the CLI has written and inotify has fired.
  property var desiredPermissions: ({})
  property var desiredPaused: null
  property string desiredProfile: ""

  readonly property bool pausedShown: desiredPaused !== null ? desiredPaused : paused
  readonly property string profileShown: desiredProfile !== "" ? desiredProfile : profile

  function permissionFor(name) {
    if (desiredPermissions[name] !== undefined) return desiredPermissions[name]
    var value = permissions[name]
    if (value !== undefined) return value
    for (var i = 0; i < catalog.length; i++)
      if (catalog[i].name === name) return catalog[i].default
    return "ask"
  }

  // -------------------------------------------------------------- the files

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onFileChanged: reload()
    onLoadFailed: root.applyConfig("")
  }

  function applyConfig(raw) {
    try {
      var config = JSON.parse(raw || "{}")
      paused = !!config.paused
      permissions = config.tools || ({})
      // Older config files predate named profiles. The CLI catalogue below
      // performs the authoritative inference from their permission map.
      profile = config.profile || catalogProfile
    } catch (e) {
      paused = false
      profile = "custom"
      // Match the server's fail-closed treatment of an existing malformed
      // config instead of falling through to permissive catalogue defaults.
      var gated = {}
      for (var i = 0; i < catalog.length; i++) gated[catalog[i].name] = "ask"
      permissions = gated
    }
    // The file is the truth again; drop every overlay it has caught up with.
    if (desiredPaused !== null && desiredPaused === paused) desiredPaused = null
    var pending = {}
    for (var k in desiredPermissions)
      if (permissions[k] !== desiredPermissions[k]) pending[k] = desiredPermissions[k]
    desiredPermissions = pending
    if (desiredProfile !== "" && desiredProfile === profile) desiredProfile = ""
  }

  FileView {
    id: agentsFile
    path: root.statePath + "/agents.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyAgents(text())
    onFileChanged: reload()
    onLoadFailed: root.agentsRaw = []
  }

  // An agent that was killed rather than closed never gets to remove itself, so
  // liveness is decided here on `lastSeen` instead of trusting the file.
  function applyAgents(raw) {
    // agents.json moving is the cheapest signal that something is alive; use it
    // to re-read the feed in case its own watch was lost to a rotation.
    activityFile.reload()
    try {
      agentsRaw = (JSON.parse(raw || "{}").agents) || []
    } catch (e) {
      agentsRaw = []
    }
  }

  FileView {
    id: activityFile
    path: root.statePath + "/activity.jsonl"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyActivity(text())
    onFileChanged: reload()
    onLoadFailed: root.activity = []
  }

  function applyActivity(raw) {
    var next = Model.parseActivity(raw, root.feedLength)
    var head = next.length > 0 ? next[0] : null
    var changed = head && (activity.length === 0
      || head.ts !== activity[0].ts || head.tool !== activity[0].tool
      || head.state !== activity[0].state || head.summary !== activity[0].summary
      || next.length !== activity.length)
    // Reassigning the array resets the Repeater and rebuilds every delegate, so
    // only do it when the contents actually moved. The backstop reload fires on
    // a timer and would otherwise churn the whole feed for nothing.
    if (!changed && next.length === activity.length) return
    activity = next
    if (changed && head) {
      lastState = head.state
      activityArrived(head.tool, head.state)
    }
  }

  FileView {
    id: pendingFile
    path: root.statePath + "/pending.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyPending(text())
    onFileChanged: reload()
    onLoadFailed: root.pending = null
  }

  function applyPending(raw) {
    try {
      var request = JSON.parse(raw || "null")
      pending = (request && request.id) ? request : null
    } catch (e) {
      pending = null
    }
  }

  function reloadWatches() {
    configFile.reload()
    agentsFile.reload()
    activityFile.reload()
    pendingFile.reload()
  }

  // ------------------------------------------------------------------- time
  //
  // One clock, three speeds, plus a short prime after mount. The omcp state
  // dirs do not exist until the CLI first runs, and FileView cannot watch a
  // parent that is not there yet — so the first few ticks mkdir (via `omcp
  // tools`) and re-attach the watches.
  property int primeTicks: 0

  Timer {
    interval: root.primeTicks < 8 || root.pending !== null ? 1000 : (root.connected ? 5000 : 30000)
    repeat: true
    running: root.primeTicks < 8 || root.connected || root.pending !== null || root.agentsRaw.length > 0
    onTriggered: {
      if (root.primeTicks < 8) root.primeTicks += 1
      root.now = Math.floor(Date.now() / 1000)
      if (root.pending && root.pending.expires <= root.now) root.pending = null
      root.reloadWatches()
    }
  }

  // ------------------------------------------------------------- run the CLI

  function setPermission(name, value) {
    var next = {}
    for (var k in desiredPermissions) next[k] = desiredPermissions[k]
    next[name] = value
    desiredPermissions = next
    desiredProfile = "custom"
    runCli(["set", name, value])
  }

  function setProfile(name) {
    if (["observe", "present", "operate"].indexOf(name) < 0) return
    desiredProfile = name
    var next = {}
    var template = profilePermissions[name] || ({})
    for (var key in template) next[key] = template[key]
    desiredPermissions = next
    runCli(["profile", name])
  }

  function togglePause() { setPaused(!pausedShown) }

  function setPaused(value) {
    desiredPaused = value
    runCli(["pause", value ? "on" : "off"])
  }
  function approve(expectedId) {
    if (pending && String(pending.id) === String(expectedId)) {
      runCli(["decide", pending.id, "allow"])
      pending = null
    }
  }
  function deny(expectedId) {
    if (pending && String(pending.id) === String(expectedId)) {
      runCli(["decide", pending.id, "deny"])
      pending = null
    }
  }

  // Configuration writes are serialized. Separate detached processes could
  // acquire the file lock in a different order than the user's clicks, making
  // a rapid profile → tool or profile → profile change finish backwards.
  property var cliQueue: []
  property var activeCliArgs: []

  function runCli(args) {
    var next = cliQueue.slice()
    next.push(args)
    cliQueue = next
    pumpCli()
  }

  function pumpCli() {
    if (cliProc.running || cliQueue.length === 0) return
    var next = cliQueue.slice()
    var args = next.shift()
    cliQueue = next
    activeCliArgs = args
    cliProc.command = [cli].concat(args)
    cliProc.running = true
  }

  Process {
    id: cliProc
    running: false
    command: []
    onExited: function(exitCode) {
      var finished = root.activeCliArgs
      root.activeCliArgs = []
      if (exitCode !== 0) {
        root.desiredPermissions = ({})
        root.desiredProfile = ""
        root.desiredPaused = null
      }
      root.commandFinished(finished, exitCode === 0)
      root.reloadWatches()
      Qt.callLater(root.pumpCli)
    }
  }

  // The tool list is read once per shell session: it only changes when the
  // plugin itself is updated.
  Process {
    id: catalogProc
    running: false
    command: [root.cli, "tools", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var response = JSON.parse(text || "{}")
          root.catalog = response.tools || []
          root.profilePermissions = response.profiles || ({})
          if (response.profile) root.catalogProfile = response.profile
          if (root.desiredProfile === "" && response.profile) root.profile = response.profile
        } catch (e) {
          root.catalog = []
          root.profilePermissions = ({})
        }
        root.reloadWatches()
      }
    }
  }

  readonly property bool catalogLoading: catalogProc.running

  function loadCatalog() { if (!catalogProc.running) catalogProc.running = true }

  // Live while the widget is on the bar. Without it, `omcp pause on` still
  // writes config.json and the server honours that without QML.
  IpcHandler {
    target: "omcp-service"
    enabled: !root.panelOwned

    function pause(): string { root.setPaused(true); return "paused" }
    function resume(): string { root.setPaused(false); return "armed" }
    function toggle(): string { root.togglePause(); return root.paused ? "armed" : "paused" }
    function status(): string { return root.statusLine }
    function agents(): string { return String(root.agents.length) }
  }

  Component.onCompleted: loadCatalog()
}
