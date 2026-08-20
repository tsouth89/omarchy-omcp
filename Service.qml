import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The engine behind the ghost. Two instances exist: one the panel owns, and one
// the shell mounts headless (kind: "service") so keybinds and scripts can reach
// the kill switch whether or not the bar icon is placed.
//
// It holds no state of its own. The MCP server owns everything on disk — the
// permission file, the agent registry, the activity log, the request waiting for
// an answer — and this watches those four files. Nothing here polls: every
// property below moves because inotify said a file changed.
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
  // The server resolves these through XDG_CONFIG_HOME / XDG_STATE_HOME. If the
  // panel assumed the defaults, a user with either set would get a working
  // server and a permanently dead panel — approvals would never appear and
  // would time out to denied.
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string configPath: configHome + "/omcp/config.json"
  readonly property string statePath: stateHome + "/omcp"
  readonly property string cli: Qt.resolvedUrl("bin/omcp").toString().replace(/^file:\/\//, "")

  // ------------------------------------------------------------------ state
  property bool paused: false
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
    : connected ? agentSummary + " · " + callCount + " calls"
    : "no agent connected"

  signal activityArrived(string tool, string state)

  // The config file only stores overrides, so a tool the user has never touched
  // has no entry — its real permission is the default the server ships for it.
  // Falling back to a blanket "allow" here would have the panel claim a gated
  // tool was wide open while the server was still holding it for approval.
  function permissionFor(name) {
    var value = permissions[name]
    if (value !== undefined) return value
    for (var i = 0; i < catalog.length; i++)
      if (catalog[i].name === name) return catalog[i].default
    return "allow"
  }

  // -------------------------------------------------------------- the files

  FileView {
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
    } catch (e) {
      paused = false
      permissions = ({})
    }
  }

  FileView {
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

  // ------------------------------------------------------------------- time
  //
  // Two clocks rather than one. The slow one keeps "3m ago" honest; the fast one
  // only runs while a request is counting down, because that is the only second
  // anyone is watching.

  // One clock, three speeds, because the thing on screen that moves fastest
  // decides how often anything needs recomputing: a countdown ticks in seconds,
  // an attached agent's "here 40s" reads wrong if it lags, and an idle machine
  // has nothing to update at all.
  Timer {
    interval: root.pending !== null ? 1000 : (root.connected ? 5000 : 30000)
    repeat: true
    // Idle means idle: with no agent attached and nothing pending, the inotify
    // watches already cover every change, so the tick only needs to exist as a
    // rotation backstop while something is actually happening.
    running: root.connected || root.pending !== null || root.agentsRaw.length > 0
    onTriggered: {
      root.now = Math.floor(Date.now() / 1000)
      if (root.pending && root.pending.expires <= root.now) root.pending = null
      activityFile.reload()   // backstop: recover a watch lost to a rotation
    }
  }

  // ------------------------------------------------------------- run the CLI

  function setPermission(name, value) { runCli(["set", name, value]) }
  function togglePause() { runCli(["pause", paused ? "off" : "on"]) }
  function setPaused(value) { runCli(["pause", value ? "on" : "off"]) }
  function approve() { if (pending) { runCli(["decide", pending.id, "allow"]); pending = null } }
  function deny() { if (pending) { runCli(["decide", pending.id, "deny"]); pending = null } }

  // Detached, not a shared Process object: assigning `running = true` while the
  // previous call was still going was a silent no-op, so approving and then
  // immediately pausing would drop the pause.
  function runCli(args) {
    Quickshell.execDetached([cli].concat(args))
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
          root.catalog = JSON.parse(text || "{}").tools || []
        } catch (e) {
          root.catalog = []
        }
      }
    }
  }

  function loadCatalog() { if (!catalogProc.running) catalogProc.running = true }

  // Scripts and keybinds talk to the headless copy; the panel owns the target
  // name so a notification can summon the real UI.
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
