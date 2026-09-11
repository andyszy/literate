import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Hold-to-open action menu for one workspace: rename it (model-suggested or
// manual), spin a group of its windows onto another workspace, or close
// everything on it. Summoned with `omarchy-shell shell summon literate
// '{"workspace":"3"}'` -- see bin/literate-workspace-namer --suggest for the
// payload this reads.
//
// Also hosts the full-desktop triage view (Triage.qml), summoned with
// `omarchy-shell shell summon literate '{"mode":"triage"}'`: every window on
// every workspace, grouped by activity via `literate-workspace-namer
// --triage`. It lives here rather than as its own manifest entry point --
// see Triage.qml's header comment for why -- selected by root.triageMode,
// which open() sets from the payload's "mode" field.
//
// Lifecycle contract mirrors /usr/share/omarchy/shell/plugins/menu/Menu.qml
// and plugins/clipboard/Clipboard.qml: open(payloadJson)/close()/ping(), and
// every host-injected property below is PLAIN with a default, never
// `required`. shell.qml's panel Loader assigns omarchyPath/shell/manifest/
// pluginRegistry from onLoaded, i.e. *after* construction -- a `required`
// declaration here makes the plugin fail to load entirely (this already
// broke the bar on this machine once; see CLAUDE.md).
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned. Keep plain.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  // ---------------------------------------------------------------- state

  property bool opened: false
  // Selects which of the two lifecycle contracts below open()/close() run:
  // the per-workspace action menu (default), or the full-desktop triage
  // view in Triage.qml, driven by the summon payload's "mode" field. See
  // Triage.qml's header comment for why this lives here rather than as its
  // own manifest entry point.
  property bool triageMode: false
  property string workspaceId: ""
  property int windowCount: -1
  // Fallback close-all target list, filled from `hyprctl -j clients` so the
  // static actions still work even if the namer call fails or times out.
  property var fallbackAddresses: []

  property bool suggestLoading: false
  property bool suggestFailed: false
  property string suggestErrorText: ""
  property string suggestedName: ""
  property string suggestedIcon: ""
  property var suggestedWindows: []   // [{index,address,class,title}]
  property var groups: []             // [{name,icon,indices}]

  property bool manualRenameActive: false
  property string manualRenameText: ""

  property bool spinOutMode: false
  property int spinOutGroupIndex: -1

  property bool cursorActive: false
  property int selectedIndex: 0

  // Rows recompute whenever any property read inside computeRows() changes
  // -- the same pattern Menu.qml's derived-size properties use.
  property var visibleRows: root.computeRows()

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.opened = true
    root.manualRenameActive = false
    root.manualRenameText = ""
    root.spinOutMode = false
    root.spinOutGroupIndex = -1
    root.cursorActive = false
    root.selectedIndex = 0

    root.triageMode = payload.mode === "triage"
    if (root.triageMode) {
      root.workspaceId = ""
      root.windowCount = -1
      root.fallbackAddresses = []
      root.suggestLoading = false
      root.suggestFailed = false
      root.suggestErrorText = ""
      root.suggestedName = ""
      root.suggestedIcon = ""
      root.suggestedWindows = []
      root.groups = []
      triageView.open()
      // SUPER+SHIFT+<n> ("move category to workspace N") is a GLOBAL
      // Hyprland bind, so the compositor would consume it before triage (a
      // plain Wayland client) ever sees the keypress. Shadow it for as long
      // as triage is open via the "literate-triage" submap defined in
      // bindings.lua; close() resets it on every exit path. See CLAUDE.md.
      root.enterTriageSubmap()
    } else {
      root.workspaceId = String(payload.workspace || "")
      root.windowCount = -1
      root.fallbackAddresses = []
      root.suggestLoading = true
      root.suggestFailed = false
      root.suggestErrorText = ""
      root.suggestedName = ""
      root.suggestedIcon = ""
      root.suggestedWindows = []
      root.groups = []

      // Window count so the header can read "Workspace N · M windows" the
      // instant the panel appears, without waiting on the model call.
      clientsProc.command = ["hyprctl", "-j", "clients"]
      clientsProc.running = true

      suggestProc.command = [root.binPath, "--suggest", root.workspaceId]
      suggestProc.running = true
      suggestTimeoutTimer.restart()
    }

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.manualRenameActive = false
    root.spinOutMode = false
    suggestTimeoutTimer.stop()
    if (suggestProc.running) suggestProc.running = false
    if (root.triageMode) triageView.close()
    // Belt-and-braces: reset unconditionally on every close path (Escape,
    // Enter/activate, scrim click, IPC hide, this function in general).
    // Dispatching a submap reset when not in one is harmless, and being
    // stuck in a submap with only 9 chords working is a much worse failure
    // than one redundant dispatch. See also Component.onDestruction below.
    root.resetTriageSubmap()
  }

  function ping() { return "ok" }

  // IPC entry point for the SUPER+SHIFT+<n> binds in the "literate-triage"
  // Hyprland submap (see bindings.lua): moves the highlighted row's whole
  // category to workspace `arg`, then closes -- what pressing digit N used
  // to do directly, before digits became Triage.qml's search box. Lives
  // here rather than on Triage.qml because only this Item is the manifest
  // entry point the host (and `omarchy-shell shell call`) can reach.
  function triageMove(arg) {
    if (!root.opened || !root.triageMode) return "not in triage"
    triageView.moveCurrentCategory(String(arg))
    return "ok"
  }

  function enterTriageSubmap() {
    submapProc.command = ["hyprctl", "dispatch", 'hl.dsp.submap("literate-triage")']
    submapProc.running = true
  }

  function resetTriageSubmap() {
    submapProc.command = ["hyprctl", "dispatch", 'hl.dsp.submap("reset")']
    submapProc.running = true
  }

  Component.onDestruction: root.resetTriageSubmap()

  // Resolve this component's own directory rather than trusting PATH --
  // Qt.resolvedUrl resolves relative to the QML file it's evaluated in.
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    url = url.replace(/^file:\/\//, "").replace(/\/+$/, "")
    return url
  }
  readonly property string binPath: root.pluginDir + "/bin/literate-workspace-namer"

  // ----------------------------------------------------------- namer call

  function handleClientsResult(raw) {
    var count = 0
    var addrs = []
    try {
      var clients = JSON.parse(raw || "[]")
      for (var i = 0; i < clients.length; i++) {
        var c = clients[i]
        if (c && c.workspace && String(c.workspace.id) === root.workspaceId) {
          count++
          if (c.address) addrs.push(c.address)
        }
      }
      root.windowCount = count
      root.fallbackAddresses = addrs
    } catch (e) {
      // Leave windowCount at -1 (unknown); the suggest result or the user's
      // own eyes are the fallback.
    }
  }

  function handleSuggestLine(line) {
    if (!root.suggestLoading) return // stray output after timeout/close
    var data
    try { data = JSON.parse(line) } catch (e) { return }
    if (!data || typeof data !== "object") return

    suggestTimeoutTimer.stop()
    root.suggestLoading = false

    if (data.error) {
      root.suggestFailed = true
      root.suggestErrorText = String(data.error)
      return
    }

    root.suggestedName = String(data.name || "")
    root.suggestedIcon = String(data.icon || "")
    root.suggestedWindows = Array.isArray(data.windows) ? data.windows : []
    root.groups = Array.isArray(data.groups) ? data.groups : []
    if (root.windowCount < 0) root.windowCount = root.suggestedWindows.length
    root.settleCursor()
  }

  function windowByIndex(idx) {
    for (var i = 0; i < root.suggestedWindows.length; i++) {
      if (root.suggestedWindows[i].index === idx) return root.suggestedWindows[i]
    }
    return null
  }

  function currentAddresses() {
    if (root.suggestedWindows.length > 0) {
      var out = []
      for (var i = 0; i < root.suggestedWindows.length; i++) {
        if (root.suggestedWindows[i].address) out.push(root.suggestedWindows[i].address)
      }
      return out
    }
    return root.fallbackAddresses
  }

  // -------------------------------------------------------------- actions

  function runRename(name, icon) {
    var args = [root.binPath, "--pin", root.workspaceId, name]
    if (icon) args.push(icon)
    renameProc.command = args
    renameProc.running = true
    root.close()
  }

  function acceptSuggestedRename() {
    if (root.suggestLoading || root.suggestFailed || !root.suggestedName) return
    root.runRename(root.suggestedName, root.suggestedIcon)
  }

  function beginManualRename() {
    root.manualRenameActive = true
    root.manualRenameText = root.suggestedName || ""
    Qt.callLater(function() {
      manualRenameField.forceActiveFocus()
      manualRenameField.selectAll()
    })
  }

  function commitManualRename() {
    var name = String(root.manualRenameText || "").replace(/^\s+|\s+$/g, "")
    if (!name) { root.cancelManualRename(); return }
    root.runRename(name, root.suggestedIcon)
  }

  function cancelManualRename() {
    root.manualRenameActive = false
    root.manualRenameText = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function beginSpinOut(groupIndex) {
    if (groupIndex < 0 || groupIndex >= root.groups.length) return
    root.spinOutMode = true
    root.spinOutGroupIndex = groupIndex
  }

  function cancelSpinOut() {
    root.spinOutMode = false
    root.spinOutGroupIndex = -1
  }

  function completeSpinOut(target) {
    var group = root.groups[root.spinOutGroupIndex]
    root.spinOutMode = false
    root.spinOutGroupIndex = -1
    if (!group) { root.close(); return }

    var indices = group.indices || []
    var addrs = []
    for (var i = 0; i < indices.length; i++) {
      var w = root.windowByIndex(indices[i])
      if (w && w.address) addrs.push(w.address)
    }
    if (addrs.length > 0) {
      var dispatches = []
      for (var j = 0; j < addrs.length; j++)
        // This Hyprland is Lua-configured: `hyprctl dispatch` is shorthand for
        // hl.dispatch(...), so the classic "movetoworkspacesilent 4,address:0x.."
        // string form is a Lua syntax error, not a dispatch. It fails on stderr
        // and looks exactly like nothing happening.
        dispatches.push('dispatch hl.dsp.window.move({ workspace = "' + target
          + '", follow = false, window = "address:' + addrs[j] + '" })')
      spinOutProc.command = ["hyprctl", "--batch", dispatches.join(" ; ")]
      spinOutProc.running = true
    }
    root.close()
  }

  function closeAllWindows() {
    var addrs = root.currentAddresses()
    if (addrs.length > 0) {
      var dispatches = []
      for (var i = 0; i < addrs.length; i++)
        // Lua dispatcher form, as above.
        dispatches.push('dispatch hl.dsp.window.close({ window = "address:'
          + addrs[i] + '" })')
      closeAllProc.command = ["hyprctl", "--batch", dispatches.join(" ; ")]
      closeAllProc.running = true
    }
    root.close()
  }

  // --------------------------------------------------------------- rows

  function computeRows() {
    var rows = []
    if (!root.suggestLoading && !root.suggestFailed && root.suggestedName) {
      rows.push({
        kind: "rename-suggested",
        label: 'Rename to "' + root.suggestedName + '"',
        shortcut: "⏎"
      })
    }
    if (root.groups.length > 0) {
      var g0 = root.groups[0]
      rows.push({
        kind: "spinout-0",
        label: 'Spin out "' + g0.name + '" (' + ((g0.indices && g0.indices.length) || 0) + ")",
        shortcut: "S"
      })
    }
    if (root.groups.length > 1) {
      var g1 = root.groups[1]
      rows.push({
        kind: "spinout-1",
        label: 'Spin out "' + g1.name + '" (' + ((g1.indices && g1.indices.length) || 0) + ")",
        shortcut: "⇧S"
      })
    }
    rows.push({ kind: "rename-manual", label: "Rename manually…", shortcut: "R" })
    rows.push({
      kind: "close-all",
      label: "Close all windows (" + (root.windowCount >= 0 ? root.windowCount : "?") + ")",
      shortcut: "⌫"
    })
    return rows
  }

  function activateRow(row) {
    if (!row) return
    if (row.kind === "rename-suggested") root.acceptSuggestedRename()
    else if (row.kind === "spinout-0") root.beginSpinOut(0)
    else if (row.kind === "spinout-1") root.beginSpinOut(1)
    else if (row.kind === "rename-manual") root.beginManualRename()
    else if (row.kind === "close-all") root.closeAllWindows()
  }

  function activateIndex(index) {
    if (index < 0 || index >= root.visibleRows.length) return
    root.activateRow(root.visibleRows[index])
  }

  function select(delta) {
    if (root.visibleRows.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? root.visibleRows.length - 1 : 0
    } else {
      root.selectedIndex = (root.selectedIndex + delta + root.visibleRows.length) % root.visibleRows.length
    }
  }

  function settleCursor() {
    if (root.visibleRows.length === 0) { root.selectedIndex = 0; return }
    if (root.selectedIndex >= root.visibleRows.length) root.selectedIndex = root.visibleRows.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  // -------------------------------------------------------------- theme
  //
  // Bound to the [menu] surface tokens, same as Menu.qml and Clipboard.qml --
  // no hardcoded colours or sizes anywhere below.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(28), Style.font.heading + Style.spacing.controlPaddingY * 2)
  property int statusHeight: (root.suggestLoading || root.suggestFailed) ? Style.space(16) : 0
  property int contentSpacing: Style.spacing.md
  property int rowSpacing: Style.spacing.xs
  property int rowHeight: Math.max(Style.space(38), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int rowsHeight: root.visibleRows.length > 0
    ? (root.visibleRows.length * root.rowHeight + (root.visibleRows.length - 1) * root.rowSpacing)
    : root.rowHeight
  property int workspaceCardWidth: Math.min(Style.space(360), panel.width - Style.gapsOut * 2)
  property int workspaceCardHeight: Math.min(
    contentMargin * 2 + headerHeight + (statusHeight > 0 ? contentSpacing + statusHeight : 0) + contentSpacing + rowsHeight,
    panel.height - Style.gapsOut * 2)
  // Triage surveys every window on every workspace, not one workspace's --
  // it earns most of the screen, capped so it doesn't look absurd on an
  // ultrawide monitor.
  property int triageCardWidth: Math.min(panel.width - Style.gapsOut * 4, Style.space(1200))
  property int triageCardHeight: panel.height - Style.gapsOut * 4
  property int cardWidth: root.triageMode ? root.triageCardWidth : root.workspaceCardWidth
  property int cardHeight: root.triageMode ? root.triageCardHeight : root.workspaceCardHeight

  Process {
    id: clientsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleClientsResult(text)
    }
  }

  Process {
    id: suggestProc
    stdout: SplitParser {
      onRead: function(data) { root.handleSuggestLine(data) }
    }
    onExited: function(exitCode, exitStatus) {
      if (root.suggestLoading) {
        suggestTimeoutTimer.stop()
        root.suggestLoading = false
        root.suggestFailed = true
        root.suggestErrorText = "no response"
      }
    }
  }

  Timer {
    id: suggestTimeoutTimer
    interval: 10000
    repeat: false
    onTriggered: {
      if (root.suggestLoading) {
        root.suggestLoading = false
        root.suggestFailed = true
        root.suggestErrorText = "timed out"
        if (suggestProc.running) suggestProc.running = false
      }
    }
  }

  // Fire-and-forget action processes. The overlay closes the instant one of
  // these starts; none of them need their result observed here.
  Process { id: renameProc }
  Process {
    id: submapProc
    // A bad submap dispatch fails on stderr with exit 0 -- same trap as the
    // window-move dispatches below. Never drop this without logging it.
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim()) console.warn("literate triage submap:", line)
      }
    }
  }
  Process {
    id: spinOutProc
    // A bad dispatch prints to stderr and exits 0, so without this the whole
    // action is a no-op with no trace anywhere.
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim()) console.warn("literate spin-out:", line)
      }
    }
  }
  Process {
    id: closeAllProc
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim()) console.warn("literate close-all:", line)
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "literate-overlay"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.triageMode) {
            triageView.handleKey(event)
            return
          }

          if (root.manualRenameActive) return // the text field owns keys

          if (root.spinOutMode) {
            if (event.key === Qt.Key_Escape) {
              root.cancelSpinOut()
              event.accepted = true
              return
            }
            if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
              root.completeSpinOut(String(event.key - Qt.Key_0))
              event.accepted = true
              return
            }
            event.accepted = true // swallow everything else while picking
            return
          }

          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else root.acceptSuggestedRename()
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace) {
            root.closeAllWindows()
            event.accepted = true
          } else if (event.key === Qt.Key_R && event.modifiers === Qt.NoModifier) {
            root.beginManualRename()
            event.accepted = true
          } else if (event.key === Qt.Key_S && (event.modifiers & Qt.ShiftModifier)) {
            root.beginSpinOut(1)
            event.accepted = true
          } else if (event.key === Qt.Key_S && event.modifiers === Qt.NoModifier) {
            root.beginSpinOut(0)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing
        visible: !root.triageMode

        // ------------------------------------------------------- header

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: headerText
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.manualRenameActive
            text: root.spinOutMode
              ? "Spin onto which workspace?"
              : ("Workspace " + root.workspaceId + (root.windowCount >= 0
                  ? (" · " + root.windowCount + (root.windowCount === 1 ? " window" : " windows"))
                  : ""))
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          TextInput {
            id: manualRenameField
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.manualRenameActive
            text: root.manualRenameText
            onTextChanged: root.manualRenameText = text
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            clip: true
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.cancelManualRename()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.commitManualRename()
                event.accepted = true
              }
            }
          }
        }

        // ------------------------------------------------ status / progress

        Item {
          width: parent.width
          height: root.statusHeight
          visible: root.statusHeight > 0

          // Real indeterminate progress: a filled rect sweeping across the
          // track on a loop, not a static "Thinking…" row.
          Rectangle {
            id: progressTrack
            visible: root.suggestLoading
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(4)
            radius: height / 2
            color: Util.alpha(root.foreground, 0.12)
            clip: true

            Rectangle {
              id: progressFill
              width: parent.width * 0.32
              height: parent.height
              radius: height / 2
              color: root.selectedText

              SequentialAnimation on x {
                running: root.suggestLoading
                loops: Animation.Infinite
                NumberAnimation {
                  from: -progressFill.width
                  to: progressTrack.width
                  duration: 900
                  easing.type: Easing.InOutQuad
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.suggestFailed
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Couldn't name this workspace: " + root.suggestErrorText
            color: Color.urgent
            opacity: 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        // ------------------------------------------------------------ rows

        Column {
          width: parent.width
          spacing: root.rowSpacing

          Repeater {
            model: root.visibleRows

            delegate: Rectangle {
              id: rowDelegate
              required property int index
              required property var modelData

              readonly property bool hasCursor: root.cursorActive && rowDelegate.index === root.selectedIndex

              width: parent.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: rowDelegate.hasCursor ? root.selectedBackground : "transparent"

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: shortcutText.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: rowDelegate.modelData.label
                color: rowDelegate.hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                id: shortcutText
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: rowDelegate.modelData.shortcut
                color: rowDelegate.hasCursor ? root.selectedText : root.foreground
                opacity: 0.52
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: {
                  root.cursorActive = true
                  root.selectedIndex = rowDelegate.index
                }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = rowDelegate.index
                  root.activateIndex(rowDelegate.index)
                }
              }
            }
          }
        }
      }

      // Full-desktop triage view -- see Triage.qml's header comment for why
      // it lives here instead of as its own manifest entry point. Declared
      // after the swallow-click MouseArea above (and after the workspace
      // Column) so its own row MouseAreas sit on top for hit-testing, same
      // as that Column's row delegates already rely on.
      Triage {
        id: triageView
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        visible: root.triageMode
        binPath: root.binPath
        onCloseRequested: root.close()
      }
    }
  }
}
