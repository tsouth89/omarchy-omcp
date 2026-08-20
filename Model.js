.pragma library

// Formatting and parsing shared by the bar icon and the panel. Kept out of QML
// so the bindings over there read as layout rather than as string work.

var PERMISSIONS = ["allow", "ask", "deny"]

// What each permission promises, in the panel's own words.
var PERMISSION_LABEL = { allow: "Allow", ask: "Ask", deny: "Off" }
var PROFILE_LABEL = { observe: "Observe", present: "Present", operate: "Operate", custom: "Custom" }
var PROFILE_DESCRIPTION = {
  observe: "Read desktop state. Screenshots and clipboard reads still ask; every write is Off.",
  present: "Arrange and tune the desktop. Starting apps, opening links, clipboard writes, closing windows, and locking stay Off.",
  operate: "The reviewed defaults: most desktop actions run, while sensitive operations ask first.",
  custom: "Your per-tool choices no longer match a built-in profile."
}

function nextPermission(current) {
  var i = PERMISSIONS.indexOf(current)
  return PERMISSIONS[(i < 0 ? 0 : (i + 1) % PERMISSIONS.length)]
}

function permissionLabel(value) { return PERMISSION_LABEL[value] || value }
function profileLabel(value) { return PROFILE_LABEL[value] || value }
function profileDescription(value) { return PROFILE_DESCRIPTION[value] || PROFILE_DESCRIPTION.custom }

function clockTime(epochSeconds) {
  if (!epochSeconds) return ""
  var d = new Date(epochSeconds * 1000)
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return pad(d.getHours()) + ":" + pad(d.getMinutes())
}


function duration(seconds) {
  if (seconds < 60) return seconds + "s"
  if (seconds < 3600) return Math.floor(seconds / 60) + "m"
  return Math.floor(seconds / 3600) + "h"
}

// The activity log is JSONL: one record per tool call, oldest first. A partial
// last line is normal — the server may be mid-append — so bad lines are skipped
// rather than treated as an error.
function parseActivity(raw, limit) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (line === "") continue
    try {
      var entry = JSON.parse(line)
      if (entry && entry.tool) out.push(entry)
    } catch (e) {
      // half-written trailing line; the next change event brings the rest
    }
  }
  if (limit > 0 && out.length > limit) out = out.slice(out.length - limit)
  return out.reverse()
}

// Feed rows earn their glyph from the outcome, not the tool: what you scan for
// is "did anything get refused", and that has to be visible at a glance.
function stateGlyph(state) {
  switch (state) {
    case "ok": return ""        // check
    case "denied": return ""    // ban
    case "blocked": return ""
    case "asked": return ""     // question
    case "error": return ""     // warning
  }
  return ""
}

function isRefusal(state) {
  return state === "denied" || state === "blocked"
}

// Takes either an entry from the agent registry or the bare name string the
// pending request carries, so both callers can share one spelling of a name.
function agentLabel(agent) {
  if (!agent) return ""
  var name = String((typeof agent === "string" ? agent : agent.name) || "agent")
  return name.replace(/^claude-code$/, "Claude Code").replace(/^codex(-cli)?$/, "Codex")
}

// One line summarising who is attached, used under the panel title and in the
// tooltip. Reads as a sentence in every case, including none.
function agentSummary(agents) {
  if (!agents || agents.length === 0) return "no agent connected"
  if (agents.length === 1) return agentLabel(agents[0]) + " connected"
  return agents.length + " agents connected"
}

function callCount(agents) {
  var total = 0
  for (var i = 0; i < (agents || []).length; i++) total += agents[i].calls || 0
  return total
}
