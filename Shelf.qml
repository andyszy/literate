import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Omnibox.js" as Omnibox

// The bar expands into the surface: the menu bar grows downward into a
// full-width black shelf carrying a live board for every workspace, with an
// omnibox panel beneath it. Summoned with
// `omarchy-shell shell summon literate '{"mode":"shelf"}'`.
//
// Like Triage.qml this is NOT a manifest entry point -- shell.qml builds one
// panel/overlay/menu Loader per plugin id, so a second entry point would cost
// us Overlay.qml entirely (see Triage.qml's header for the full reasoning).
// Overlay.qml instantiates it as `Shelf { ... }` and selects it from the
// summon payload's "mode" field. It is fork-owned, so it must stay in
// tools/sync-upstream's --exclude list or the next re-vendor deletes it.
//
// Three things about this surface are not negotiable and explain most of the
// code below:
//
// 1. It COVERS the bar rather than hanging below it. The bar already draws
//    the workspace list -- number, Phosphor icon, model-given name -- so a
//    shelf that drew its own row underneath would show the same list twice,
//    stacked. Instead this window starts at y=0 on the same black
//    (Color.bar.background), and every workspace label starts life at the x
//    it occupies in the bar and animates out to its board header. The bar
//    appears to grow; nothing appears from nowhere, and the labels are never
//    on screen twice. The cost is that the bar's other modules (the menu
//    button, clock, tray) are hidden for as long as the shelf is up.
//
// 2. A board carries the SCREEN's aspect ratio, measured at runtime off the
//    monitor and the compositor's reserved area. A workspace is a miniature
//    of the screen; a board at some invented ratio does not read as one.
//
// 3. exclusionMode is Ignore. The shelf OVERLAYS the desktop; an exclusion
//    zone would shove every tiled window down the instant it is summoned and
//    back up when it closes.
Item {
  id: root

  // Set by Overlay.qml, same as Triage.qml. Not host-injected, so no
  // plain-vs-required concern here.
  property string binPath: ""

  signal closeRequested()

  // ---------------------------------------------------------------- state

  property bool opened: false
  // The window outlives `opened` by one animation: closing has to collapse
  // back into the bar, which it cannot do after the surface is gone.
  property bool windowVisible: false
  // Two separate dials rather than one. `extent` is how far the black surface
  // has grown below the bar; `reveal` is how present the content on it is.
  // They are separate because the ORDER matters on the way out: the content
  // has to be gone before the surface collapses, so the frame where the real
  // bar takes over again is a frame where nothing of ours is drawn. A single
  // progress value cannot express that.
  //
  // This used to lerp every tile from a reconstruction of where the bar draws
  // its own labels out to the expanded layout. That can only be seamless if
  // the reconstruction matches the vendored bar's font metrics exactly, and it
  // does not -- the mismatch showed as a snap at the handoff. A cross-fade
  // suggests the same motion and is honest about being a fade.
  property real extent: 0
  property real reveal: 0
  // A few pixels of shared rise on open, fall on close: enough to give the
  // fade a direction, not enough to be a morph.
  readonly property real contentOffset: Style.space(8) * (1 - root.reveal)

  // The selected board's REAL Hyprland workspace id, or 0 for the Jump-to
  // tile. Deliberately not a position in wsTiles: an ordinal and a workspace
  // id agree only while the boards happen to be a contiguous 1..N, and the
  // one place that difference would surface is the dispatch that switches
  // workspace -- i.e. it would send you somewhere else entirely, silently.
  // Nothing below indexes wsTiles by this; tileFor() looks it up.
  property int selectedWorkspace: 0
  // Which part of the surface Enter belongs to. Without this there is no
  // answer to "the pointer is over board 3 and the panel's first row is a
  // window on board 1 -- what does Enter do?", and the answer it fell into
  // was the wrong one. "action" is the pinned row carrying the typed query
  // itself (see queryAction); it is its own region because it is one row that
  // never scrolls, not a place in the result list.
  property string focusRegion: "shelf"   // "shelf" | "action" | "panel"
  property string query: ""
  property int cursor: 0
  property bool pointerLive: false

  function tileFor(wsId) {
    for (var i = 0; i < root.wsTiles.length; i++)
      if (root.wsTiles[i].id === wsId) return root.wsTiles[i]
    return null
  }

  readonly property int workspaceCount: 9

  // An initial query may come in on the summon payload
  // ({"mode":"shelf","query":"omarchy"}): summoning straight into an answer is
  // the same view, and it is the only way to exercise the query state without
  // a keyboard.
  function open(initialQuery, armedProfile) {
    root.armProfile(armedProfile)
    root.selectedWorkspace = 0
    root.query = String(initialQuery || "")
    var initial = Omnibox.urlOrSearch(root.query, root.searchEngine)
    root.focusRegion = root.query.length === 0 ? "shelf"
      : (initial && initial.kind === "open") ? "action" : "panel"
    root.cursor = 0
    root.pointerLive = false
    root.rebuild()
    root.opened = true
    root.windowVisible = true
    root.priming = true
    primeTimer.restart()
    collapseAnim.stop()
    expandAnim.restart()
    // Cheap, and it means rebinding Terminal takes effect on the next summon
    // rather than the next shell restart.
    bindsProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened && !root.windowVisible) return
    root.opened = false
    expandAnim.stop()
    collapseAnim.restart()
  }

  ParallelAnimation {
    id: expandAnim
    NumberAnimation {
      target: root; property: "extent"; to: 1
      duration: 150; easing.type: Easing.OutCubic
    }
    NumberAnimation {
      target: root; property: "reveal"; to: 1
      duration: 150; easing.type: Easing.OutCubic
    }
  }

  // Strictly sequential, and this is the whole trick: the content is at zero
  // before the surface starts shrinking, and the surface is still opaque black
  // the whole way down, so the moment the real bar reappears there is nothing
  // of ours left to jump.
  SequentialAnimation {
    id: collapseAnim
    NumberAnimation {
      target: root; property: "reveal"; to: 0
      duration: 90; easing.type: Easing.OutQuad
    }
    NumberAnimation {
      target: root; property: "extent"; to: 0
      duration: 110; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        root.windowVisible = false
        if (root.pendingCommand) flushTimer.restart()
      }
    }
  }

  // Anything that moves the compositor's FOCUS has to wait for this surface to
  // be gone. The shelf holds exclusive keyboard focus, and when that layer
  // unmaps Hyprland restores focus to the window that had it before -- which
  // silently undoes the switch. Verified: dispatching "go to workspace 5"
  // while the shelf is open lands on 5 and bounces straight back to 3 the
  // moment it closes. Launching something new is not affected (the new window
  // takes focus on its own) and stays inline.
  property var pendingCommand: null

  function runAfterClose(command) {
    root.pendingCommand = command
    root.closeRequested()
  }

  Timer {
    id: flushTimer
    interval: 40
    repeat: false
    onTriggered: {
      if (!root.pendingCommand) return
      actionProc.command = root.pendingCommand
      root.pendingCommand = null
      actionProc.running = true
    }
  }

  Process {
    id: actionProc
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim()) console.warn("literate shelf action:", line)
      }
    }
  }

  function lerp(a, b, p) { return a + (b - a) * p }

  // Capture streams only for the moment it takes to fill the boards, then
  // stops. See the ScreencopyView below.
  property bool priming: false

  Timer {
    id: primeTimer
    interval: 600
    repeat: false
    onTriggered: root.priming = false
  }

  function setQuery(text) {
    if (root.query === text) return
    root.query = text
    root.pointerLive = false
    root.cursor = 0
    // A query is a question about the whole desktop, so it answers from the
    // Jump-to tile -- and Enter answers it, so focus goes to the results. The
    // shelf still shows WHERE the matches are (dimming and badging below);
    // Tab from here narrows to one workspace deliberately.
    if (text.length > 0) {
      root.selectedWorkspace = 0
      // A query that is already a location is not a search for anything: the
      // pinned row IS the answer, so Enter goes straight there without an
      // arrow key. Anything else lands on the best result, exactly as an
      // address bar highlights its top suggestion and leaves "search for what
      // I typed" one keystroke away.
      var action = Omnibox.urlOrSearch(text, root.searchEngine)
      root.focusRegion = (action && action.kind === "open") ? "action" : "panel"
    } else {
      root.focusRegion = "shelf"
    }
  }

  // The Tab order: the Jump-to tile, then every board in the order they are
  // drawn, by id.
  function tileOrder() {
    var out = [0]
    for (var i = 0; i < root.wsTiles.length; i++) out.push(root.wsTiles[i].id)
    return out
  }

  function selectTile(delta) {
    var order = root.tileOrder()
    var at = order.indexOf(root.selectedWorkspace)
    if (at < 0) at = 0
    root.selectedWorkspace = order[(at + delta + order.length) % order.length]
    root.focusRegion = "shelf"
    root.cursor = 0
    root.pointerLive = false
  }

  // Hovering a board selects it, exactly as hovering a row selects the row --
  // and under the same guard, because a board sliding under a stationary
  // pointer (the shelf animating open, a workspace gaining its first window)
  // must not steal the selection from the keyboard.
  function hoverTile(wsId) {
    if (!root.pointerLive) return
    root.takeTile(wsId)
  }

  function pickTile(wsId) {
    root.takeTile(wsId)
  }

  // Qt delivers positionChanged to a MouseArea whenever the pointer moves
  // RELATIVE to it -- which includes an item sliding under a pointer that
  // never moved. That is how a re-created panel row stole focus back the
  // instant a board was selected. Real movement is the only thing that counts,
  // so compare against the last position in window coordinates.
  property real lastPointerX: -1
  property real lastPointerY: -1

  function pointerMoved(item, mouse) {
    var p = item.mapToItem(null, mouse.x, mouse.y)
    if (Math.abs(p.x - root.lastPointerX) < 1 && Math.abs(p.y - root.lastPointerY) < 1)
      return false
    root.lastPointerX = p.x
    root.lastPointerY = p.y
    return true
  }

  // Parking the pointer again after a deliberate selection is the whole trick.
  // Changing the selected board rebuilds the panel's rows, which re-creates
  // the delegates under a pointer that never moved -- and their onEntered
  // would then hand focus straight back to the panel, which is exactly how
  // "hover board 3, press Enter, land on workspace 1" happened. The next real
  // pointer movement sets it live again.
  function takeTile(wsId) {
    root.selectedWorkspace = wsId
    root.focusRegion = "shelf"
    root.cursor = 0
    root.pointerLive = false
  }

  // ------------------------------------------------------- monitor geometry
  //
  // Everything here is measured off the live monitor and the compositor's
  // reserved area rather than baked in, so an external display or a bar on
  // another edge stays correct.

  readonly property var monitor: Hyprland.focusedMonitor
  readonly property var monitorIpc: root.monitor ? root.monitor.lastIpcObject : null
  readonly property real monitorScale: (root.monitor && root.monitor.scale > 0)
    ? root.monitor.scale : 1
  // HyprlandMonitor reports physical pixels; window geometry is logical.
  readonly property real monitorWidth: root.monitor
    ? root.monitor.width / root.monitorScale : 1512
  readonly property real monitorHeight: root.monitor
    ? root.monitor.height / root.monitorScale : 982
  readonly property real monitorX: root.monitor ? root.monitor.x : 0
  readonly property real monitorY: root.monitor ? root.monitor.y : 0

  // reserved is [left, top, right, bottom], in logical px.
  function reservedAt(i, fallback) {
    var r = root.monitorIpc ? root.monitorIpc.reserved : null
    if (r && r.length > i) {
      var v = Number(r[i])
      if (isFinite(v) && v >= 0) return Math.round(v)
    }
    return fallback
  }
  readonly property int reservedLeft: root.reservedAt(0, 0)
  readonly property int reservedTop: root.reservedAt(1, Style.bar.sizeHorizontal)
  readonly property int reservedRight: root.reservedAt(2, 0)
  readonly property int reservedBottom: root.reservedAt(3, 0)

  // What a window can actually occupy, which is what a board is a picture of.
  readonly property real usableX: root.monitorX + root.reservedLeft
  readonly property real usableY: root.monitorY + root.reservedTop
  readonly property real usableWidth: Math.max(1,
    root.monitorWidth - root.reservedLeft - root.reservedRight)
  readonly property real usableHeight: Math.max(1,
    root.monitorHeight - root.reservedTop - root.reservedBottom)
  readonly property real usableAspect: root.usableWidth / root.usableHeight

  // The bar's own height: the strip this surface has to cover to replace it.
  readonly property int barHeight: root.reservedTop > 0 ? root.reservedTop
                                                        : Style.bar.sizeHorizontal

  // ------------------------------------------------------------ live model
  //
  // Geometry and capture sources come from Quickshell's Hyprland IPC module,
  // which is the only place the two halves of this view meet: HyprlandToplevel
  // carries BOTH the window address the daemon keys everything by AND the
  // Wayland Toplevel that ScreencopyView captures. Without that join there is
  // no way to get from "the window on workspace 3" to its pixels -- appId and
  // title are all a bare Toplevel exposes, and neither is a key.
  //
  // Semantics (resolved app name, subject, context) come from the daemon's
  // triage.json instead: a window class is not an app name, and this view
  // never renders one (see CLAUDE.md).
  property var wsTiles: []
  property int liveWindowCount: 0

  function fallbackApp(title, appId) {
    // Only ever reached for a window the daemon has not seen yet. The last
    // " - "-separated segment of a title is the app's own name far more often
    // than not, and it is at least something a person wrote; the raw class is
    // never shown.
    var parts = String(title || "").split(" - ")
    if (parts.length > 1) {
      var tail = parts[parts.length - 1].replace(/^\s+|\s+$/g, "")
      if (tail) return tail
    }
    return String(appId || "")
  }

  function clamp01(v) { return v < 0 ? 0 : (v > 1 ? 1 : v) }

  function rebuild() {
    var byAddress = ({})
    var tw = (root.triageCache && Array.isArray(root.triageCache.windows))
      ? root.triageCache.windows : []
    for (var i = 0; i < tw.length; i++)
      byAddress[Omnibox.normalizeAddress(tw[i].address)] = tw[i]

    var buckets = ({})
    var total = 0
    var tls = (Hyprland.toplevels && Hyprland.toplevels.values) ? Hyprland.toplevels.values : []
    for (var j = 0; j < tls.length; j++) {
      var t = tls[j]
      if (!t || !t.workspace) continue
      var ws = Number(t.workspace.id)
      if (!(ws >= 1 && ws <= root.workspaceCount)) continue // real workspaces only
      var io = t.lastIpcObject || ({})
      var size = io.size || [1, 1]
      var at = io.at || [root.usableX, root.usableY]
      var addr = Omnibox.normalizeAddress(t.address)
      var meta = byAddress[addr] || ({})
      // Fractions of the usable area, which is what makes a board a real
      // miniature: a window filling the left half of the screen fills the
      // left half of its board, master/stack splits included.
      var entry = {
        toplevel: t,
        address: "0x" + addr,
        workspace: ws,
        fx: root.clamp01((Number(at[0]) - root.usableX) / root.usableWidth),
        fy: root.clamp01((Number(at[1]) - root.usableY) / root.usableHeight),
        fw: root.clamp01(Number(size[0]) / root.usableWidth),
        fh: root.clamp01(Number(size[1]) / root.usableHeight),
        app: meta.app || root.fallbackApp(t.title, t.appId),
        subject: meta.subject || Omnibox.stripStatusGlyphs(t.title),
        context: meta.context || "",
        host: meta.host || "",
        lastFocus: meta.lastFocus === undefined ? null : meta.lastFocus
      }
      if (!buckets[ws]) buckets[ws] = []
      buckets[ws].push(entry)
      total++
    }

    var tiles = []
    for (var n = 1; n <= root.workspaceCount; n++) {
      var named = (root.workspaceNames && root.workspaceNames[String(n)]) || ({})
      tiles.push({ id: n, name: named.name || "", icon: named.icon || "",
                   windows: buckets[n] || [] })
    }
    root.wsTiles = tiles
    root.liveWindowCount = total
  }

  // The window set can move under an open shelf (a title changes, a window
  // closes). Rebuilding is a walk of at most a few dozen objects with no
  // process call, so it is cheap enough to just redo it.
  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { if (root.opened) root.rebuild() }
  }

  onTriageCacheChanged: if (root.opened) root.rebuild()
  onWorkspaceNamesChanged: if (root.opened) root.rebuild()

  // ------------------------------------------------------------- filtering

  function matchesWindow(w) {
    if (root.query.length === 0) return true
    var q = root.query.toLowerCase()
    function has(s) { return String(s || "").toLowerCase().indexOf(q) >= 0 }
    return has(w.app) || has(w.subject) || has(w.context) || has(w.host)
  }

  // Per-workspace match counts: what dims a workspace with nothing to say and
  // badges the ones that do. "Answer and its location in one glance" is the
  // whole reason the shelf stays on screen while a query is live.
  readonly property var matchCounts: {
    var out = []
    for (var i = 0; i < root.wsTiles.length; i++) {
      var c = 0
      var wins = root.wsTiles[i].windows
      for (var j = 0; j < wins.length; j++) if (root.matchesWindow(wins[j])) c++
      out.push(c)
    }
    return out
  }

  function tileMatchCount(wsId) {
    var c = root.matchCounts[wsId - 1]
    return c === undefined ? 0 : c
  }

  // ------------------------------------------------------------------ rows

  readonly property int tierLimit: 6
  readonly property var rows: root.computeRows()

  // ------------------------------------------------------- the typed query
  //
  // With Chrome's address bar gone there must never be a state where Enter
  // does nothing useful with what was typed, so this row exists for every
  // non-empty query: "Open <url>" when the query is a location, "Search the
  // web for <query>" when it is not (through the user's OWN search engine,
  // which the daemon reads out of Chrome's Preferences).
  //
  // It is PINNED directly under the query line rather than sorted into the
  // result list, and it is its own focus region. That is the whole point: a
  // last row can be forty rows down a scrolling list, and a first row would
  // mean typing "gm" and pressing Enter searched the web instead of opening
  // gmail.com. Pinned, it is always on screen, always one key from the
  // cursor's home, and Enter still belongs to the best result -- which is
  // exactly where Chrome puts its own default suggestion.
  // Never null: an empty query still offers a browser window, because with
  // SUPER+T repointed at this surface there is no longer any keybind that
  // opens one. "No query" must not mean "no way out to the web".
  readonly property var queryAction: Omnibox.urlOrSearch(root.query, root.searchEngine)
    || Omnibox.newWindowAction()
  // A query with no matches at all leaves the panel region pointing at
  // nothing, and Enter doing nothing is precisely the state this piece exists
  // to abolish. So an empty result list hands the region to the pinned row
  // rather than to the void. Everything that draws or dispatches reads this,
  // never focusRegion directly.
  readonly property string activeRegion: (root.focusRegion === "panel"
    && root.selectableRows.length === 0) ? "action" : root.focusRegion
  readonly property var searchEngine: (root.omniboxIndex && root.omniboxIndex.search)
    ? root.omniboxIndex.search : null

  // ------------------------------------------------------- Chrome profiles
  //
  // THE KEY DECIDES, NEVER THE ROW. Enter opens a link in the armed profile
  // and Shift+Enter in the next one, whatever profile the matched history row
  // happens to have been recorded in. Deriving it from the row was tried and
  // is wrong: Gmail, Calendar and Drive accumulate history in both accounts,
  // so the row's origin is an accident of which one opened the page last, and
  // the same keystroke would go somewhere different on different days. Muscle
  // memory needs a rule, and "the key I pressed" is the only rule available
  // that a person can hold.
  //
  // The list is enumerated by the daemon from Local State's profile.info_cache
  // and arrives primary-first in the index. An empty list (no index yet, or
  // Chrome never run) falls back to the plain browser launcher, which is
  // exactly the old behaviour.
  readonly property var chromeProfiles:
    (root.omniboxIndex && Array.isArray(root.omniboxIndex.profiles))
      ? root.omniboxIndex.profiles : []
  // Which profile Enter opens in. Normally the configured primary, i.e. index
  // 0; a summon payload may arm another one for that invocation
  // ({"mode":"shelf","profile":"Profile 1"}), which is how a second chord can
  // mean "this time, the other account" without changing what Enter means the
  // rest of the time.
  property int enterAt: 0
  // How far past it Shift+Enter reaches. Only ever moves with three or more
  // profiles, where it cycles -- and the footer always names the profile it is
  // pointing at, because a key that silently picks one of three is not a rule.
  property int shiftOffset: 1

  function profileAt(i) {
    var n = root.chromeProfiles.length
    return n === 0 ? null : root.chromeProfiles[((i % n) + n) % n]
  }

  readonly property var enterProfile: root.profileAt(root.enterAt)
  readonly property var shiftProfile: root.chromeProfiles.length > 1
    ? root.profileAt(root.enterAt + root.shiftOffset) : null

  // The payload names a profile DIRECTORY ("Profile 1"), since that is the
  // stable key; an unknown one falls back to the primary rather than failing,
  // because a bind with a stale profile name in it must still open the shelf.
  function armProfile(directory) {
    root.shiftOffset = 1
    root.enterAt = 0
    var wanted = String(directory || "")
    if (!wanted) return
    for (var i = 0; i < root.chromeProfiles.length; i++)
      if (root.chromeProfiles[i] && root.chromeProfiles[i].dir === wanted) {
        root.enterAt = i
        return
      }
  }

  // True when Enter would hand a URL to a browser, i.e. when the profile
  // question even arises. A window or a conversation has nothing to do with
  // Chrome and must not claim otherwise in the footer.
  function opensInBrowser() {
    if (root.activeRegion === "action") return root.queryAction !== null
    if (root.activeRegion !== "panel") return false
    var row = root.currentRow()
    return !!(row && row.kind === "history")
  }

  // What Enter does right now, in words, for the footer. When it opens a link
  // it names the ACCOUNT rather than the verb, because with two profiles the
  // interesting half of "open" is which one -- and it is stated rather than
  // implied, so Shift+Enter is never a guess.
  function enterHint() {
    // The profiles are named whenever Enter opens a link, and named more
    // quietly when it does not -- but always NAMED. Which account a keystroke
    // uses is the one thing about this surface that must never have to be
    // remembered, and the display names are the only spelling of a profile a
    // person should ever have to read.
    var primary = root.profileName(root.enterProfile)
    var secondary = root.profileName(root.shiftProfile)
    var suffix = (root.chromeProfiles.length > 2) ? " (⌃⇥ next)" : ""
    if (root.activeRegion === "shelf")
      return "⏎ " + (root.selectedWorkspace > 0
        ? "go to workspace " + root.selectedWorkspace : "type to search")
    if (root.opensInBrowser() && primary)
      return "⏎ " + primary + (secondary ? " · ⇧⏎ " + secondary : "") + suffix
    if (root.activeRegion === "action")
      return "⏎ " + (!root.queryAction ? "search the web"
        : root.queryAction.kind === "open" ? "open it"
        : root.queryAction.kind === "window" ? "new window" : "search the web")
    return "⏎ focus / resume / open"
      + (primary ? ("    links ⏎ " + primary
                    + (secondary ? " · ⇧⏎ " + secondary : "") + suffix) : "")
  }

  function cycleShiftProfile() {
    var n = root.chromeProfiles.length
    if (n <= 2) return          // with two, "the other one" is not a choice
    root.shiftOffset = (root.shiftOffset % (n - 1)) + 1
  }

  function profileName(profile) {
    // Never the directory: "Profile 1" is an internal identifier.
    return (profile && profile.name) ? String(profile.name) : ""
  }

  function windowsForTile() {
    var out = []
    for (var i = 0; i < root.wsTiles.length; i++) {
      if (root.selectedWorkspace > 0 && root.wsTiles[i].id !== root.selectedWorkspace) continue
      var wins = root.wsTiles[i].windows
      for (var j = 0; j < wins.length; j++)
        if (root.matchesWindow(wins[j])) out.push(wins[j])
    }
    return out
  }

  // A workspace's model-given name is a phrase ("Github Nonprofits"), and no
  // conversation title contains that phrase verbatim. Matching it word by word
  // is what makes a selected board show everything ABOUT that piece of work
  // rather than just the two windows that happen to be open. A typed query is
  // never treated this way -- what someone typed means exactly what it says.
  function indexMatchesByName(name, conversations) {
    var raw = String(name || "").toLowerCase().split(/[^a-z0-9]+/)
    var tokens = []
    for (var i = 0; i < raw.length; i++) if (raw[i].length >= 4) tokens.push(raw[i])
    if (tokens.length === 0) return []
    var seen = ({})
    var out = []
    for (var t = 0; t < tokens.length; t++) {
      var hits = conversations
        ? Omnibox.matchConversations(tokens[t], root.omniboxIndex)
        : Omnibox.matchHistory(tokens[t], root.omniboxIndex)
      for (var h = 0; h < hits.length; h++) {
        var key = conversations ? hits[h].id : hits[h].url
        if (seen[key]) continue
        seen[key] = true
        out.push(hits[h])
      }
    }
    return out
  }

  function computeRows() {
    var out = []

    var wins = root.windowsForTile()
    // Most recently touched first. A window the daemon has never watched take
    // focus reports null rather than a guess (see CLAUDE.md), so it sorts to
    // the bottom rather than pretending to be new.
    wins = wins.slice().sort(function(a, b) {
      return (Number(b.lastFocus) || 0) - (Number(a.lastFocus) || 0)
    })

    if (root.query.length > 0) {
      // With a query the open hits are grouped by where they are -- the
      // location is half the answer.
      var seen = ({})
      for (var i = 0; i < wins.length; i++) {
        var w = wins[i]
        if (!seen[w.workspace]) {
          var tile = root.tileFor(w.workspace)
          out.push({ kind: "section", label: "On workspace " + w.workspace
            + (tile && tile.name ? " · " + tile.name : "") })
          seen[w.workspace] = true
        }
        out.push({ kind: "window", window: w })
      }
    } else if (wins.length > 0) {
      var tile2 = root.tileFor(root.selectedWorkspace)
      out.push({ kind: "section", label: tile2
        ? ("Workspace " + tile2.id + (tile2.name ? " · " + tile2.name : "")
           + " · " + wins.length + (wins.length === 1 ? " window" : " windows"))
        : ("Open · " + wins.length + (wins.length === 1 ? " window" : " windows")) })
      for (var p = 0; p < wins.length; p++) out.push({ kind: "window", window: wins[p] })
    }

    // Conversations and history: with a query they answer the query; without
    // one they answer the selection.
    var convs, hist
    if (root.query.length > 0) {
      convs = Omnibox.matchConversations(root.query, root.omniboxIndex)
      hist = Omnibox.matchHistory(root.query, root.omniboxIndex)
    } else if (root.selectedWorkspace > 0) {
      var selected = root.tileFor(root.selectedWorkspace)
      var name = selected ? selected.name : ""
      convs = root.indexMatchesByName(name, true)
      hist = root.indexMatchesByName(name, false)
    } else {
      // Summary with no query: the most recent of everything, unfiltered.
      convs = root.recentConversations()
      hist = root.recentHistory()
    }

    if (convs.length > 0) {
      var cShown = convs.slice(0, root.tierLimit)
      out.push({ kind: "section", label: "Conversations"
        + (convs.length > cShown.length ? " · " + cShown.length + " of " + convs.length
                                        : " · " + convs.length) })
      for (var c = 0; c < cShown.length; c++)
        out.push({ kind: "conversation", conversation: cShown[c] })
    }

    if (hist.length > 0) {
      var hShown = hist.slice(0, root.tierLimit)
      out.push({ kind: "section", label: "Links"
        + (hist.length > hShown.length ? " · " + hShown.length + " of " + hist.length
                                       : " · " + hist.length) })
      for (var h = 0; h < hShown.length; h++)
        out.push({ kind: "history", history: hShown[h] })
    }

    return out
  }

  function recentConversations() {
    var convs = (root.omniboxIndex && Array.isArray(root.omniboxIndex.conversations))
      ? root.omniboxIndex.conversations.slice() : []
    convs.sort(function(a, b) { return (Number(b.mtime) || 0) - (Number(a.mtime) || 0) })
    return convs
  }

  function recentHistory() {
    var hist = (root.omniboxIndex && Array.isArray(root.omniboxIndex.history))
      ? root.omniboxIndex.history.slice() : []
    hist.sort(function(a, b) { return (Number(b.lastVisit) || 0) - (Number(a.lastVisit) || 0) })
    return hist
  }

  // Section labels are headings, never landing places -- same rule as
  // Triage.qml's tier rows.
  readonly property var selectableRows: {
    var out = []
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].kind !== "section") out.push(i)
    return out
  }

  function currentRow() {
    var sel = root.selectableRows
    if (sel.length === 0) return null
    return root.rows[sel[Math.max(0, Math.min(root.cursor, sel.length - 1))]]
  }

  // Down out of the shelf lands in the panel; up off the top row goes back to
  // the shelf. The two regions are one continuous list to the arrow keys, and
  // the boundary is where Enter changes meaning.
  function select(delta) {
    var n = root.selectableRows.length
    root.pointerLive = false
    // Down out of the boards lands on the pinned query row if there is one,
    // then in the list; up retraces the same three steps. One continuous
    // column to the arrow keys, with Enter changing meaning at each boundary.
    if (root.focusRegion === "shelf") {
      if (delta <= 0) return
      if (root.queryAction) { root.focusRegion = "action"; return }
      if (n > 0) {
        root.focusRegion = "panel"
        root.cursor = 0
        listView.positionViewAtIndex(root.selectableRows[0], ListView.Contain)
      }
      return
    }
    if (root.focusRegion === "action") {
      if (delta < 0) { root.focusRegion = "shelf"; return }
      if (n > 0) {
        root.focusRegion = "panel"
        root.cursor = 0
        listView.positionViewAtIndex(root.selectableRows[0], ListView.Contain)
      }
      return
    }
    if (n === 0) { root.focusRegion = root.queryAction ? "action" : "shelf"; return }
    if (delta < 0 && root.cursor === 0) {
      root.focusRegion = root.queryAction ? "action" : "shelf"
      return
    }
    root.cursor = (root.cursor + delta + n) % n
    listView.positionViewAtIndex(root.selectableRows[root.cursor], ListView.Contain)
  }

  function selectRow(flatIndex) {
    var pos = root.selectableRows.indexOf(flatIndex)
    if (pos < 0) return
    root.cursor = pos
    root.focusRegion = "panel"
  }

  // --------------------------------------------------------------- actions
  //
  // Identical dispatch shapes to Triage.qml: this Hyprland is Lua-configured,
  // so `hyprctl dispatch` is shorthand for hl.dispatch(...) and the classic
  // "focuswindow address:0x.." string form is a silent Lua syntax error.

  function execCmdDispatch(shellCommand) {
    var lua = shellCommand.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
    return 'hl.dsp.exec_cmd("' + lua + '")'
  }

  function findOpenClaudeWindow(title) {
    var target = String(title || "")
    if (!target) return null
    for (var i = 0; i < root.wsTiles.length; i++) {
      var wins = root.wsTiles[i].windows
      for (var j = 0; j < wins.length; j++) {
        var w = wins[j]
        if (!w.toplevel) continue
        if (String(w.toplevel.appId).toLowerCase() !== "org.omarchy.claude") continue
        if (Omnibox.stripStatusGlyphs(w.toplevel.title) === target) return w
      }
    }
    return null
  }

  function focusAddress(address) {
    root.runAfterClose(["hyprctl", "dispatch",
      'hl.dsp.focus({ window = "address:' + address + '" })'])
  }

  function openConversation(conv) {
    if (!conv) return
    var existing = root.findOpenClaudeWindow(conv.title)
    if (existing && existing.address) { root.focusAddress(existing.address); return }
    root.closeRequested()
    var cmd = "setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.claude --dir="
      + Util.shellQuote(conv.project) + " -e claude --resume " + Util.shellQuote(conv.id)
    launchProc.command = ["hyprctl", "dispatch", root.execCmdDispatch(cmd)]
    launchProc.running = true
  }

  // `secondary` is the Shift half of the chord, not a property of the row:
  // the same row opens in either account depending only on which key was
  // pressed. Chrome's --profile-directory takes the DIRECTORY name, which is
  // why the index carries both that and the display name.
  // An empty url means "just a window", which is the empty-query action.
  function openUrl(url, secondary) {
    var profile = secondary ? root.shiftProfile : root.enterProfile
    var target = url ? (" " + Util.shellQuote(url)) : " --new-window"
    var cmd = (profile && profile.dir)
      ? ("setsid uwsm-app -- google-chrome-stable --profile-directory="
         + Util.shellQuote(profile.dir) + target)
      : ("omarchy launch browser" + target)
    launchProc.command = ["hyprctl", "dispatch", root.execCmdDispatch(cmd)]
    launchProc.running = true
  }

  function openHistoryEntry(hist, secondary) {
    if (hist && hist.url) root.openUrl(hist.url, secondary)
  }

  // Enter on a board goes to that workspace; Enter on a row acts on the row.
  // Which of those applies is root.focusRegion and nothing else -- in
  // particular not "does the panel happen to have rows", which is what this
  // used to ask and is why hovering board 3 and pressing Enter landed on
  // workspace 1.
  function activateCurrent(secondary) {
    if (root.activeRegion === "shelf") {
      if (root.selectedWorkspace > 0) root.gotoWorkspace(root.selectedWorkspace)
      return
    }
    if (root.activeRegion === "action") {
      if (root.queryAction) {
        root.openUrl(root.queryAction.url, secondary)
        root.closeRequested()
      }
      return
    }
    var row = root.currentRow()
    if (!row) return
    if (row.kind === "conversation") { root.openConversation(row.conversation); return }
    if (row.kind === "history") {
      root.openHistoryEntry(row.history, secondary); root.closeRequested(); return
    }
    if (row.kind === "window" && row.window && row.window.address)
      root.focusAddress(row.window.address)   // defers its own close
  }

  // The real workspace id, never a tile ordinal -- see selectedWorkspace.
  function gotoWorkspace(wsId) {
    root.runAfterClose(["hyprctl", "dispatch",
      'hl.dsp.focus({ workspace = "' + wsId + '" })'])
  }

  // Invoked from Overlay.qml's triageMove(arg) IPC entry point, driven by the
  // SUPER+SHIFT+<n> binds in the "literate-triage" Hyprland submap. Only a
  // window row has a workspace to move to.
  function moveCurrent(target) {
    var row = root.currentRow()
    if (!row || row.kind !== "window" || !row.window || !row.window.address) return
    // follow = true, so this moves focus too and is subject to the same
    // restore-on-unmap problem as gotoWorkspace above.
    root.runAfterClose(["hyprctl", "dispatch",
      'hl.dsp.window.move({ workspace = "' + target + '", follow = true, window = "address:'
      + row.window.address + '" })'])
  }

  // ------------------------------------------------------------------ keys

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (root.query) root.setQuery("")
      else root.closeRequested()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab && (event.modifiers & Qt.ControlModifier)) {
      // Only does anything with three or more profiles; see cycleShiftProfile.
      root.cycleShiftProfile()
      event.accepted = true
    } else if (event.key === Qt.Key_Backtab
        || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
      root.selectTile(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Tab) {
      root.selectTile(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Left) {
      root.selectTile(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Right) {
      root.selectTile(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      root.select(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      root.select(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      // Shift is the profile switch and nothing else: same row, same query,
      // other account.
      root.activateCurrent((event.modifiers & Qt.ShiftModifier) !== 0)
      event.accepted = true
    } else if (Util.editsFilter(event, root.query)) {
      root.setQuery(Util.editedFilter(event, root.query))
      event.accepted = true
    } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32
        && event.text.charCodeAt(0) !== 127
        && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
      // Every printable character is a search character, j and k included --
      // same rule as Triage.qml. Navigation is arrows and Tab only.
      root.setQuery(root.query + event.text)
      event.accepted = true
    }
  }

  // ------------------------------------------------------- launcher chords
  //
  // With a query typed, the user's own launcher chords should act on that text
  // instead of launching an empty app. Which chords those ARE is discovered
  // from `hyprctl binds -j` by matching the human descriptions, never
  // hardcoded: rebind Terminal to something else tomorrow and this follows
  // with no code change. A description that is not found simply yields no
  // affordance.
  //
  // What CANNOT be reused is the bind's action. On this Lua-configured
  // Hyprland every user bind reports dispatcher "__lua" with an opaque
  // callback index as its arg, so there is no command string to recover. The
  // command is therefore reconstructed from Omarchy's own launchers, with one
  // detail taken from the discovery rather than assumed: the agent's model
  // comes out of the matched description ("Claude Code (Opus)" -> opus), so a
  // user who binds Sonnet gets Sonnet.
  readonly property var agentPreference: ["claude code (opus)", "claude code (sonnet)",
    "claude code (fable)", "claude code", "agent"]

  // { terminal: {chord,label,model}, browser: {...}, agent: {...} }
  property var launchChords: ({})
  property string chordSignature: ""

  function modNames(modmask) {
    var m = Number(modmask) || 0
    var out = []
    if (m & 64) out.push("SUPER")
    if (m & 4) out.push("CTRL")
    if (m & 8) out.push("ALT")
    if (m & 1) out.push("SHIFT")
    return out
  }

  function chordString(modmask, key) {
    var mods = root.modNames(modmask)
    mods.push(String(key))
    return mods.join(" + ")
  }

  // The same chord written the way the rest of the UI writes shortcut hints.
  function chordLabel(modmask, key) {
    var m = Number(modmask) || 0
    var out = ""
    if (m & 64) out += "⌘"
    if (m & 4) out += "⌃"
    if (m & 8) out += "⌥"
    if (m & 1) out += "⇧"
    var k = String(key)
    var pretty = ({ comma: ",", period: ".", slash: "/", RETURN: "⏎", SPACE: "␣" })
    return out + (pretty[k] !== undefined ? pretty[k] : k.toUpperCase())
  }

  function handleBinds(raw) {
    var binds = []
    try { binds = JSON.parse(raw || "[]") } catch (e) { return }
    if (!Array.isArray(binds)) return

    var byDescription = ({})
    for (var i = 0; i < binds.length; i++) {
      var b = binds[i]
      // Global binds only: a bind already inside a submap is not a chord the
      // user presses from the desktop.
      if (!b || b.mouse || (b.submap && b.submap.length > 0)) continue
      var d = String(b.description || "").toLowerCase()
      if (!d) continue
      if (byDescription[d] === undefined) byDescription[d] = b
    }

    function pick(names) {
      for (var n = 0; n < names.length; n++)
        if (byDescription[names[n]]) return byDescription[names[n]]
      return null
    }

    var found = ({})
    var terminal = pick(["terminal"])
    if (terminal) found.terminal = { chord: root.chordString(terminal.modmask, terminal.key),
                                     label: root.chordLabel(terminal.modmask, terminal.key) }
    var browser = pick(["browser"])
    if (browser) found.browser = { chord: root.chordString(browser.modmask, browser.key),
                                   label: root.chordLabel(browser.modmask, browser.key) }
    var agent = pick(root.agentPreference)
    if (agent) {
      var model = ""
      var m = String(agent.description || "").match(/\(([^)]+)\)/)
      if (m) model = m[1].toLowerCase()
      found.agent = { chord: root.chordString(agent.modmask, agent.key),
                      label: root.chordLabel(agent.modmask, agent.key), model: model }
    }

    var sig = JSON.stringify(found)
    if (sig === root.chordSignature) return
    root.chordSignature = sig
    root.launchChords = found
    root.defineSubmap()
  }

  Process {
    id: bindsProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleBinds(text)
    }
  }

  // The submap that shadows those chords while the shelf is up. It has to
  // exist: they are GLOBAL binds, so without it the compositor launches an
  // empty terminal and this plugin never sees the key -- exactly the trap
  // SUPER+SHIFT+<digit> hit.
  //
  // It is defined at RUNTIME rather than written into bindings.lua, because
  // the chords are discovered rather than fixed and a static list would go
  // stale the first time the user rebinds. `hyprctl keyword` is refused on
  // this Hyprland ("keyword can't work with non-legacy parsers, use eval"),
  // but `hyprctl eval` runs Lua in the config's own context, where
  // hl.define_submap and hl.bind are both callable.
  //
  // Each definition gets a fresh generation name rather than redefining one
  // name, which sidesteps the question of whether a redefinition replaces or
  // appends -- the same lesson as the Lua layout API (see CLAUDE.md). It only
  // happens when the discovered set actually changes, i.e. once per session
  // on a machine nobody is rebinding.
  property int submapGeneration: 0
  property string submapName: ""

  function luaString(text) {
    return '"' + String(text).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  }

  function defineSubmap() {
    root.submapGeneration += 1
    // The name has to be unique across shell RESTARTS too, not just within one
    // process: a runtime-defined submap outlives the shell, and redefining an
    // existing name APPENDS to it rather than replacing it (verified -- a
    // restart left the same submap holding both the old and the new Escape
    // bind). A wall-clock component is what makes each definition its own
    // submap.
    var name = "literate-shelf-" + Date.now() + "-" + root.submapGeneration
    var lines = []
    lines.push('hl.define_submap(' + root.luaString(name) + ', function()')
    for (var n = 1; n <= 9; n++)
      lines.push('  hl.bind("SUPER + SHIFT + ' + n + '", hl.dsp.exec_cmd('
        + root.luaString("omarchy-shell shell call literate triageMove " + n)
        + '), { description = "Send to workspace ' + n + '" })')
    var kinds = ["terminal", "browser", "agent"]
    for (var k = 0; k < kinds.length; k++) {
      var c = root.launchChords[kinds[k]]
      if (!c) continue
      lines.push('  hl.bind(' + root.luaString(c.chord) + ', hl.dsp.exec_cmd('
        + root.luaString("omarchy-shell shell call literate shelfLaunch " + kinds[k])
        + '), { description = "Omnibox ' + kinds[k] + '" })')
    }
    // Safety exit only, and deliberately NOT plain Escape: a submap that
    // swallows Escape makes the shelf take two presses to close (the
    // compositor eats the first and answers it with a process spawn) and kills
    // the client's own "clear the query, then close". Escape belongs to the
    // QML; this is for an overlay wedged badly enough that its close path
    // never runs.
    lines.push('  hl.bind("SUPER + Escape", hl.dsp.submap("reset"), '
      + '{ description = "Exit shelf submap" })')
    lines.push('end)')
    submapProc.command = ["hyprctl", "eval", lines.join("\n")]
    submapProc.running = true
    root.submapName = name
  }

  Process {
    id: submapProc
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim()) console.warn("literate shelf submap:", line)
      }
    }
  }

  Component.onCompleted: bindsProc.running = true

  // ------------------------------------------------------ launcher actions

  // Pre-filled but NOT executed: running arbitrary typed text as a shell
  // command straight out of a search box is a foot-gun. The line is put into
  // readline's buffer with the terminal's own Device Status Report reply
  // (printf '\e[5n' -> the terminal answers '\e[0n' -> readline expands the
  // macro bound to it), which leaves the text on the prompt with the cursor
  // after it and nothing run. The rc file is written by argv rather than
  // through a quoted shell string, so nothing in the query can escape it.
  function terminalCommandFor(query) {
    var rc = root.runtimeDir + "/literate-prefill.bashrc"
    return "setsid uwsm-app -- xdg-terminal-exec -- bash --rcfile " + Util.shellQuote(rc) + " -i"
  }

  readonly property string runtimeDir: {
    var d = Quickshell.env("XDG_RUNTIME_DIR")
    return d && d.length > 0 ? d : "/tmp"
  }

  function launchTerminal(query) {
    // A directory is not a command: go there instead of typing it.
    dirProc.pendingQuery = query
    dirProc.command = ["sh", "-c", '[ -d "$1" ] && printf yes || printf no', "sh", query]
    dirProc.running = true
  }

  function openTerminalIn(dir) {
    var cmd = "setsid uwsm-app -- xdg-terminal-exec --dir=" + Util.shellQuote(dir)
    launchProc.command = ["hyprctl", "dispatch", root.execCmdDispatch(cmd)]
    launchProc.running = true
  }

  function openTerminalPrefilled(query) {
    var rc = root.runtimeDir + "/literate-prefill.bashrc"
    var body = '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"\n'
      + "bind '\"\\e[0n\": \"" + String(query).replace(/\\/g, "\\\\").replace(/"/g, '\\"')
      + "\"' 2>/dev/null\n"
      + "printf '\\033[5n'\n"
    rcProc.command = ["sh", "-c", 'printf %s "$1" > "$2"', "sh", body, rc]
    rcProc.running = true
  }

  Process {
    id: rcProc
    onExited: function(code) {
      if (code !== 0) { console.warn("literate shelf: could not write prefill rc"); return }
      var cmd = root.terminalCommandFor(root.query)
      launchProc.command = ["hyprctl", "dispatch", root.execCmdDispatch(cmd)]
      launchProc.running = true
    }
  }

  Process {
    id: dirProc
    property string pendingQuery: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text).trim() === "yes") root.openTerminalIn(dirProc.pendingQuery)
        else root.openTerminalPrefilled(dirProc.pendingQuery)
      }
    }
  }

  // The browser chord and the pinned query row are the same decision, so they
  // go through the same rules (Omnibox.urlOrSearch) rather than two copies.
  function launchBrowser(query) {
    var action = Omnibox.urlOrSearch(query, root.searchEngine)
    if (action) root.openUrl(action.url)
  }

  function launchAgent(query) {
    var c = root.launchChords.agent
    var model = (c && c.model) ? c.model : "opus"
    var cmd = "omarchy-launch-tui --app-id=org.omarchy.claude claude --model "
      + Util.shellQuote(model) + " " + Util.shellQuote(query)
    launchProc.command = ["hyprctl", "dispatch", root.execCmdDispatch(cmd)]
    launchProc.running = true
  }

  // Entry point for the submap binds above, via Overlay.qml's shelfLaunch().
  function launchWithQuery(kind) {
    var q = String(root.query || "").replace(/^\s+|\s+$/g, "")
    // The browser chord with nothing typed is the same standing offer the
    // pinned row makes: a window, in the armed profile.
    if (!q && kind === "browser") { root.openUrl(""); root.closeRequested(); return }
    if (!q) return
    if (kind === "terminal") root.launchTerminal(q)
    else if (kind === "browser") root.launchBrowser(q)
    else if (kind === "agent") root.launchAgent(q)
    else return
    root.closeRequested()
  }

  // ----------------------------------------------------------------- files
  //
  // Exactly the FileView idiom Triage.qml uses, and for the same reason:
  // Overlay.qml is keepLoaded, so every file is parsed long before the key is
  // ever pressed and the first frame is already complete.

  property var triageCache: null
  property var workspaceNames: ({})
  property var omniboxIndex: null

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/literate/triage.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var d = null
      try { d = JSON.parse(text()) } catch (e) { d = null }
      root.triageCache = (d && Array.isArray(d.windows)) ? d : null
    }
    onLoadFailed: root.triageCache = null
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/literate/workspaces.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var d = null
      try { d = JSON.parse(text()) } catch (e) { d = null }
      root.workspaceNames = (d && typeof d === "object") ? d : ({})
    }
    onLoadFailed: root.workspaceNames = ({})
  }

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

  Process {
    id: launchProc
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim()) console.warn("literate shelf launch:", line)
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

  // ----------------------------------------------------------------- theme
  //
  // The shelf half derives from [bar] so it reads as one surface with the bar
  // it is standing in front of; the panel half derives from [menu], exactly
  // like Triage.qml's rows, so a light theme's popups stay light.

  readonly property color shelfBackground: Color.bar.background
  readonly property color shelfText: Color.bar.text
  readonly property color accent: Color.popups.border
  readonly property color panelBackground: Color.menu.background
  readonly property color panelText: Color.menu.text
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property string fontFamily: Style.font.menuFamily
  // The workspace labels animate out of the bar, so they are drawn in the
  // bar's own font at the bar's size -- otherwise the first frame is a
  // substitution rather than a movement.
  readonly property string barFontFamily: Style.font.family

  readonly property int tileRadius: Math.max(Style.space(8), Style.cornerRadius)
  readonly property int cellRadius: Math.max(Style.space(4), Math.round(Style.cornerRadius / 2))
  readonly property int shelfPadding: Style.space(9)
  readonly property int tileGap: Style.space(7)
  readonly property int tilePadding: Style.space(5)
  readonly property int tileHeaderHeight: Style.space(18)
  readonly property int summaryWidth: Style.space(92)
  readonly property int emptyTileMinWidth: Style.space(34)
  readonly property int rowHeight: Math.max(Style.space(30), Style.font.body + Style.spacing.md * 2)
  readonly property int sectionHeight: Style.space(24)
  readonly property int panelPadding: Style.spacing.popupPadding
  readonly property int footerHeight: Style.space(26)
  readonly property int queryBarHeight: Style.space(34)

  // -------------------------------------------------------- board geometry
  //
  // Boards keep the screen's aspect ratio, which fixes their height once their
  // width is known. Nine boards at true aspect do not fit at a generous size,
  // so: occupied boards keep true aspect and share the free width equally, and
  // EMPTY workspaces -- which hold nothing, so a board shape would be claiming
  // something false -- collapse to outlines and absorb whatever width the
  // aspect cap leaves over. That is also what stops the row reflowing when a
  // workspace gains or loses its last window.
  readonly property real shelfWidth: shelfWindow.width
  readonly property int occupiedCount: {
    var n = 0
    for (var i = 0; i < root.wsTiles.length; i++)
      if (root.wsTiles[i].windows.length > 0) n++
    return n
  }
  readonly property int emptyCount: root.workspaceCount - root.occupiedCount
  // Without a ceiling, two occupied workspaces would each get a ~700px board
  // and the shelf would swallow half the screen. A shelf is a glance, not a
  // view.
  readonly property real maxBoardHeight: Math.round(root.monitorHeight * 0.17)
  readonly property real innerWidth: Math.max(1, root.shelfWidth - root.shelfPadding * 2
    - root.tileGap * root.workspaceCount - root.summaryWidth)
  // The BOARD is the picture; the tile is the board plus its padding. Deriving
  // the height from the tile width instead would make every board a little
  // squatter than the screen, which is exactly the error this is here to
  // avoid.
  readonly property real boardWidth: {
    if (root.occupiedCount <= 0) return 0
    var rawTile = (root.innerWidth - root.emptyTileMinWidth * root.emptyCount)
      / root.occupiedCount
    return Math.max(Style.space(30),
      Math.min(rawTile - root.tilePadding * 2, root.maxBoardHeight * root.usableAspect))
  }
  readonly property real boardHeight: root.occupiedCount > 0
    ? Math.round(root.boardWidth / root.usableAspect)
    : Math.round(root.emptyTileMinWidth * 2 / root.usableAspect)
  readonly property real occupiedTileWidth: root.boardWidth + root.tilePadding * 2
  // Empty workspaces absorb what the aspect cap leaves over, but only up to
  // twice their minimum -- past that they stop reading as "collapsed" and
  // start looking like boards that failed to load. Anything still left over is
  // trailing space at the right-hand end of the row.
  readonly property real emptyWidth: root.emptyCount > 0
    ? Math.max(root.emptyTileMinWidth, Math.min(root.emptyTileMinWidth * 2,
        (root.innerWidth - root.occupiedTileWidth * root.occupiedCount) / root.emptyCount))
    : root.emptyTileMinWidth

  readonly property real tileHeight: root.tilePadding * 2 + root.tileHeaderHeight
    + root.boardHeight
  readonly property real shelfHeight: root.shelfPadding * 2 + root.tileHeight

  // Expanded x for tile index 0 (Summary) and 1..9.
  function expandedX(index) {
    var x = root.shelfPadding
    if (index === 0) return x
    x += root.summaryWidth + root.tileGap
    for (var n = 1; n <= root.workspaceCount; n++) {
      if (n === index) return x
      x += (root.wsTiles[n - 1] && root.wsTiles[n - 1].windows.length > 0
            ? root.occupiedTileWidth : root.emptyWidth) + root.tileGap
    }
    return x
  }

  function expandedW(index) {
    if (index === 0) return root.summaryWidth
    return (root.wsTiles[index - 1] && root.wsTiles[index - 1].windows.length > 0)
      ? root.occupiedTileWidth : root.emptyWidth
  }

  // ------------------------------------------------------------ panel size

  // FIXED, and deliberately not derived from the row count. The panel's height
  // is the layer surface's height, and a Wayland surface that resizes
  // mid-interaction is what produced the collapse-and-re-expand flinch every
  // time Tab moved to a workspace holding a different number of windows. A
  // shelf that is occasionally a little taller than its contents is a much
  // smaller cost than one that breathes -- the same call Triage.qml already
  // made about its own card. Anything longer than this scrolls.
  readonly property int panelHeight: Math.max(Style.space(160),
    Math.round(root.monitorHeight * 0.42))

  // ---------------------------------------------------------------- layout

  PanelWindow {
    id: shelfWindow
    visible: root.windowVisible
    color: "transparent"
    WlrLayershell.namespace: "literate-shelf"
    WlrLayershell.layer: WlrLayer.Overlay
    // Released the instant `opened` goes false rather than when the collapse
    // animation lands, so whatever is underneath gets its keys back at once.
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive
                                             : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // y = 0: this surface covers the bar. See the header comment.
    anchors { top: true; left: true; right: true }
    margins.top: 0

    implicitHeight: root.barHeight + root.shelfHeight + root.panelHeight

    MouseArea { anchors.fill: parent; onClicked: {} }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.handleKey(event) }
    }

    // ------------------------------------------------------------- shelf

    Rectangle {
      id: shelfSurface
      anchors { top: parent.top; left: parent.left; right: parent.right }
      // Exactly the bar's height when collapsed, so at rest this is
      // indistinguishable from the bar it is standing in front of. Opaque from
      // the very first frame -- that, not the geometry, is what keeps the real
      // bar's workspace row from ever showing through beside ours.
      height: root.lerp(root.barHeight, root.barHeight + root.shelfHeight, root.extent)
      color: root.shelfBackground
      clip: true

      // ----------------------------------------------------- summary tile

      Rectangle {
        id: summaryTile
        x: root.expandedX(0)
        y: root.barHeight + root.shelfPadding + root.contentOffset
        width: root.expandedW(0)
        height: root.tileHeight
        opacity: root.reveal
        radius: root.tileRadius
        color: Util.alpha(root.shelfText, root.selectedWorkspace === 0 ? 0.10 : 0.045)

        Rectangle {
          anchors.fill: parent
          radius: parent.radius
          color: "transparent"
          // Selection and FOCUS are two different states and look different:
          // a full accent ring means Enter acts here, a hairline means this is
          // still the selection but Enter belongs to the panel.
          border.width: (root.selectedWorkspace === 0 || root.query.length > 0)
            ? (root.focusRegion === "shelf" ? Math.max(1, Style.space(2)) : Math.max(1, Style.space(1)))
            : 0
          border.color: root.focusRegion === "shelf" ? root.accent
                                                     : Util.alpha(root.accent, 0.45)
        }

        // The leftmost stop is a search affordance, not a scoreboard. A count
        // of windows is a fact nobody can act on, and this is the most
        // valuable slot on the shelf: it says what typing does, and lights up
        // once something has been typed so it is obvious where the text went.
        // The query text itself stays in the panel header below -- this tile
        // is only as wide as its label, and eliding a search you are still
        // typing would be worse than reading it one row lower.
        Item {
          anchors.fill: parent
          anchors.margins: root.tilePadding
          clip: true

          Column {
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.glyph("magnifying-glass")
              color: root.query.length > 0 ? root.accent
                : (root.selectedWorkspace === 0 ? root.shelfText
                                                : Util.alpha(root.shelfText, 0.6))
              font.family: phosphor.font.family
              font.pixelSize: Math.max(Style.font.body, Math.min(
                Style.font.iconLarge, Math.round(root.boardHeight * 0.30)))
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "Jump to"
              color: root.selectedWorkspace === 0 ? root.shelfText
                                                  : Util.alpha(root.shelfText, 0.65)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            // Shortcut hint, shown the way the rest of the shell shows them:
            // subordinate to the label it explains.
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "⌘ /"
              color: Util.alpha(root.shelfText, 0.45)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: root.reveal > 0.9
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          id: summaryMouse
          onEntered: root.hoverTile(0)
          onPositionChanged: function(mouse) {
            if (!root.pointerMoved(summaryMouse, mouse)) return
            root.pointerLive = true
            root.hoverTile(0)
          }
          onClicked: root.pickTile(0)
        }
      }

      // -------------------------------------------------- workspace boards

      Repeater {
        model: root.wsTiles

        delegate: Rectangle {
          id: wsTile
          required property var modelData

          readonly property int wsId: wsTile.modelData.id
          readonly property bool occupied: wsTile.modelData.windows.length > 0
          readonly property bool selected: root.selectedWorkspace === wsTile.wsId
          readonly property int matchCount: root.tileMatchCount(wsTile.wsId)
          // A live query dims everything it did not find. The selected board
          // never dims -- it is where the user is standing.
          readonly property bool dimmed: root.query.length > 0
            && wsTile.matchCount === 0 && !wsTile.selected
          readonly property real tone: wsTile.selected ? 1.0 : (wsTile.occupied ? 0.6 : 0.35)

          x: root.expandedX(wsTile.wsId)
          y: root.barHeight + root.shelfPadding + root.contentOffset
          width: root.expandedW(wsTile.wsId)
          height: root.tileHeight
          radius: root.tileRadius
          opacity: root.reveal * (wsTile.dimmed ? 0.42 : 1.0)
          color: wsTile.occupied
            ? Util.alpha(root.shelfText, wsTile.selected ? 0.10 : 0.045)
            : "transparent"

          Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.width: wsTile.selected
              ? (root.focusRegion === "shelf" ? Math.max(1, Style.space(2))
                                              : Math.max(1, Style.space(1)))
              : (wsTile.occupied ? 0 : Math.max(1, Style.space(1)))
            border.color: wsTile.selected
              ? (root.focusRegion === "shelf" ? root.accent : Util.alpha(root.accent, 0.45))
              : Util.alpha(root.shelfText, 0.18)
          }

          // ------------------------------------------------- board header
          //
          // Drawn in the bar's own font at the bar's size: the shelf is meant
          // to read as the bar having grown, and a different typeface at the
          // handoff would give that away even through a fade.
          Item {
            id: tileHeader
            anchors { top: parent.top; left: parent.left; right: parent.right }
            anchors.leftMargin: root.tilePadding
            anchors.rightMargin: root.tilePadding
            height: root.tilePadding * 2 + root.tileHeaderHeight

            Row {
              anchors.left: parent.left
              anchors.right: badge.visible ? badge.left : parent.right
              anchors.rightMargin: badge.visible ? Style.space(4) : 0
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                textFormat: Text.PlainText
                text: String(wsTile.wsId)
                color: Util.alpha(root.shelfText, wsTile.tone)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.body
              }

              Item {
                width: root.glyph(wsTile.modelData.icon) !== "" ? Style.spaceReal(2) : 0
                height: 1
              }

              Text {
                visible: root.glyph(wsTile.modelData.icon) !== ""
                text: root.glyph(wsTile.modelData.icon)
                color: Util.alpha(root.shelfText, wsTile.tone)
                font.family: phosphor.font.family
                font.pixelSize: Style.bar.iconFont
              }

              Item {
                width: wsTile.modelData.name !== "" ? Style.spaceReal(1.5) : 0
                height: 1
              }

              Text {
                textFormat: Text.PlainText
                width: Math.max(0, tileHeader.width - Style.space(30)
                  - (badge.visible ? badge.width + Style.space(4) : 0))
                text: wsTile.modelData.name
                color: Util.alpha(root.shelfText, wsTile.tone)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
            }

            // How many of this workspace's windows answer the query. Only ever
            // drawn while a query is live.
            Rectangle {
              id: badge
              visible: root.query.length > 0 && wsTile.matchCount > 0
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: badgeText.implicitWidth + Style.space(8)
              height: Style.space(14)
              radius: Math.max(1, Style.space(4))
              color: root.accent
              Text {
                id: badgeText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: String(wsTile.matchCount)
                color: root.panelBackground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
            }
          }

          // ------------------------------------------------------- board
          //
          // A miniature of the screen: the board carries the usable area's
          // aspect ratio, and every window sits at its real fraction of that
          // area, so a master/stack split looks like a master/stack split.
          Item {
            id: board
            anchors { top: tileHeader.bottom; left: parent.left; right: parent.right }
            anchors.leftMargin: root.tilePadding
            anchors.rightMargin: root.tilePadding
            height: root.boardHeight
            clip: true
            visible: wsTile.occupied

            Repeater {
              model: wsTile.modelData.windows

              delegate: Item {
                id: cell
                required property var modelData

                readonly property bool hit: root.query.length === 0
                  || root.matchesWindow(cell.modelData)

                x: Math.round(cell.modelData.fx * board.width)
                y: Math.round(cell.modelData.fy * board.height)
                width: Math.max(Style.space(10),
                  Math.round(cell.modelData.fw * board.width) - 1)
                height: Math.max(Style.space(10),
                  Math.round(cell.modelData.fh * board.height) - 1)
                clip: true
                opacity: cell.hit ? 1.0 : 0.22

                Rectangle {
                  anchors.fill: parent
                  radius: root.cellRadius
                  color: root.panelBackground
                }

                // Live capture of the real window, including windows on
                // workspaces that are not currently visible -- which is the
                // case this whole design rests on. `live` follows the shelf's
                // own visibility so nothing streams while it is closed.
                // captureSource wants the Wayland Toplevel, which
                // HyprlandToplevel hands over already joined to its address.
                ScreencopyView {
                  id: shot
                  captureSource: root.windowVisible ? cell.modelData.toplevel.wayland : null
                  // Live only for the moment it takes to fill in, then frozen.
                  // Nine continuously-streaming views cost the shell ~16% of a
                  // core for as long as the shelf is up (measured); a shelf is
                  // a glance, and a picture that stops moving after the first
                  // frame is not one anybody can pick out. captureFrame() on
                  // its own is not an alternative -- called before the capture
                  // session exists it just warns "no recording context is
                  // ready" and returns nothing, and there is no signal for
                  // when that becomes true.
                  live: root.windowVisible && root.priming
                  paintCursor: false
                  // Cover, anchored top-left. ScreencopyView preserves the
                  // source aspect inside its own bounds, so handing it the
                  // source's aspect ratio and clipping is what produces a
                  // real "cover" rather than a letterbox.
                  readonly property real ar: shot.sourceSize.height > 0
                    ? (shot.sourceSize.width / shot.sourceSize.height)
                    : Math.max(0.1, (cell.modelData.fw * root.usableWidth)
                        / Math.max(1, cell.modelData.fh * root.usableHeight))
                  x: 0
                  y: 0
                  width: Math.max(cell.width, cell.height * shot.ar)
                  height: Math.max(cell.height, cell.width / shot.ar)
                }

                // The app name sits on the thumbnail in a small opaque chip.
                // No gradient scrim: it would grey out the top of every
                // window, which is exactly the part that identifies it.
                Rectangle {
                  anchors.centerIn: parent
                  width: Math.min(parent.width - Style.space(4),
                                  chipText.implicitWidth + Style.space(10))
                  height: chipText.implicitHeight + Style.space(3)
                  radius: Math.max(1, Style.space(3))
                  color: root.panelBackground
                  Text {
                    id: chipText
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - Style.space(6))
                    textFormat: Text.PlainText
                    text: cell.modelData.app
                    color: root.panelText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                  }
                }
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            enabled: root.reveal > 0.9
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            id: tileMouse
            onEntered: root.hoverTile(wsTile.wsId)
            onPositionChanged: function(mouse) {
              if (!root.pointerMoved(tileMouse, mouse)) return
              root.pointerLive = true
              root.hoverTile(wsTile.wsId)
            }
            onClicked: root.pickTile(wsTile.wsId)
          }
        }
      }
    }

    // ------------------------------------------------------------- panel

    Rectangle {
      id: panelSurface
      y: shelfSurface.height
      anchors { left: parent.left; right: parent.right }
      height: root.panelHeight
      color: root.panelBackground
      opacity: root.reveal
      clip: true

      // Query line. There is no visible field until something is typed -- the
      // shelf itself is the affordance, and an empty search box on a surface
      // that is mostly pictures reads as clutter.
      Item {
        id: queryBar
        anchors { top: parent.top; left: parent.left; right: parent.right }
        anchors.leftMargin: root.panelPadding
        anchors.rightMargin: root.panelPadding
        height: root.query.length > 0 ? root.queryBarHeight : 0
        visible: height > 0

        Text {
          id: queryText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.query + "▮"
          color: root.panelText
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: queryText.right
          anchors.leftMargin: Style.space(10)
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: {
            var w = 0, c = 0, h = 0
            for (var i = 0; i < root.rows.length; i++) {
              if (root.rows[i].kind === "window") w++
              else if (root.rows[i].kind === "conversation") c++
              else if (root.rows[i].kind === "history") h++
            }
            return w + (w === 1 ? " window · " : " windows · ")
              + c + (c === 1 ? " conversation · " : " conversations · ")
              + h + (h === 1 ? " link" : " links")
          }
          color: Util.alpha(root.panelText, 0.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }

      // The pinned query action. Always present with something typed, always
      // on screen, never scrolled: with no address bar left, "do what I typed"
      // cannot be a row you have to go looking for.
      Item {
        id: actionRow
        anchors { top: queryBar.bottom; left: parent.left; right: parent.right }
        height: root.queryAction ? root.rowHeight : 0
        visible: height > 0

        readonly property bool hasCursor: root.activeRegion === "action"
        readonly property color fg: actionRow.hasCursor ? root.selectedText : root.panelText

        Rectangle {
          anchors.fill: parent
          anchors.leftMargin: Style.space(5)
          anchors.rightMargin: Style.space(5)
          visible: actionRow.hasCursor
          radius: Math.max(Style.space(5), Style.cornerRadius)
          color: root.selectedBackground
        }

        Item {
          anchors.fill: parent
          anchors.leftMargin: root.panelPadding + Style.space(5)
          anchors.rightMargin: root.panelPadding + Style.space(5)

          Text {
            id: actionIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(16)
            text: root.glyph(!root.queryAction ? "magnifying-glass"
              : root.queryAction.kind === "open" ? "arrow-up-right"
              : root.queryAction.kind === "window" ? "browser" : "magnifying-glass")
            color: root.accent
            font.family: phosphor.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            id: actionKind
            anchors.left: actionIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(92)
            textFormat: Text.PlainText
            // "Open", or the name of the engine this will actually use --
            // read from Chrome, so a switch to DuckDuckGo shows up here.
            text: root.queryAction ? root.queryAction.engine : ""
            color: Util.alpha(actionRow.fg, 0.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            anchors.left: actionKind.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.queryAction ? root.queryAction.label : ""
            color: actionRow.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }

        MouseArea {
          id: actionMouse
          anchors.fill: parent
          enabled: actionRow.visible
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: if (root.pointerLive) root.focusRegion = "action"
          onPositionChanged: function(mouse) {
            if (!root.pointerMoved(actionMouse, mouse)) return
            root.pointerLive = true
            root.focusRegion = "action"
          }
          onClicked: {
            root.pointerLive = true
            root.focusRegion = "action"
            root.activateCurrent()
          }
        }
      }

      Text {
        visible: root.rows.length === 0
        anchors { top: actionRow.bottom; left: parent.left; right: parent.right }
        anchors.leftMargin: root.panelPadding
        anchors.rightMargin: root.panelPadding
        anchors.topMargin: Style.spacing.md
        textFormat: Text.PlainText
        text: root.query.length > 0 ? ("No matches for “" + root.query + "”")
                                    : "Nothing here yet"
        color: Util.alpha(root.panelText, 0.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      ListView {
        id: listView
        anchors { top: actionRow.bottom; left: parent.left; right: parent.right
                  bottom: footer.top }
        anchors.topMargin: Style.spacing.sm
        anchors.leftMargin: Style.space(5)
        anchors.rightMargin: Style.space(5)
        clip: true
        spacing: 0
        model: root.rows

        delegate: Item {
          id: rowRoot
          required property int index
          required property var modelData

          readonly property bool isSection: rowRoot.modelData.kind === "section"
          readonly property bool isWindow: rowRoot.modelData.kind === "window"
          readonly property bool isConversation: rowRoot.modelData.kind === "conversation"
          readonly property bool isHistory: rowRoot.modelData.kind === "history"
          readonly property bool hasCursor: !rowRoot.isSection
            && root.selectableRows[root.cursor] === rowRoot.index

          width: listView.width
          height: rowRoot.isSection ? root.sectionHeight : root.rowHeight

          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: Style.space(5)
            anchors.rightMargin: Style.space(5)
            visible: rowRoot.hasCursor
            radius: Math.max(Style.space(5), Style.cornerRadius)
            color: root.selectedBackground
            // Where Enter will land once you arrow down, but not where it
            // lands now.
            opacity: root.focusRegion === "panel" ? 1.0 : 0.35
          }

          Text {
            visible: rowRoot.isSection
            anchors.left: parent.left
            anchors.leftMargin: root.panelPadding
            anchors.right: parent.right
            anchors.rightMargin: root.panelPadding
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(3)
            textFormat: Text.PlainText
            text: rowRoot.isSection ? rowRoot.modelData.label : ""
            color: Util.alpha(root.panelText, 0.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.capitalization: Font.AllUppercase
            elide: Text.ElideRight
          }

          // ---- result row: mark | app | subject | context | ws | age

          Item {
            id: rowBody
            visible: !rowRoot.isSection
            anchors.fill: parent
            anchors.leftMargin: root.panelPadding
            anchors.rightMargin: root.panelPadding

            readonly property color fg: (rowRoot.hasCursor && root.focusRegion === "panel")
              ? root.selectedText : root.panelText

            Text {
              id: rowIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16)
              // Windows carry the app identity in their name; the two index
              // tiers are distinguished by kind alone, so they get the marks
              // Triage.qml already uses for them.
              text: root.glyph(rowRoot.isConversation ? "chat-circle"
                : rowRoot.isHistory ? "globe" : "app-window")
              color: root.accent
              font.family: phosphor.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              id: rowApp
              anchors.left: rowIcon.right
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(92)
              textFormat: Text.PlainText
              text: rowRoot.isWindow ? rowRoot.modelData.window.app
                : rowRoot.isConversation ? "Claude Code"
                : rowRoot.isHistory ? (rowRoot.modelData.history.app
                    || rowRoot.modelData.history.domain || "") : ""
              color: Util.alpha(rowBody.fg, 0.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              id: rowAge
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(40)
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: {
                var now = Date.now() / 1000
                if (rowRoot.isWindow) return Omnibox.age(rowRoot.modelData.window.lastFocus, now)
                if (rowRoot.isConversation) return Omnibox.age(rowRoot.modelData.conversation.mtime, now)
                if (rowRoot.isHistory) return Omnibox.age(rowRoot.modelData.history.lastVisit, now)
                return ""
              }
              color: Util.alpha(rowBody.fg, 0.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              id: rowWs
              anchors.right: rowAge.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18)
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              // A window says which workspace it is on; a history row says
              // which account(s) it has been seen in -- initials, because the
              // column is narrow and the directory name is unspeakable. It is
              // NOT where Enter will open it: that is the key's decision, and
              // the footer states it.
              text: rowRoot.isWindow ? String(rowRoot.modelData.window.workspace)
                : rowRoot.isHistory ? (Omnibox.profileMark(rowRoot.modelData.history) || "—")
                : "—"
              color: Util.alpha(rowBody.fg, 0.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              id: rowContext
              anchors.right: rowWs.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: rowRoot.isWindow ? (rowRoot.modelData.window.context
                    || rowRoot.modelData.window.host || "")
                : rowRoot.isConversation ? (rowRoot.modelData.conversation.messages
                    ? rowRoot.modelData.conversation.messages + " msgs" : "")
                : rowRoot.isHistory ? (rowRoot.modelData.history.domain || "") : ""
              color: Util.alpha(rowBody.fg, 0.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: Math.min(implicitWidth, Style.space(180))
            }

            Text {
              anchors.left: rowApp.right
              anchors.leftMargin: Style.space(10)
              anchors.right: rowContext.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: rowRoot.isWindow ? rowRoot.modelData.window.subject
                : rowRoot.isConversation ? rowRoot.modelData.conversation.title
                : rowRoot.isHistory ? rowRoot.modelData.history.title : ""
              color: rowBody.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }

          MouseArea {
            anchors.fill: parent
            visible: !rowRoot.isSection
            enabled: !rowRoot.isSection
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // Same rule as Triage.qml: a row sliding under a stationary
            // pointer as the results refilter must not steal the selection
            // from the keyboard.
            id: rowMouse
            onEntered: if (root.pointerLive) root.selectRow(rowRoot.index)
            onPositionChanged: function(mouse) {
              if (!root.pointerMoved(rowMouse, mouse)) return
              root.pointerLive = true
              root.selectRow(rowRoot.index)
            }
            onClicked: {
              root.pointerLive = true
              root.selectRow(rowRoot.index)
              root.activateCurrent()
            }
          }
        }
      }

      Item {
        id: footer
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        anchors.leftMargin: root.panelPadding
        anchors.rightMargin: root.panelPadding
        height: root.footerHeight

        Text {
          anchors.fill: parent
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: {
            var hint = "⇥ workspace    ↑↓ item    " + root.enterHint()
            if (root.query.length > 0) {
              // Only meaningful with something typed, and only for the chords
              // actually discovered on this machine.
              var parts = []
              if (root.launchChords.terminal)
                parts.push(root.launchChords.terminal.label + " terminal")
              if (root.launchChords.browser)
                parts.push(root.launchChords.browser.label + " browser")
              if (root.launchChords.agent)
                parts.push(root.launchChords.agent.label + " agent")
              if (parts.length > 0) hint += "    " + parts.join(" · ")
            }
            return hint + "    ⇧⌘1-9 send there    esc "
              + (root.query.length > 0 ? "clear" : "collapse")
          }
          color: Util.alpha(root.panelText, 0.45)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }
}
