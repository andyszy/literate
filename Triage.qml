import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// Full-desktop triage view: every window on every real workspace, grouped by
// what the user is DOING (bin/literate-workspace-namer --triage makes one
// model call for the whole grouping). This is a sibling of Overlay.qml's
// per-workspace hold-to-open menu -- same theme tokens, same Process/
// SplitParser idiom -- but it is instantiated BY Overlay.qml rather than
// being its own manifest entry point.
//
// Why not its own "panel" kind: shell.qml's computePanelEntries() builds
// exactly ONE panel/overlay/menu Loader per plugin id, picking a single
// entry point by kind priority panel > overlay > menu. Adding a "panel" kind
// (entryPoints.panel: "Triage.qml") alongside this plugin's existing
// "overlay" kind would make the host pick "panel" and never again resolve
// entryPoints.overlay -- Overlay.qml, and the whole per-workspace hold-menu,
// would silently stop being summonable. So this view is mounted inside
// Overlay.qml's own PanelWindow instead, selected by the summon payload's
// "mode" field ({"mode":"triage"}).
//
// This file is NOT a manifest entry point and is never loaded by the host
// directly -- Overlay.qml instantiates it as `Triage { ... }` (implicit
// same-directory QML import). It still needs to survive tools/sync-upstream
// like Overlay.qml does, so it is in that script's --exclude list too.
Item {
  id: root

  // Set by Overlay.qml, which already resolves its own plugin directory the
  // same way. Not host-injected, so no plain-vs-required concern here.
  property string binPath: ""

  signal closeRequested()

  // ------------------------------------------------------------------ state

  property bool loading: false
  property bool failed: false
  property string errorText: ""
  property var categories: []   // [{name, icon, indices:[...]}]
  property var windows: []      // [{index, address, class, title, workspace}]
  property int cursor: 0        // position within selectableRows, not rows

  function open() {
    root.loading = true
    root.failed = false
    root.errorText = ""
    root.categories = []
    root.windows = []
    root.cursor = 0
    proc.command = [root.binPath, "--triage"]
    proc.running = true
    timeoutTimer.restart()
  }

  function close() {
    timeoutTimer.stop()
    if (proc.running) proc.running = false
  }

  function windowByIndex(idx) {
    for (var i = 0; i < root.windows.length; i++)
      if (root.windows[i].index === idx) return root.windows[i]
    return null
  }

  // ------------------------------------------------------------------- rows
  //
  // Flattened list of header rows (one per category) and window rows,
  // in category order. Keyboard/click selection only ever lands on a
  // window row -- computeSelectableRows() is the map from "row you can
  // land on" back to its position in `rows`.

  readonly property var rows: root.computeRows()

  function computeRows() {
    var out = []
    for (var c = 0; c < root.categories.length; c++) {
      var cat = root.categories[c]
      out.push({ kind: "header", categoryIndex: c, name: cat.name, icon: cat.icon,
                 count: (cat.indices || []).length })
      var indices = cat.indices || []
      for (var i = 0; i < indices.length; i++) {
        var w = root.windowByIndex(indices[i])
        if (w) out.push({ kind: "window", categoryIndex: c, window: w })
      }
    }
    return out
  }

  readonly property var selectableRows: root.computeSelectableRows()

  function computeSelectableRows() {
    var out = []
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].kind === "window") out.push(i)
    return out
  }

  function currentRow() {
    var sel = root.selectableRows
    if (sel.length === 0) return null
    var pos = Math.max(0, Math.min(root.cursor, sel.length - 1))
    return root.rows[sel[pos]]
  }

  function select(delta) {
    var n = root.selectableRows.length
    if (n === 0) return
    root.cursor = (root.cursor + delta + n) % n
    listView.positionViewAtIndex(root.selectableRows[root.cursor], ListView.Contain)
  }

  // flatIndex: a position in `rows` (what a delegate's `index` is), not in
  // selectableRows -- this is what a click hands back.
  function selectRow(flatIndex) {
    var pos = root.selectableRows.indexOf(flatIndex)
    if (pos >= 0) root.cursor = pos
  }

  // ---------------------------------------------------------------- actions

  function focusCurrent() {
    var row = root.currentRow()
    if (!row || !row.window || !row.window.address) return
    // This Hyprland is Lua-configured: `hyprctl dispatch` is shorthand for
    // hl.dispatch(...), so the classic "focuswindow address:0x.." string is
    // a Lua syntax error, not a dispatch. See CLAUDE.md.
    focusProc.command = ["hyprctl", "dispatch",
      'hl.dsp.focus({ window = "address:' + row.window.address + '" })']
    focusProc.running = true
    root.closeRequested()
  }

  function moveCurrentCategory(target) {
    var row = root.currentRow()
    if (!row) return
    var cat = root.categories[row.categoryIndex]
    if (!cat) return
    var addrs = []
    var indices = cat.indices || []
    for (var i = 0; i < indices.length; i++) {
      var w = root.windowByIndex(indices[i])
      if (w && w.address) addrs.push(w.address)
    }
    if (addrs.length > 0) {
      var dispatches = []
      for (var j = 0; j < addrs.length; j++)
        // Same Lua dispatcher form as Overlay.qml's spin-out.
        dispatches.push('dispatch hl.dsp.window.move({ workspace = "' + target
          + '", follow = false, window = "address:' + addrs[j] + '" })')
      moveProc.command = ["hyprctl", "--batch", dispatches.join(" ; ")]
      moveProc.running = true
    }
    root.closeRequested()
  }

  // ------------------------------------------------------------------- keys
  //
  // Called from Overlay.qml's keyCatcher when root.triageMode is true.

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.closeRequested()
      event.accepted = true
    } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
      root.select(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
      root.select(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.focusCurrent()
      event.accepted = true
    } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
      root.moveCurrentCategory(String(event.key - Qt.Key_0))
      event.accepted = true
    }
  }

  // ------------------------------------------------------------------ model

  Process {
    id: proc
    stdout: SplitParser {
      onRead: function(line) {
        if (!root.loading) return // stray output after timeout/close
        var data
        try { data = JSON.parse(line) } catch (e) { return }
        if (!data || typeof data !== "object") return

        timeoutTimer.stop()
        root.loading = false

        if (data.error) {
          root.failed = true
          root.errorText = String(data.error)
          return
        }

        root.categories = Array.isArray(data.categories) ? data.categories : []
        root.windows = Array.isArray(data.windows) ? data.windows : []
        root.cursor = 0
      }
    }
    // A bad dispatch or a daemon crash prints to stderr and would otherwise
    // vanish with no trace -- see CLAUDE.md on the spin-out dispatch that
    // once looked like a silent no-op. Never drop this without logging it.
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim()) console.warn("literate triage:", line)
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (root.loading) {
        timeoutTimer.stop()
        root.loading = false
        root.failed = true
        root.errorText = "no response"
      }
    }
  }

  Timer {
    id: timeoutTimer
    // Triage asks about every window on the desktop in one call, so it gets
    // a longer leash than the ~10s single-workspace --suggest call.
    interval: 20000
    repeat: false
    onTriggered: {
      if (root.loading) {
        root.loading = false
        root.failed = true
        root.errorText = "timed out"
        if (proc.running) proc.running = false
      }
    }
  }

  // Fire-and-forget action processes -- root.closeRequested() fires before
  // either of these settles; neither result needs observing here.
  Process { id: focusProc }
  Process {
    id: moveProc
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim()) console.warn("literate triage move:", line)
      }
    }
  }

  // -------------------------------------------------------------- phosphor

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    url = url.replace(/^file:\/\//, "").replace(/\/+$/, "")
    return url
  }
  property var codepoints: ({})

  FontLoader {
    id: phosphor
    source: Qt.resolvedUrl("fonts/Phosphor.ttf")
  }

  FileView {
    path: root.pluginDir + "/phosphor-codepoints.json"
    printErrors: false
    onLoaded: root.codepoints = JSON.parse(text())
  }

  function glyph(iconName) {
    var cp = root.codepoints[iconName]
    return cp ? String.fromCharCode(parseInt(cp, 16)) : ""
  }

  // ------------------------------------------------------------------ theme

  property color foreground: Color.menu.text
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property string fontFamily: Style.font.menuFamily
  property int headerHeight: Math.max(Style.space(28), Style.font.heading + Style.spacing.controlPaddingY * 2)
  property int catHeaderHeight: Style.space(30)
  property int rowHeight: Math.max(Style.space(34), Style.font.body + Style.spacing.rowPaddingX * 2)

  // ----------------------------------------------------------------- layout

  Item {
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: root.headerHeight

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "Triage" + (root.windows.length > 0
        ? (" · " + root.windows.length + (root.windows.length === 1 ? " window" : " windows")
           + " · " + root.categories.length + (root.categories.length === 1 ? " category" : " categories"))
        : "")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      elide: Text.ElideRight
    }
  }

  Item {
    id: status
    anchors.top: header.bottom
    anchors.topMargin: height > 0 ? Style.spacing.md : 0
    anchors.left: parent.left
    anchors.right: parent.right
    height: (root.loading || root.failed) ? Style.space(16) : 0
    visible: height > 0

    // Real indeterminate progress: a filled rect sweeping the track on a
    // loop, matching Overlay.qml's --suggest progress bar.
    Rectangle {
      id: progressTrack
      visible: root.loading
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(4)
      radius: height / 2
      color: Util.alpha(root.foreground, 0.12)
      clip: true

      Rectangle {
        id: progressFill
        width: parent.width * 0.24
        height: parent.height
        radius: height / 2
        color: root.selectedText

        SequentialAnimation on x {
          running: root.loading
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
      visible: root.failed
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "Couldn't triage: " + root.errorText
      color: Color.urgent
      opacity: 0.85
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  ListView {
    id: listView
    anchors.top: status.bottom
    anchors.topMargin: Style.spacing.md
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    clip: true
    spacing: 0
    model: root.rows

    delegate: Item {
      id: rowRoot
      required property int index
      required property var modelData

      readonly property bool isHeader: rowRoot.modelData.kind === "header"
      readonly property bool hasCursor: !rowRoot.isHeader
        && root.selectableRows[root.cursor] === rowRoot.index

      width: listView.width
      height: rowRoot.isHeader ? root.catHeaderHeight : root.rowHeight

      Rectangle {
        anchors.fill: parent
        visible: !rowRoot.isHeader
        radius: Style.cornerRadius
        color: rowRoot.hasCursor ? root.selectedBackground : "transparent"
      }

      Row {
        visible: rowRoot.isHeader
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Text {
          visible: rowRoot.isHeader && root.glyph(rowRoot.modelData.icon) !== ""
          text: rowRoot.isHeader ? root.glyph(rowRoot.modelData.icon) : ""
          color: root.foreground
          font.family: phosphor.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          textFormat: Text.PlainText
          text: rowRoot.isHeader ? (rowRoot.modelData.name + " (" + rowRoot.modelData.count + ")") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.bold: true
          font.pixelSize: Style.font.body
        }
      }

      Text {
        visible: !rowRoot.isHeader
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(24)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: rowRoot.isHeader ? "" : ("[" + rowRoot.modelData.window.workspace + "] "
              + rowRoot.modelData.window.class
              + (rowRoot.modelData.window.title ? " — " + rowRoot.modelData.window.title : ""))
        color: rowRoot.hasCursor ? root.selectedText : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      MouseArea {
        anchors.fill: parent
        visible: !rowRoot.isHeader
        enabled: !rowRoot.isHeader
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.selectRow(rowRoot.index)
        onClicked: {
          root.selectRow(rowRoot.index)
          root.focusCurrent()
        }
      }
    }
  }
}
