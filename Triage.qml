import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui
import "Omnibox.js" as Omnibox

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

  // There is a real difference between "waiting with nothing to show" and
  // "waiting on top of a grouping already on screen". The first earns a
  // progress bar; the second must not get one -- a spinner over good-enough
  // data is worse than the slightly stale data underneath it.
  readonly property bool hasContent: root.categories.length > 0
  readonly property bool blocking: root.loading && !root.hasContent
  readonly property bool refreshing: root.loading && root.hasContent

  // Incremental search: plain substring, case-insensitive, matched against
  // category name / window class / window title independently. See
  // computeRows() below for how a query reshapes the grouped list.
  property string query: ""

  // False while the keyboard is driving. Set true again by real pointer motion,
  // so a stationary mouse cannot hijack the cursor as rows reflow underneath it.
  property bool pointerLive: false

  function setQuery(text) {
    if (root.query === text) return
    root.query = text
    root.pointerLive = false
    root.cursor = 0 // first visible row, every time the query changes
  }

  function matchesQuery(haystack) {
    return String(haystack || "").toLowerCase().indexOf(root.query.toLowerCase()) >= 0
  }

  function open() {
    root.failed = false
    root.errorText = ""
    root.cursor = 0
    root.query = ""
    // Paint the daemon's precomputed grouping in this frame rather than
    // waiting on a process to tell us the same thing. If it is still current
    // --triage confirms it in ~45ms and nothing moves; if the desktop has
    // drifted, the fresh answer lands a second later and replaces it. Either
    // way the view is useful immediately, which is the whole point.
    if (root.cache) {
      root.categories = root.cache.categories
      root.windows = root.cache.windows
    } else {
      root.categories = []
      root.windows = []
    }
    root.loading = true
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
  // Flattened list of rows: open-window headers/windows, plus, once there is
  // a query, a "tier" label row and up to root.tierLimit conversation/
  // history rows per non-empty source tier. Keyboard/click selection can
  // land on any kind except "tier" -- computeSelectableRows() is the map
  // from "row you can land on" back to its position in `rows`.

  readonly property var rows: root.computeRows()

  // With no query this is exactly the old flat list. With one, a category
  // whose OWN name matches keeps every window (the match already explains
  // the whole group); otherwise only the windows that individually match
  // survive, and a category left with none is dropped rather than shown
  // with an empty body. That drop applies whether or not there is a query --
  // a header for a category with zero visible windows is never emitted, so
  // it can never be landed on (see computeSelectableRows()).
  //
  // With a query, two more tiers follow the open-window one: CONVERSATIONS
  // and HISTORY, sourced from the omnibox index (see the FileView below).
  // Both are capped (root.tierLimit) so open windows never get pushed off
  // screen by a big index; a "tier" row is a plain label, never selectable
  // (see computeSelectableRows()) -- only real result rows land the cursor.
  function computeOpenRows() {
    var out = []
    var hasQuery = root.query.length > 0
    for (var c = 0; c < root.categories.length; c++) {
      var cat = root.categories[c]
      var indices = cat.indices || []
      var visible = indices
      if (hasQuery && !root.matchesQuery(cat.name)) {
        visible = []
        for (var i = 0; i < indices.length; i++) {
          var w = root.windowByIndex(indices[i])
          if (w && (root.matchesQuery(w.app) || root.matchesQuery(w.subject)
                    || root.matchesQuery(w.host) || root.matchesQuery(w.context)
                    || root.matchesQuery(w.class) || root.matchesQuery(w.title)))
            visible.push(indices[i])
        }
      }
      if (visible.length === 0) continue

      out.push({ kind: "header", categoryIndex: c, name: cat.name, icon: cat.icon,
                 count: visible.length })
      for (var j = 0; j < visible.length; j++) {
        var win = root.windowByIndex(visible[j])
        if (win) out.push({ kind: "window", categoryIndex: c, window: win })
      }
    }
    return out
  }

  readonly property int tierLimit: 5

  function computeRows() {
    var openRows = root.computeOpenRows()
    if (root.query.length === 0) return openRows // exactly today's triage

    var convMatches = root.matchConversations(root.query)
    var histMatches = root.matchHistory(root.query)
    var out = []

    // Only bother labelling the OPEN tier when there is something else on
    // screen to distinguish it from -- with no conversation/history matches
    // this degrades to exactly the pre-omnibox search view.
    if (openRows.length > 0 && (convMatches.length > 0 || histMatches.length > 0))
      out.push({ kind: "tier", categoryIndex: -1, label: "OPEN" })
    out = out.concat(openRows)

    if (convMatches.length > 0) {
      var convShown = convMatches.slice(0, root.tierLimit)
      out.push({ kind: "tier", categoryIndex: -1, label: "CONVERSATIONS",
                 shown: convShown.length, total: convMatches.length })
      for (var i = 0; i < convShown.length; i++)
        out.push({ kind: "conversation", categoryIndex: -1, conversation: convShown[i] })
    }

    if (histMatches.length > 0) {
      var histShown = histMatches.slice(0, root.tierLimit)
      out.push({ kind: "tier", categoryIndex: -1, label: "HISTORY",
                 shown: histShown.length, total: histMatches.length })
      for (var h = 0; h < histShown.length; h++)
        out.push({ kind: "history", categoryIndex: -1, history: histShown[h] })
    }

    return out
  }

  // ------------------------------------------------------------- omnibox
  //
  // The matching, ranking and title-normalisation rules themselves live in
  // Omnibox.js, shared verbatim with Shelf.qml -- two views over the same
  // index must not rank the same query differently. These wrappers only
  // supply this view's parsed index.

  function textRank(text, query) { return Omnibox.textRank(text, query) }

  function matchConversations(query) {
    return Omnibox.matchConversations(query, root.omniboxIndex)
  }

  function matchHistory(query) {
    return Omnibox.matchHistory(query, root.omniboxIndex)
  }

  function stripStatusGlyphs(title) { return Omnibox.stripStatusGlyphs(title) }

  // Claude Code sets an org.omarchy.claude terminal's window title to the
  // conversation's ai-title, so a live window whose (glyph-stripped) title
  // matches the index entry IS that conversation, already open -- jump to
  // it instead of spawning a duplicate `claude --resume`. Searches
  // root.windows (the full filtered window inventory triage already has),
  // not just what the current query happens to show.
  function findOpenClaudeWindow(title) {
    var target = String(title || "")
    if (!target) return null
    for (var i = 0; i < root.windows.length; i++) {
      var w = root.windows[i]
      if (!w || !w.class) continue
      if (String(w.class).toLowerCase() !== "org.omarchy.claude") continue
      if (root.stripStatusGlyphs(w.title) === target) return w
    }
    return null
  }

  // Shell-command + Lua-string escaping for hl.dsp.exec_cmd(), which itself
  // runs the string through a shell (see CLAUDE.md/bindings.lua precedent:
  // "wpctl set-volume ... @DEFAULT_AUDIO_SINK@" and similar need one).
  // Util.shellQuote single-quotes for that shell layer; escaping backslash
  // then double-quote afterwards is what then makes the whole thing safe as
  // one Lua-string argument to hyprctl dispatch (order matters: escaping
  // backslash first means the backslashes shellQuote may have just inserted
  // get escaped too, instead of being re-escaped a second time).
  function execCmdDispatch(shellCommand) {
    var lua = shellCommand.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
    return 'hl.dsp.exec_cmd("' + lua + '")'
  }

  function launchClaudeResume(sessionId, project) {
    var cmd = "setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.claude --dir="
      + Util.shellQuote(project) + " -e claude --resume " + Util.shellQuote(sessionId)
    launchProc.command = ["hyprctl", "dispatch", root.execCmdDispatch(cmd)]
    launchProc.running = true
  }

  function openUrlInBrowser(url) {
    var cmd = "omarchy launch browser " + Util.shellQuote(url)
    launchProc.command = ["hyprctl", "dispatch", root.execCmdDispatch(cmd)]
    launchProc.running = true
  }

  function openConversation(conv) {
    if (!conv) return
    var existing = root.findOpenClaudeWindow(conv.title)
    if (existing && existing.address) {
      focusProc.command = ["hyprctl", "dispatch",
        'hl.dsp.focus({ window = "address:' + existing.address + '" })']
      focusProc.running = true
      return
    }
    root.launchClaudeResume(conv.id, conv.project)
  }

  function openHistoryEntry(hist) {
    if (!hist || !hist.url) return
    root.openUrlInBrowser(hist.url)
  }

  readonly property int visibleWindowCount: {
    var n = 0
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].kind === "window") n++
    return n
  }
  readonly property int visibleCategoryCount: {
    var n = 0
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].kind === "header") n++
    return n
  }

  // Every row lands on something selectable, except "tier" labels -- a
  // header is a stop in its own right (arrow nav walks header -> its
  // windows -> next header -> ...), and computeRows() already drops any
  // header left with zero visible rows. Kept as its own function/array
  // (rather than indexing `rows` directly) so currentRow()/select()/
  // selectRow() below don't change shape.
  readonly property var selectableRows: root.computeSelectableRows()

  function computeSelectableRows() {
    var out = []
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].kind !== "tier") out.push(i)
    return out
  }

  function currentRow() {
    var sel = root.selectableRows
    if (sel.length === 0) return null
    var pos = Math.max(0, Math.min(root.cursor, sel.length - 1))
    return root.rows[sel[pos]]
  }

  // Which category the cursor currently sits in (header or window row alike)
  // -- drives the whole-category scope tint below, so it's obvious at a
  // glance which windows a header-level move would take.
  readonly property int currentCategoryIndex: {
    var row = root.currentRow()
    return row ? row.categoryIndex : -1
  }

  // What SUPER+SHIFT+<digit> and Enter will do to the current selection --
  // shown in the header so the scope of a header-level move is legible
  // before it happens, not after. Moving a workspace is meaningless for a
  // conversation or history row -- those get an Enter-only hint, so
  // SUPER+SHIFT+<n> reads as (and is, see moveCurrent()) a no-op rather
  // than something surprising.
  readonly property string scopeHint: {
    var row = root.currentRow()
    if (!row) return ""
    if (row.kind === "header")
      return "⇧⌘1-9 move all " + row.count + (row.count === 1 ? " window" : " windows")
    if (row.kind === "window")
      return "⇧⌘1-9 move this window"
    if (row.kind === "conversation")
      return "⏎ resume conversation"
    if (row.kind === "history")
      return "⏎ open in browser"
    return ""
  }

  function select(delta) {
    var n = root.selectableRows.length
    if (n === 0) return
    // Arrowing scrolls the list, which slides rows under a stationary pointer;
    // park the mouse again so its hover cannot fight the keyboard.
    root.pointerLive = false
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

  // On a window row, focus that window. On a header, focus the category's
  // first (visible) window -- computeRows() guarantees the row immediately
  // after a header is a window of that same category, since a header with
  // no visible windows is never emitted.
  function focusCurrent() {
    var row = root.currentRow()
    if (!row) return

    if (row.kind === "conversation") {
      root.openConversation(row.conversation)
      root.closeRequested()
      return
    }
    if (row.kind === "history") {
      root.openHistoryEntry(row.history)
      root.closeRequested()
      return
    }

    var win = row.window
    if (row.kind === "header") {
      var flat = root.selectableRows[root.cursor]
      var next = root.rows[flat + 1]
      win = next ? next.window : null
    }
    if (!win || !win.address) return
    // This Hyprland is Lua-configured: `hyprctl dispatch` is shorthand for
    // hl.dispatch(...), so the classic "focuswindow address:0x.." string is
    // a Lua syntax error, not a dispatch. See CLAUDE.md.
    focusProc.command = ["hyprctl", "dispatch",
      'hl.dsp.focus({ window = "address:' + win.address + '" })']
    focusProc.running = true
    root.closeRequested()
  }

  // Invoked from Overlay.qml's triageMove(arg) IPC entry point, driven by
  // the SUPER+SHIFT+<n> binds in the "literate-triage" Hyprland submap (see
  // bindings.lua) -- not from handleKey() any more, since plain digits now
  // feed the search box.
  //
  // Scope follows the cursor: a window row moves just that window; a header
  // moves every window in the category (its full index list, not just what
  // the current search happens to show -- unchanged from this function's
  // original category-only behaviour).
  function moveCurrent(target) {
    var row = root.currentRow()
    if (!row) return
    // Only open windows/categories have a workspace to move to -- a
    // conversation or history row does nothing here (see scopeHint above).
    if (row.kind !== "header" && row.kind !== "window") return
    var addrs = []
    if (row.kind === "header") {
      var cat = root.categories[row.categoryIndex]
      var indices = (cat && cat.indices) || []
      for (var i = 0; i < indices.length; i++) {
        var w = root.windowByIndex(indices[i])
        if (w && w.address) addrs.push(w.address)
      }
    } else if (row.window && row.window.address) {
      addrs.push(row.window.address)
    }
    if (addrs.length > 0) {
      var dispatches = []
      for (var j = 0; j < addrs.length; j++)
        // follow = true, not false: the user asked these windows to go to
        // `target` because they intend to go there themselves. Same Lua
        // dispatcher form as Overlay.qml's spin-out (which stays silent --
        // a different feature, not in scope here).
        dispatches.push('dispatch hl.dsp.window.move({ workspace = "' + target
          + '", follow = true, window = "address:' + addrs[j] + '" })')
      moveProc.command = ["hyprctl", "--batch", dispatches.join(" ; ")]
      moveProc.running = true
    }
    root.closeRequested()
  }

  // ------------------------------------------------------------------- keys
  //
  // Called from Overlay.qml's keyCatcher when root.triageMode is true.
  //
  // Digits and letters all feed the search box now (moving a category to a
  // workspace moved to SUPER+SHIFT+<n>, shadowed in via the "literate-triage"
  // Hyprland submap -- see triageMove() below and bindings.lua), so the only
  // keys left for navigation are the plain arrows: j/k would otherwise be
  // untypeable in a query. Escape mirrors Menu.qml:1132 -- clear the filter
  // first, only close once it is already empty.
  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (root.query) root.setQuery("")
      else root.closeRequested()
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      root.select(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      root.select(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.focusCurrent()
      event.accepted = true
    } else if (Util.editsFilter(event, root.query)) {
      root.setQuery(Util.editedFilter(event, root.query))
      event.accepted = true
    } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32
        && event.text.charCodeAt(0) !== 127
        && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
      root.setQuery(root.query + event.text)
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
          // With a cached grouping already on screen this is a failed
          // refresh, not a failed triage: say so quietly and leave the rows
          // alone rather than replacing something useful with an error.
          root.failed = true
          root.errorText = String(data.error)
          return
        }

        var cats = Array.isArray(data.categories) ? data.categories : []
        var wins = Array.isArray(data.windows) ? data.windows : []
        // A cache hit hands back exactly what open() already painted.
        // Reassigning would be invisible; resetting the cursor and scroll
        // position under someone who has started arrowing around would not.
        if (JSON.stringify(cats) === JSON.stringify(root.categories)
            && JSON.stringify(wins) === JSON.stringify(root.windows))
          return

        root.categories = cats
        root.windows = wins
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

  // ------------------------------------------------------------ triage cache
  //
  // The daemon groups the desktop after every settled window-set change and
  // writes the answer here (maybe_precompute_triage() in
  // bin/literate-workspace-namer), atomically, exactly as it does
  // workspaces.json. Overlay.qml is keepLoaded, so this FileView has parsed
  // the file long before the triage key is ever pressed -- which is what lets
  // open() draw a full grouping in its first frame.
  //
  // This is only what we draw while the answer is in flight. `--triage` hashes
  // the live window set and stays the authority on what is actually open.
  property var cache: null

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/literate/triage.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var d = null
      try { d = JSON.parse(text()) } catch (e) { d = null }
      root.cache = (d && Array.isArray(d.categories) && d.categories.length > 0
                    && Array.isArray(d.windows)) ? d : null
    }
    onLoadFailed: root.cache = null
  }

  // --------------------------------------------------------- omnibox index
  //
  // Written by bin/literate-workspace-namer's Claude-conversation/Chrome-
  // history indexer (owned by another agent) to this exact contract:
  // {"updatedAt":.., "conversations":[{id,title,project,mtime,messages}],
  //  "history":[{title,url,domain,visits,lastVisit}]}. Same FileView idiom
  // as the triage cache above, so it too is already parsed before the key
  // is ever pressed. The file may not exist yet, or may be malformed --
  // either degrades to root.omniboxIndex === null, which matchConversations/
  // matchHistory already treat as "no results", i.e. exactly today's
  // open-windows-only search.
  property var omniboxIndex: null

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/literate/omnibox-index.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var d = null
      try { d = JSON.parse(text()) } catch (e) { d = null }
      root.omniboxIndex = (d && typeof d === "object"
        && (d.conversations === undefined || Array.isArray(d.conversations))
        && (d.history === undefined || Array.isArray(d.history))) ? d : null
    }
    onLoadFailed: root.omniboxIndex = null
  }

  // Fire-and-forget action processes -- root.closeRequested() fires before
  // any of these settles; none of their results need observing here.
  Process { id: focusProc }
  Process {
    id: launchProc
    // A bad exec_cmd dispatch fails on stderr with exit 0 -- same trap as
    // the focus/move dispatches elsewhere in this file. Never drop this
    // without logging it.
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim()) console.warn("literate triage launch:", line)
      }
    }
  }
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
      // The " · refreshing…" tail is the whole of the drift hint: rows that
      // are already readable do not deserve a bar drawn over the top of them.
      // The scope hint trails everything else -- it's the least essential
      // part of the line, so it's the first thing elide sacrifices.
      text: (root.query.length > 0
        ? ("Search: " + root.query + "▮"
           + " · " + root.visibleWindowCount + (root.visibleWindowCount === 1 ? " window" : " windows")
           + " · " + root.visibleCategoryCount + (root.visibleCategoryCount === 1 ? " category" : " categories"))
        : ("Triage" + (root.windows.length > 0
            ? (" · " + root.windows.length + (root.windows.length === 1 ? " window" : " windows")
               + " · " + root.categories.length + (root.categories.length === 1 ? " category" : " categories"))
            : ""))) + (root.refreshing ? " · refreshing…" : "")
        + (root.scopeHint ? " · " + root.scopeHint : "")
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
    height: (root.blocking || root.failed) ? Style.space(16) : 0
    visible: height > 0

    // Real indeterminate progress: a filled rect sweeping the track on a
    // loop, matching Overlay.qml's --suggest progress bar.
    Rectangle {
      id: progressTrack
      visible: root.blocking
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
          running: root.blocking
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
      // Cached rows are still on screen when a refresh fails, so name what
      // actually went wrong rather than implying the view is empty.
      text: (root.hasContent ? "Couldn't refresh: " : "Couldn't triage: ") + root.errorText
      color: Color.urgent
      opacity: 0.85
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  Text {
    id: noMatches
    textFormat: Text.PlainText
    visible: root.query.length > 0 && root.rows.length === 0 && !root.blocking && !root.failed
    anchors.top: status.bottom
    anchors.topMargin: Style.spacing.md
    anchors.left: parent.left
    anchors.right: parent.right
    text: "No matches for “" + root.query + "”"
    color: root.foreground
    opacity: 0.7
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
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
      readonly property bool isWindow: rowRoot.modelData.kind === "window"
      readonly property bool isTier: rowRoot.modelData.kind === "tier"
      readonly property bool isConversation: rowRoot.modelData.kind === "conversation"
      readonly property bool isHistory: rowRoot.modelData.kind === "history"
      readonly property bool hasIconRow: rowRoot.isHeader || rowRoot.isConversation || rowRoot.isHistory
      readonly property bool hasCursor: !rowRoot.isTier && root.selectableRows[root.cursor] === rowRoot.index
      // Whole-category scope cue: every row (header or window) belonging to
      // the category the cursor is currently in, so it's obvious at a glance
      // which windows a header-level move would take. Drawn under, and kept
      // subordinate to, the cursor's own highlight below -- the cursor row
      // must still read as the primary selection. categoryIndex is -1 for
      // every non-open-tier row (tier labels, conversations, history), so
      // the >= 0 guard keeps those from all lighting up together whenever
      // the cursor happens to be sitting on one of them.
      readonly property bool inScopeCategory: rowRoot.modelData.categoryIndex >= 0
        && rowRoot.modelData.categoryIndex === root.currentCategoryIndex

      width: listView.width
      height: rowRoot.isTier ? Style.space(22) : (rowRoot.isHeader ? root.catHeaderHeight : root.rowHeight)

      Rectangle {
        anchors.fill: parent
        visible: rowRoot.inScopeCategory && !rowRoot.hasCursor
        radius: Style.cornerRadius
        color: Util.alpha(root.foreground, 0.045)
      }

      Rectangle {
        anchors.fill: parent
        visible: rowRoot.hasCursor
        radius: Style.cornerRadius
        color: root.selectedBackground
      }

      // Tier label ("OPEN"/"CONVERSATIONS"/"HISTORY") -- a heading, never a
      // selectable row: no cursor rect, no MouseArea below picks it up.
      Text {
        visible: rowRoot.isTier
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: rowRoot.isTier ? (rowRoot.modelData.label
          + (rowRoot.modelData.total > rowRoot.modelData.shown
             ? (" (showing " + rowRoot.modelData.shown + " of " + rowRoot.modelData.total + ")") : "")) : ""
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.bold: true
        font.pixelSize: Style.font.bodySmall
        font.capitalization: Font.AllUppercase
      }

      Row {
        visible: rowRoot.hasIconRow
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Text {
          readonly property string iconName: rowRoot.isHeader ? rowRoot.modelData.icon
            : (rowRoot.isConversation ? "chat-circle" : (rowRoot.isHistory ? "globe" : ""))
          visible: rowRoot.hasIconRow && root.glyph(iconName) !== ""
          text: root.glyph(iconName)
          color: rowRoot.hasCursor ? root.selectedText : root.foreground
          font.family: phosphor.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width - Style.space(20)
          text: rowRoot.isHeader ? (rowRoot.modelData.name + " (" + rowRoot.modelData.count + ")")
            : rowRoot.isConversation ? (rowRoot.modelData.conversation.title
                + (rowRoot.modelData.conversation.messages
                   ? "  ·  " + rowRoot.modelData.conversation.messages + " msgs" : ""))
            : rowRoot.isHistory ? (rowRoot.modelData.history.title
                + (rowRoot.modelData.history.domain ? "  —  " + rowRoot.modelData.history.domain : ""))
            : ""
          color: rowRoot.hasCursor ? root.selectedText : root.foreground
          font.family: root.fontFamily
          font.bold: rowRoot.isHeader
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
      }

      Text {
        visible: rowRoot.isWindow
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(24)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        // The daemon resolves `app` (Gmail, Claude Code) and `subject` (the
        // title with the app/account tail subtracted). Fall back to class and
        // title only for a record written before that landed.
        text: rowRoot.isWindow ? ("[" + rowRoot.modelData.window.workspace + "] "
              + (rowRoot.modelData.window.app || rowRoot.modelData.window.class)
              + ((rowRoot.modelData.window.subject || rowRoot.modelData.window.title)
                 ? " — " + (rowRoot.modelData.window.subject || rowRoot.modelData.window.title) : "")
              + (rowRoot.modelData.window.context ? "  ·  " + rowRoot.modelData.window.context : "")) : ""
        color: rowRoot.hasCursor ? root.selectedText : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      MouseArea {
        anchors.fill: parent
        visible: !rowRoot.isTier
        enabled: !rowRoot.isTier
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // onEntered fires when the pointer moves onto a row -- and also when a
        // row slides under a pointer that never moved, which is what happens on
        // every keystroke as the results refilter. Honouring that made the
        // selection appear to jump around at random while typing. Only let the
        // mouse take the selection once it has actually moved since the last key.
        onEntered: if (root.pointerLive) root.selectRow(rowRoot.index)
        onPositionChanged: {
          if (root.pointerLive) return
          root.pointerLive = true
          root.selectRow(rowRoot.index)
        }
        onClicked: {
          root.pointerLive = true
          root.selectRow(rowRoot.index)
          root.focusCurrent()
        }
      }
    }
  }
}
