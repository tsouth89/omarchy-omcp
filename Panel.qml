import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A ghost in the bar and a panel behind it. The ghost is lit while an agent is
// attached, twitches on every tool call, and turns urgent when something is
// waiting on you. The panel is the whole contract in one place: what just
// happened, what each tool is allowed to do, and how to hand the keys to an
// agent in the first place.
//
// Nothing here executes a desktop action. Every button is a call into
// bin/omcp, which is the only thing that touches the machine.
Panel {
  id: root
  moduleName: "tsouth89.omcp"
  ipcTarget: "omcp"
  manageIpc: false

  // ------------------------------------------------------------------ theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property color stateColor: engine.paused ? urgent
    : engine.awaitingApproval ? urgent
    : engine.connected ? accent
    : dim

  // ------------------------------------------------------------------ state
  property string tab: "activity"
  property int cursor: 0
  property bool cursorActive: false
  property string notice: ""

  readonly property int feedLength: setting("feedLength", 40)
  readonly property bool showIdleGhost: setting("showIdleGhost", true)

  readonly property string serverPath: engine.cli
  readonly property string claudeCommand: "claude mcp add omcp -- " + serverPath + " serve"
  readonly property string jsonConfig:
    '{\n  "mcpServers": {\n    "omcp": {\n      "command": "' + serverPath + '",\n'
    + '      "args": ["serve"]\n    }\n  }\n}'

  readonly property var tabs: ["activity", "tools", "connect"]
  readonly property var tabLabels: ({ activity: "Activity", tools: "Permissions", connect: "Connect" })

  readonly property var rows: {
    var out = []
    if (engine.awaitingApproval) {
      out.push({ id: "approve" })
      out.push({ id: "deny" })
    }
    if (tab === "activity") {
      out.push({ id: "pause" })
    } else if (tab === "tools") {
      for (var i = 0; i < engine.catalog.length; i++)
        out.push({ id: "tool:" + engine.catalog[i].name })
    } else if (tab === "connect") {
      out.push({ id: "copy-claude" })
      out.push({ id: "copy-json" })
      out.push({ id: "doctor" })
    }
    return out
  }

  readonly property string currentRowId: cursorActive && cursor >= 0 && cursor < rows.length
    ? rows[cursor].id : ""

  function hasCursor(id) { return currentRowId === id }

  // The row list changes shape underneath the cursor — Approve and Deny appear
  // at the top the moment an agent asks for something. A bare index would then
  // point at a different row than the one under the highlight, so an Enter the
  // user had already decided on could answer a request they had not read. Track
  // the row by identity and drop the cursor entirely when its row disappears.
  property string anchoredRowId: ""

  // Every deliberate cursor move goes through here, and nothing else writes the
  // anchor. Deriving it from currentRowId instead made correctness depend on
  // whether Qt refreshed the binding or ran onRowsChanged first: in the other
  // order the anchor would follow the reshaped list onto Approve, which is the
  // hazard the anchoring exists to prevent.
  function setCursor(index) {
    cursor = Math.max(0, Math.min(Math.max(0, rows.length - 1), index))
    anchoredRowId = (cursor >= 0 && cursor < rows.length) ? rows[cursor].id : ""
  }

  // Keyboard navigation has to drag the view with it. Without this the cursor
  // walks off the bottom of the visible area and the highlight is simply gone:
  // the Permissions tab is taller than the panel, so arrowing into the WRITES
  // section left the user staring at READS with no cursor in sight.
  // Only the keyboard scrolls the view. Hover sets the cursor too, and a pointer
  // drifting across rows must never yank the content out from under it.
  property bool keyboardNav: false

  function ensureVisible(item) {
    if (!keyboardNav) return
    if (!item || !panelFlick || panelFlick.contentHeight <= panelFlick.height) return
    var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
    var bottom = top + item.height
    var margin = Style.space(10)
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    if (top - margin < panelFlick.contentY)
      panelFlick.contentY = Math.max(0, top - margin)
    else if (bottom + margin > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
  }

  // Keep the highlight on whatever row it was on when the list reshapes. If
  // that row is gone, drop the cursor rather than let it point at whatever
  // slid into its place.
  function reanchorCursor() {
    if (!cursorActive) return
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].id === anchoredRowId) { cursor = i; return }
    }
    cursorActive = false
    cursor = 0
    anchoredRowId = ""
  }

  onRowsChanged: reanchorCursor()

  // -------------------------------------------------------------- behaviour

  function moveCursor(dx, dy) {
    cursorActive = true
    keyboardNav = true
    if (dx !== 0) {
      var t = tabs.indexOf(tab) + dx
      if (t >= 0 && t < tabs.length) { tab = tabs[t]; setCursor(0) }
      return
    }
    if (dy === 0) return
    setCursor(cursor + dy)
  }

  function activate() {
    if (!cursorActive) { cursorActive = true; return }
    trigger(currentRowId)
  }

  function trigger(id) {
    if (id.indexOf("tool:") === 0) {
      var name = id.substring(5)
      // No catalog reload: titles and defaults are static, and the effective
      // permission arrives on the config.json watch.
      engine.setPermission(name, Model.nextPermission(engine.permissionFor(name)))
      return
    }
    switch (id) {
      case "approve":
        engine.approve()
        flash("Approved")
        break
      case "deny":
        engine.deny()
        flash("Denied")
        break
      case "pause":
        engine.togglePause()
        break
      case "copy-claude":
        copy(root.claudeCommand)
        flash("Command copied — paste it in a terminal")
        break
      case "copy-json":
        copy(root.jsonConfig)
        flash("JSON copied — paste it into your agent's MCP config")
        break
      case "doctor":
        Quickshell.execDetached(["omarchy-launch-terminal", root.serverPath, "doctor"])
        root.close()
        break
    }
  }

  function copy(text) {
    copyProc.command = ["wl-copy", "--", text]
    copyProc.running = true
  }

  function flash(message) { notice = message; noticeTimer.restart() }

  // Collapse rather than leave an invisible slot-wide gap when the ghost is
  // hidden, the way the first-party media widget does.
  implicitWidth: button.visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = 0
    notice = ""
    if (panelFlick) panelFlick.contentY = 0
    engine.loadCatalog()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: engine
    panelOwned: true
    feedLength: root.feedLength

    // Deliberately does NOT open the panel. This surface takes exclusive
    // keyboard focus, so summoning it the moment an agent asks would yank the
    // keyboard out of whatever the user was typing into — with Approve bound to
    // a single keystroke. An agent must never be able to make the next key you
    // press mean "yes". The ghost turns red and breathes, and a notification
    // fires; opening it stays the user's move.
  }

  Timer { id: noticeTimer; interval: 3200; onTriggered: root.notice = "" }
  Process { id: copyProc; running: false; command: [] }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function openTab(name: string): string {
      if (root.tabs.indexOf(name) < 0) return "unknown tab: " + name
      root.tab = name
      root.setCursor(0)
      root.cursorActive = false
      root.open()
      return "ok"
    }
    function pause(): string { engine.setPaused(true); return "paused" }
    function resume(): string { engine.setPaused(false); return "armed" }
    function status(): string { return engine.statusLine }
  }

  // ------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    visible: root.showIdleGhost || engine.connected || engine.paused

    iconComponent: Component {
      Item {
        Text {
          id: ghost
          anchors.centerIn: parent
          text: "󰊠"
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          color: engine.paused || engine.awaitingApproval ? root.urgent
            : engine.connected ? root.barForeground
            : Qt.darker(root.barForeground, 1.7)

          // Three different reasons to move, and they must not read the same.
          // A tool call is a single twitch. A held request breathes until it is
          // answered. Paused is dead still and half faded — the ghost is off.
          property real twitch: 1.0
          property real breathe: 1.0
          opacity: engine.paused ? 0.45 : (engine.awaitingApproval ? breathe : twitch)

          SequentialAnimation {
            id: twitchAnimation
            NumberAnimation { target: ghost; property: "twitch"; to: 0.25; duration: 90 }
            NumberAnimation { target: ghost; property: "twitch"; to: 1.0; duration: 420
                              easing.type: Easing.OutQuad }
          }

          SequentialAnimation on breathe {
            running: engine.awaitingApproval
            loops: Animation.Infinite
            NumberAnimation { to: 0.3; duration: 520; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutQuad }
          }
        }

        Connections {
          target: engine
          function onActivityArrived(tool, state) { twitchAnimation.restart() }
        }

        // A refusal deserves a mark that outlives the twitch, so you can tell at
        // a glance that the last thing an agent tried did not happen.
        Rectangle {
          visible: Model.isRefusal(engine.lastState) && !engine.paused
          width: Math.max(3, Style.space(4))
          height: width
          radius: width / 2
          color: root.urgent
          anchors.right: parent.right
          anchors.top: parent.top
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) engine.togglePause()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activate()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        // Answering a held request takes a deliberate keyboard user: `a` and `d`
        // do nothing until the cursor has been moved into the panel. Otherwise
        // one stray keystroke, from someone who never saw the prompt, decides
        // it. Navigating first is the cheap proof that you are looking at it.
        if (key === "a" && engine.awaitingApproval && root.cursorActive) root.trigger("approve")
        else if (key === "d" && engine.awaitingApproval && root.cursorActive) root.trigger("deny")
        else if (key === "p") root.trigger("pause")
        else if (key === "c") { root.tab = "connect"; root.setCursor(0) }
        else if (key === "t") { root.tab = "tools"; root.setCursor(0) }
        // `f` rather than `l`: PanelKeyCatcher eats l/h/j/k as vim motion keys
        // and never emits them here.
        else if (key === "f") { root.tab = "activity"; root.setCursor(0) }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------------------ hero
          PanelHero {
            width: parent.width
            title: "OMCP"
            meta: engine.statusLine
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰊠"
                color: root.stateColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                opacity: engine.paused ? 0.5 : 1.0
              }
            }
          }

          // --------------------------------------------------- the ask
          //
          // The whole reason this plugin has a UI. An agent asked for something
          // gated, the call is parked mid-flight, and it stays parked until one
          // of these two buttons is pressed or the countdown runs out.
          Rectangle {
            visible: engine.awaitingApproval
            width: parent.width
            implicitHeight: askColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.55)

            Column {
              id: askColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: engine.pending
                  ? (Model.agentLabel(engine.pending.agent) + " wants to " + engine.pending.summary)
                  : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: engine.pending
                  ? (engine.pending.tool + " · denied automatically in "
                     + Model.duration(engine.approvalRemaining))
                  : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                spacing: Style.space(8)

                AskButton {
                  rowId: "approve"
                  label: "Approve"
                  hint: "a"
                  tone: root.accent
                }
                AskButton {
                  rowId: "deny"
                  label: "Deny"
                  hint: "d"
                  tone: root.urgent
                }
              }
            }
          }

          Text {
            visible: root.notice !== ""
            width: parent.width
            text: root.notice
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------------------------ tabs
          Row {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.tabs
              TabChip {
                required property var modelData
                tabId: modelData
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // -------------------------------------------------- activity tab
          Column {
            visible: root.tab === "activity"
            width: parent.width
            spacing: Style.space(10)

            ActionRow {
              width: parent.width
              rowId: "pause"
              glyph: engine.paused ? "" : "󰊠"
              title: engine.paused ? "Paused" : "Stop everything"
              subtitle: engine.paused
                ? "no tool will run, not even a read · p"
                : "the kill switch · p"
              trailing: true
              trailingOn: engine.paused
            }

            PanelSectionHeader {
              visible: engine.connected
              text: "CONNECTED"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: engine.agents
                delegate: Row {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    text: ""
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: Model.agentLabel(modelData)
                      + (modelData.version ? " " + modelData.version : "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    text: (modelData.calls || 0) + " calls · here "
                      + Model.duration(Math.max(0, engine.now - (modelData.since || engine.now)))
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            PanelSectionHeader {
              text: "WHAT IT TOUCHED"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: engine.activity.length === 0
              width: parent.width
              text: "Nothing yet. Connect an agent from the Connect tab, then ask it to "
                + "switch your theme and watch this fill up."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: engine.activity
                delegate: FeedRow {
                  required property var modelData
                  width: parent.width
                  entry: modelData
                }
              }
            }
          }

          // ------------------------------------------------- permissions tab
          Column {
            visible: root.tab === "tools"
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: "Every tool is one of three things: Allow runs it, Ask parks it here until "
                + "you answer, Off hides it from the agent completely. There is no tool that "
                + "runs an arbitrary command — that one does not exist on purpose."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PanelSectionHeader {
              text: "READS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(2)
              Repeater {
                model: engine.catalog
                delegate: ToolRow {
                  required property var modelData
                  width: parent.width
                  visible: !modelData.write
                  tool: modelData
                }
              }
            }

            PanelSectionHeader {
              text: "WRITES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(2)
              Repeater {
                model: engine.catalog
                delegate: ToolRow {
                  required property var modelData
                  width: parent.width
                  visible: modelData.write
                  tool: modelData
                }
              }
            }
          }

          // ----------------------------------------------------- connect tab
          Column {
            visible: root.tab === "connect"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: "OMCP speaks MCP over stdio. Point an agent at the command below "
                + "and it gets the tools you left switched on — nothing else."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            ActionRow {
              width: parent.width
              rowId: "copy-claude"
              glyph: ""
              title: "Copy the Claude Code command"
              subtitle: "claude mcp add omcp — one line, one terminal"
            }

            CodeBlock { width: parent.width; content: root.claudeCommand }

            ActionRow {
              width: parent.width
              rowId: "copy-json"
              glyph: ""
              title: "Copy the JSON config"
              subtitle: "for Codex, Zed, or anything else that reads mcpServers"
            }

            ActionRow {
              width: parent.width
              rowId: "doctor"
              glyph: ""
              title: "Run the doctor"
              subtitle: "checks every command this needs, in a terminal"
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- components

  component TabChip: CursorSurface {
    id: tabButton
    property string tabId: ""
    readonly property bool selected: root.tab === tabId

    hasCursor: tabButton.selected
    foreground: root.foreground
    implicitWidth: tabLabel.implicitWidth + Style.space(20)
    implicitHeight: tabLabel.implicitHeight + Style.space(10)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { root.tab = tabButton.tabId; root.setCursor(0); root.cursorActive = false }
    }

    Text {
      id: tabLabel
      anchors.centerIn: parent
      text: root.tabLabels[tabButton.tabId] || tabButton.tabId
      color: tabButton.selected ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component AskButton: CursorSurface {
    id: askButton
    property string rowId: ""
    property string label: ""
    property string hint: ""
    property color tone: root.foreground

    hasCursor: root.hasCursor(askButton.rowId)
    foreground: askButton.tone
    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
    implicitWidth: askLabel.implicitWidth + Style.space(28)
    implicitHeight: askLabel.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.keyboardNav = false
        for (var i = 0; i < root.rows.length; i++)
          if (root.rows[i].id === askButton.rowId) root.setCursor(i)
      }
      onClicked: root.trigger(askButton.rowId)
    }

    Text {
      id: askLabel
      anchors.centerIn: parent
      text: askButton.label + "  " + askButton.hint
      color: askButton.tone
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property string rowId: ""
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    property bool trailing: false
    property bool trailingOn: false

    hasCursor: root.hasCursor(actionRow.rowId)
    foreground: root.foreground
    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.keyboardNav = false
        for (var i = 0; i < root.rows.length; i++)
          if (root.rows[i].id === actionRow.rowId) root.setCursor(i)
      }
      onClicked: root.trigger(actionRow.rowId)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        text: actionRow.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: actionContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: actionRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          visible: actionRow.subtitle !== ""
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      ToggleSwitch {
        visible: actionRow.trailing
        checked: actionRow.trailingOn
        hasCursor: actionRow.hasCursor
        foreground: root.foreground
        Layout.alignment: Qt.AlignVCenter
        onToggled: root.trigger(actionRow.rowId)
      }
    }
  }

  // One tool, one three-state control. Clicking anywhere on the row cycles it,
  // which is faster than aiming at a dropdown and is how the keyboard path
  // works too.
  component ToolRow: CursorSurface {
    id: toolRow
    property var tool: null
    readonly property string toolName: tool ? tool.name : ""
    readonly property string permission: engine.permissionFor(toolName)

    hasCursor: root.hasCursor("tool:" + toolName)
    foreground: root.foreground
    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
    implicitHeight: toolContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.keyboardNav = false
        for (var i = 0; i < root.rows.length; i++)
          if (root.rows[i].id === "tool:" + toolRow.toolName) root.setCursor(i)
      }
      onClicked: root.trigger("tool:" + toolRow.toolName)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      ColumnLayout {
        id: toolContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: toolRow.tool ? toolRow.tool.title : ""
          color: toolRow.permission === "deny" ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          text: toolRow.toolName
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: permissionLabel.implicitWidth + Style.space(16)
        implicitHeight: permissionLabel.implicitHeight + Style.space(8)
        radius: Style.cornerRadius
        color: toolRow.permission === "allow" ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
          : toolRow.permission === "ask" ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
          : "transparent"
        border.width: 1
        border.color: toolRow.permission === "deny"
          ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
          : "transparent"

        Text {
          id: permissionLabel
          anchors.centerIn: parent
          text: Model.permissionLabel(toolRow.permission)
          color: toolRow.permission === "allow" ? root.accent
            : toolRow.permission === "ask" ? root.foreground
            : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component FeedRow: Item {
    id: feedRow
    property var entry: null
    implicitHeight: feedLayout.implicitHeight + Style.space(6)

    RowLayout {
      id: feedLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        text: feedRow.entry ? Model.clockTime(feedRow.entry.ts) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignTop
      }

      Text {
        text: feedRow.entry ? Model.stateGlyph(feedRow.entry.state) : ""
        color: feedRow.entry && Model.isRefusal(feedRow.entry.state) ? root.urgent
          : feedRow.entry && feedRow.entry.state === "error" ? root.urgent
          : feedRow.entry && feedRow.entry.state === "asked" ? root.foreground
          : root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignTop
      }

      Text {
        Layout.fillWidth: true
        text: feedRow.entry ? (feedRow.entry.summary || feedRow.entry.tool) : ""
        color: feedRow.entry && Model.isRefusal(feedRow.entry.state) ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
    }
  }

  component CodeBlock: Rectangle {
    id: codeBlock
    property string content: ""
    implicitHeight: codeText.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

    Text {
      id: codeText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      text: codeBlock.content
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WrapAnywhere
    }
  }
}
