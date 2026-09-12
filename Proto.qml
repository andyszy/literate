import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Ui
import "Omnibox.js" as Omnibox

// The omnibox as a REAL TILED WINDOW rather than an overlay, so that where it
// lands IS the preview of where the window you are about to open will land.
// Summoned with `omarchy-shell shell summon literate
// '{"mode":"proto","target":"new"}'`.
//
// Why this can work at all, and why nothing else here can:
//
// - A layer-shell surface CANNOT tile. Everything else this plugin draws
//   (Overlay.qml's card, Triage.qml inside it, Shelf.qml) is a layer surface,
//   and the compositor keeps those out of the layout by definition. A real XDG
//   toplevel tiles, and Quickshell gives us one as `FloatingWindow` -- the same
//   type /usr/share/omarchy/shell/plugins/dev-gallery/GalleryPanel.qml uses.
// - Hyprland's dwindle layout splits THE FOCUSED WINDOW. So a toplevel opened
//   while window W has focus takes half of W -- which is exactly the half the
//   NEXT window would have taken. The placement is the preview; nothing is
//   simulated.
// - Verified on a scratch workspace: open a proto, close it, and open something
//   else while focus has returned to the same parent, and the new window lands
//   in the byte-identical slot. But if focus moves elsewhere in between, it
//   lands somewhere completely different and the preview has lied. Hence
//   `parentAddress`: the window that was focused at the moment the proto
//   opened is recorded, and refocused explicitly before anything is launched.
//   Scrambling focus deliberately in between does not disturb the result.
//
// Two things about the window itself are constraints rather than choices:
//
// - IT HAS NO APP-ID OF ITS OWN. Quickshell sets the Wayland app_id once for
//   the whole process ("org.quickshell"); FloatingWindowInterface exposes
//   title/minimumSize/maximumSize/minimized/maximized/fullscreen/parentWindow
//   and nothing else. So the proto's distinctive identity is its TITLE, which
//   Hyprland records before the surface is mapped (it reports it as
//   `initialTitle`) -- but NOT before it evaluates window rules, so a title
//   rule never fires on it at all. Only a class rule can reach this window.
//   See ~/.config/hypr/literate-omnibox.lua, and CLAUDE.md.
// - IT IS A REAL WINDOW, so it shows up in window lists -- including our own.
//   `org.quickshell` is in the daemon's `ignore_classes`, which keeps it out of
//   --triage, out of the naming prompt, and out of anything else built on
//   _filtered_clients().
//
// Not a manifest entry point, for the same reason Triage.qml and Shelf.qml are
// not: shell.qml's computePanelEntries() builds one panel/overlay/menu Loader
// per plugin id, so a second kind would silently displace entryPoints.overlay.
// Overlay.qml instantiates this and routes {"mode":"proto"} to it, and this
// file must stay in tools/sync-upstream's --exclude list.
Item {
  id: root

  // Set by Overlay.qml, which resolves its own plugin directory. Not
  // host-injected, so no plain-vs-required concern here.
  property string binPath: ""

  signal closeRequested()

  // --------------------------------------------------------------- identity
  //
  // Two titles. Not for the compositor -- no rule can match on them (see the
  // header) -- but because everything that reads a window list reads titles,
  // and "Literate omnibox" is how this surface is recognised: by resolveSelf()
  // finding our own toplevel, and by settle() telling our own window from
  // somebody else's. Both begin "Literate omnibox".
  readonly property string tiledTitle: "Literate omnibox"
  readonly property string replaceTitle: "Literate omnibox replacing this window"

  // Assigned by open() BEFORE the window is shown, never after: Hyprland
  // freezes `initialTitle` at map, and that is what the rules see.
  property string windowTitle: root.tiledTitle

  // ------------------------------------------------------------------ state

  property bool opened: false

  // "new": join the layout, and the slot taken IS the preview.
  // "current": replace the window that had focus, so the proto is NOT joining
  // the layout -- it floats over that window instead.
  property string target: "new"

  // The window that was focused when the proto opened: the one dwindle split
  // to make room, i.e. the parent whose slot the preview is showing. Refocused
  // before launching anything, which is the whole reason the preview is honest.
  // Empty means there was nothing focused (an empty workspace), in which case
  // there is nothing to refocus and the launch is unconditioned anyway.
  property string parentAddress: ""
  property string parentClass: ""
  property string parentTitle: ""
  property var parentAt: null     // [x, y] logical, for the floating placement
  property var parentSize: null   // [w, h] logical

  // Our own window, once the compositor has mapped it. "0x"-prefixed, the
  // spelling hyprctl and the daemon both use.
  property string protoAddress: ""
  // Whether the proto has ever actually held focus. Arms the dismiss rule --
  // see settle().
  property bool everFocused: false
  // The workspace the proto is SUPPOSED to be on. Not read back from the
  // compositor: a follow dispatch settles asynchronously, and comparing the
  // live workspace against a value that is still catching up would follow
  // twice. followTo() moves this first and the window afterwards.
  property int homeWorkspace: -1

  // Only the replace mode floats, and only when there is really something to
  // replace -- a terminal cannot be navigated, so that case falls back to
  // opening a window, and a preview of opening a window has to be the tiled
  // slot. See canReplace.
  readonly property bool floatingMode: root.target === "current" && root.canReplace

  function isBrowserClass(cls) {
    var c = String(cls || "").toLowerCase()
    // "google-chrome" is a tabbed window; "chrome-<host>__<path>-<Profile>" is
    // an app-mode one. Same test as Triage.qml's.
    return c === "google-chrome" || c === "chromium" || c === "google-chrome-stable"
      || c.indexOf("chrome-") === 0 || c.indexOf("google-chrome") === 0
  }

  readonly property bool canReplace: root.target === "current"
    && root.isBrowserClass(root.parentClass)

  // ---------------------------------------------------------------- query

  property string query: ""
  property bool pointerLive: false
  property int cursor: 0
  property bool actionFocused: false
  readonly property bool actionActive: root.actionFocused
    || root.selectableRows.length === 0

  function setQuery(text) {
    if (root.query === text) return
    root.query = text
    root.pointerLive = false
    root.cursor = 0
    // A query that is already a location is not a search for anything: the
    // pinned row IS the answer, so it takes the cursor on arrival. Same rule
    // as Triage.qml and Shelf.qml, for the same reason.
    var action = Omnibox.urlOrSearch(text, root.searchEngine)
    root.actionFocused = !!(action && action.kind === "open")
  }

  // ------------------------------------------------------------- lifecycle

  // The payload is {"mode":"proto","target":"new"|"current","query":..,
  // "profile":..}. Absent keys keep the defaults.
  //
  // The window is NOT shown here. Whatever has focus right now is the parent
  // whose slot the preview will show, and once the proto is mapped it is
  // itself the focused window -- so the parent has to be read first, and the
  // window shown from the reply. That one hyprctl call is far cheaper than the
  // map it precedes.
  function open(payload) {
    var p = payload || ({})
    root.opened = true
    root.target = (String(p.target || "") === "current") ? "current" : "new"
    root.parentAddress = ""
    root.parentClass = ""
    root.parentTitle = ""
    root.parentAt = null
    root.parentSize = null
    root.protoAddress = ""
    root.everFocused = false
    root.homeWorkspace = -1
    root.pendingLaunch = null
    root.armProfile(p.profile)
    root.cursor = 0
    root.query = ""
    root.actionFocused = false
    if (p.query) root.setQuery(String(p.query))

    activeProc.command = ["hyprctl", "-j", "activewindow"]
    activeProc.running = true
  }

  // Reached from activeProc once the parent is known: decide the title (which
  // decides whether the compositor floats us), then map.
  function show() {
    if (!root.opened) return
    root.windowTitle = root.floatingMode ? root.replaceTitle : root.tiledTitle
    var ws = Hyprland.focusedWorkspace ? Number(Hyprland.focusedWorkspace.id) : -1
    root.homeWorkspace = ws
    window.visible = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Teardown only. A pending launch deliberately SURVIVES this: by the time
  // one exists the user has already pressed Enter, and Overlay.qml calling
  // close() on the way out must not swallow the thing they asked for.
  function close() {
    root.opened = false
    settleTimer.stop()
    window.visible = false
  }

  // Escape, focus lost, workspace left in replace mode: all the same exit.
  // Closing the window is all that is needed to put the layout back -- dwindle
  // reflows on its own, which is the other half of why a real window is the
  // right surface for this.
  function dismiss() {
    root.close()
    root.closeRequested()
  }

  // -------------------------------------------------- follow vs. dismiss
  //
  // THE CONFLICT: a workspace switch is also a focus loss, so "dismiss when
  // focus leaves" and "follow the user to the new workspace" fight, and naive
  // handling means SUPER+3 kills the proto instead of bringing it along.
  //
  // Measured, on this machine, with both signals logged against a wall clock:
  //
  //   click away, same workspace  ->  activeToplevel changes, ~2 ms after the
  //                                   action; focusedWorkspace does NOT.
  //   switch to an OCCUPIED ws    ->  both change, 1 ms apart, and the FOCUS
  //                                   LOSS ARRIVES FIRST. This is the race.
  //   switch to an EMPTY ws       ->  only focusedWorkspace changes.
  //                                   activeToplevel stays stale, because
  //                                   Hyprland's activewindowv2 carries an
  //                                   empty payload and Quickshell ignores it.
  //
  // So neither signal alone is enough: the follow has to be driven off the
  // workspace change as well (the empty case emits nothing else), and the
  // dismiss has to be deferred past the 1 ms window in which a workspace
  // switch looks exactly like a click away.
  //
  // 150 ms is the defer. Two orders of magnitude above the 1 ms gap the race
  // actually needs, so jitter cannot misfire it, and still under the ~200 ms
  // at which a dismissal stops reading as immediate -- and a dismissal is the
  // one thing here whose latency nobody is waiting on, since the surface is
  // already on its way out.
  readonly property int settleMs: 150

  function scheduleSettle() {
    if (!root.opened) return
    settleTimer.restart()
  }

  function settle() {
    if (!root.opened) return
    // Nothing to lose until something has been had. The proto is created and
    // THEN mapped and focused, so for the first frames of its life the focused
    // window is legitimately still the parent -- and a dismiss rule that does
    // not know that closes the surface ~150 ms after it opens, every time.
    if (!root.everFocused) return
    var ws = Hyprland.focusedWorkspace ? Number(Hyprland.focusedWorkspace.id) : -1

    if (ws >= 1 && ws !== root.homeWorkspace) {
      // The user changed their mind about where the thing should go.
      //
      // ...except in replace mode, where there is nothing over here to
      // replace: the window this proto is floating over is back on the other
      // workspace. Following would leave it pointing at a window the user is
      // no longer looking at, which is worse than closing.
      if (root.floatingMode) { root.dismiss(); return }
      root.followTo(ws)
      return
    }

    // Same workspace, so a focus change really was the user clicking away.
    //
    // Judged on the TITLE, not on our address: the address is resolved from
    // Hyprland's toplevel list, which fills asynchronously, so for the first
    // moments of the proto's life we do not know our own address -- and an
    // address test written the obvious way then reads "the focused window is
    // not me" and closes the proto ~150 ms after it opened, every time. (That
    // is not hypothetical; it is what this did first.) The title is exact,
    // distinctive, and known before the surface is ever committed.
    //
    // A null activeToplevel is not evidence either: it means focus reached
    // nothing we can name, and we wait for a signal that says something.
    var t = Hyprland.activeToplevel
    if (!t) return
    if (String(t.title) !== root.windowTitle) root.dismiss()
  }

  // Bring the proto to the workspace the user just went to, and re-record the
  // parent there. The bookkeeping MUST be redone: the proto arriving on a new
  // workspace splits whatever is focused THERE, so the old parentAddress
  // describes a slot on a workspace nobody is looking at any more. (Verified:
  // the same proto moved to an empty workspace took the whole area, and moving
  // it back landed it in a different slot than the one it had originally.)
  //
  // Read the parent first, for the same reason open() does: the proto is not
  // on this workspace yet, so activewindow is exactly the window it is about
  // to split.
  function followTo(ws) {
    root.homeWorkspace = ws
    followProc.command = ["hyprctl", "-j", "activewindow"]
    followProc.running = true
  }

  function finishFollow() {
    if (!root.opened || !root.protoAddress) return
    // follow = false: the user is ALREADY on the new workspace, they walked
    // here themselves. follow = true would be a second switch to where they
    // already are.
    var dispatches = [
      'dispatch hl.dsp.window.move({ workspace = "' + root.homeWorkspace
        + '", follow = false, window = "address:' + root.protoAddress + '" })',
      'dispatch hl.dsp.focus({ window = "address:' + root.protoAddress + '" })'
    ]
    moveProc.command = ["hyprctl", "--batch", dispatches.join(" ; ")]
    moveProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ------------------------------------------------------- our own window
  //
  // The join CLAUDE.md documents: HyprlandToplevel carries both `address` (for
  // the daemon's data and for dispatches) and `wayland`, and `lastIpcObject`
  // is the whole `hyprctl -j clients` record. We only need the address, and we
  // find ourselves by appId + exact title -- never by "whichever window has
  // focus", which is usually the user's.
  function resolveSelf() {
    if (!root.opened || root.protoAddress) return
    var tls = (Hyprland.toplevels && Hyprland.toplevels.values)
      ? Hyprland.toplevels.values : []
    for (var i = 0; i < tls.length; i++) {
      var t = tls[i]
      if (!t || String(t.title) !== root.windowTitle) continue
      // HyprlandToplevel has NO `appId` -- it reads `undefined`, and a filter
      // written on it rejects every row silently (which is exactly what this
      // did: the proto was in the list the whole time and never found itself,
      // so it could neither follow a workspace change nor be moved at all).
      // The class lives in lastIpcObject, the raw `hyprctl -j clients` record.
      var io = t.lastIpcObject || ({})
      if (io.class !== undefined && String(io.class) !== "org.quickshell") continue
      root.protoAddress = "0x" + Omnibox.normalizeAddress(t.address)
      if (t.workspace) root.homeWorkspace = Number(t.workspace.id)
      root.placeIfFloating()
      return
    }
  }

  // "Replace this window" is not joining the layout, so this proto floats over
  // the window it is replacing, on that window's exact geometry -- which was
  // READ from the parent, never taken by mutating it.
  //
  // It floats ITSELF, rather than being floated by a window rule, and that is
  // forced. A rule would have to tell the two modes apart at map time, and the
  // proto has nothing distinctive at map time: Quickshell gives the whole
  // process one app_id, and a Quickshell window's TITLE reaches the compositor
  // after the rules have already run (verified against a foot window with the
  // same `initial_title` rule, which floats; this one does not, while
  // `hyprctl clients` still reports the expected initialTitle afterwards, so
  // it reads like a rule that should have matched).
  //
  // The cost is honest and worth stating: the window maps TILED for the frame
  // or two before this lands, so the layout reflows out and back. Only the
  // replace mode pays it, and the replace mode is the one whose placement is
  // not a preview of anything.
  function placeIfFloating() {
    if (!root.floatingMode || !root.protoAddress) return
    if (!root.parentAt || !root.parentSize) return
    var dispatches = [
      // action = "on", not a bare toggle: this runs off a signal that can
      // arrive more than once, and a toggle would tile it again.
      'dispatch hl.dsp.window.float({ action = "on", window = "address:'
        + root.protoAddress + '" })',
      // SIZE BEFORE POSITION. hl.dsp.window.resize keeps the window's CENTRE,
      // so resizing after moving drags the window off the point it was just
      // put on -- by half the size change, which for a full-height window is
      // most of a screen (measured: asked for x=14, landed at x=-164).
      'dispatch hl.dsp.window.resize({ x = ' + Math.round(root.parentSize[0])
        + ', y = ' + Math.round(root.parentSize[1])
        + ', window = "address:' + root.protoAddress + '" })',
      'dispatch hl.dsp.window.move({ x = ' + Math.round(root.parentAt[0])
        + ', y = ' + Math.round(root.parentAt[1])
        + ', window = "address:' + root.protoAddress + '" })'
    ]
    placeProc.command = ["hyprctl", "--batch", dispatches.join(" ; ")]
    placeProc.running = true
  }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      var t = Hyprland.activeToplevel
      if (t && String(t.title) === root.windowTitle) root.everFocused = true
      root.scheduleSettle()
    }
    function onFocusedWorkspaceChanged() { root.scheduleSettle() }
  }

  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() {
      if (!root.opened) { root.checkLaunchReady(); return }
      root.resolveSelf()
    }
  }

  Timer {
    id: settleTimer
    interval: root.settleMs
    repeat: false
    onTriggered: root.settle()
  }

  // The toplevel list fills asynchronously and a map is not a signal we get
  // told about directly, so back the Connections above with a short poll that
  // stops the moment we have found ourselves.
  Timer {
    id: resolveTimer
    interval: 60
    repeat: true
    running: root.opened && root.protoAddress === ""
    onTriggered: {
      Hyprland.refreshToplevels()
      root.resolveSelf()
    }
  }

  // ---------------------------------------------------------------- launch
  //
  // ON ENTER: close the proto, refocus the RECORDED PARENT, and only then
  // launch. That order is the verified fix -- the parent is what dwindle will
  // split, and anything else having focus at that moment puts the real window
  // somewhere the preview never showed.
  //
  // The wait is on the window actually being GONE, not on a guessed delay: the
  // proto is still in the layout until the compositor has unmapped it, and
  // launching before then would have the new window split the proto's slot
  // rather than reclaim it. Hyprland.toplevels losing our address is that
  // signal, with a timer as the backstop in case it never arrives.
  property var pendingLaunch: null
  // Whether this particular action cares where the proto's slot was. Launching
  // something does; focusing a window that already exists does not, and making
  // it wait on a refocus it has no use for only adds a hop.
  property bool pendingNeedsParent: false
  property var afterParentFocus: null

  function runAfterClose(fn, needsParent) {
    root.pendingLaunch = fn
    root.pendingNeedsParent = !!needsParent
    launchFallbackTimer.restart()
    root.close()
    // Tell Overlay.qml, so it drops its own state and resets the submap. Its
    // close() reaches back into ours, which is why close() above leaves the
    // pending launch alone.
    root.closeRequested()
    root.checkLaunchReady()
  }

  function checkLaunchReady() {
    if (!root.pendingLaunch) return
    if (root.protoAddress) {
      var tls = (Hyprland.toplevels && Hyprland.toplevels.values)
        ? Hyprland.toplevels.values : []
      var want = Omnibox.normalizeAddress(root.protoAddress)
      for (var i = 0; i < tls.length; i++)
        if (tls[i] && Omnibox.normalizeAddress(tls[i].address) === want) return
    }
    root.fireLaunch()
  }

  function fireLaunch() {
    var fn = root.pendingLaunch
    root.pendingLaunch = null
    launchFallbackTimer.stop()
    if (!fn) return
    if (!root.pendingNeedsParent || !root.parentAddress) { fn(); return }
    // The refocus has to have LANDED before the launch is spawned, not merely
    // have been started first: two hyprctl processes started back to back are
    // two races, and losing that one puts the new window somewhere the preview
    // never showed. So the launch hangs off the refocus process exiting.
    // (Batching both into one `hyprctl --batch` would be a hop cheaper, but the
    // batch separator is ";" and a launch command carries a user-typed URL.)
    root.afterParentFocus = fn
    parentFocusProc.command = ["hyprctl", "dispatch",
      'hl.dsp.focus({ window = "address:' + root.parentAddress + '" })']
    parentFocusProc.running = true
  }

  Timer {
    id: launchFallbackTimer
    interval: 400
    repeat: false
    onTriggered: root.fireLaunch()
  }

  // ------------------------------------------------------- Chrome profiles
  //
  // THE KEY DECIDES, NEVER THE ROW: Enter opens in the armed profile,
  // Shift+Enter in the next. Same rule and same reason as Triage.qml and
  // Shelf.qml -- a row's recorded profile is an accident of which account
  // loaded the page last, so a rule derived from it sends the same keystroke
  // somewhere different on different days.
  readonly property var chromeProfiles:
    (root.omniboxIndex && Array.isArray(root.omniboxIndex.profiles))
      ? root.omniboxIndex.profiles : []
  property int enterAt: 0
  property int shiftOffset: 1

  function profileAt(i) {
    var n = root.chromeProfiles.length
    return n === 0 ? null : root.chromeProfiles[((i % n) + n) % n]
  }

  readonly property var enterProfile: root.profileAt(root.enterAt)
  readonly property var shiftProfile: root.chromeProfiles.length > 1
    ? root.profileAt(root.enterAt + root.shiftOffset) : null

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

  function cycleShiftProfile() {
    var n = root.chromeProfiles.length
    if (n <= 2) return
    root.shiftOffset = (root.shiftOffset % (n - 1)) + 1
  }

  function profileName(profile) {
    return (profile && profile.name) ? String(profile.name) : ""
  }

  // ------------------------------------------------------------------ rows
  //
  // An address bar, not a second triage: with nothing typed there is only the
  // pinned action, and with something typed the matches arrive as three flat
  // capped tiers. The GROUPING is Triage.qml's job and needs Triage.qml's
  // room; a tile in the layout can be a third of a screen wide.

  readonly property int tierLimit: 5
  readonly property var rows: root.computeRows()

  function matchesQuery(haystack) {
    return String(haystack || "").toLowerCase().indexOf(root.query.toLowerCase()) >= 0
  }

  // Open windows come from the daemon's precomputed triage grouping, which is
  // where app-name resolution already lives: `app` is "Gmail" or "Claude Code"
  // rather than "chrome-gmail.com__-Default", and `subject` is the title with
  // the app/account tail subtracted. Never re-derive either here.
  function matchWindows(q) {
    var wins = (root.cache && Array.isArray(root.cache.windows)) ? root.cache.windows : []
    var out = []
    for (var i = 0; i < wins.length; i++) {
      var w = wins[i]
      if (!w) continue
      if (root.matchesQuery(w.app) || root.matchesQuery(w.subject)
          || root.matchesQuery(w.host) || root.matchesQuery(w.context)
          || root.matchesQuery(w.class) || root.matchesQuery(w.title))
        out.push(w)
    }
    return out
  }

  function computeRows() {
    if (root.query.length === 0) return []
    var out = []
    var wins = root.matchWindows(root.query).slice(0, root.tierLimit)
    if (wins.length > 0) {
      out.push({ kind: "tier", label: "OPEN" })
      for (var i = 0; i < wins.length; i++) out.push({ kind: "window", window: wins[i] })
    }
    var convs = Omnibox.matchConversations(root.query, root.omniboxIndex)
      .slice(0, root.tierLimit)
    if (convs.length > 0) {
      out.push({ kind: "tier", label: "CONVERSATIONS" })
      for (var c = 0; c < convs.length; c++)
        out.push({ kind: "conversation", conversation: convs[c] })
    }
    var hist = Omnibox.matchHistory(root.query, root.omniboxIndex).slice(0, root.tierLimit)
    if (hist.length > 0) {
      out.push({ kind: "tier", label: "HISTORY" })
      for (var h = 0; h < hist.length; h++) out.push({ kind: "history", history: hist[h] })
    }
    return out
  }

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
    return root.rows[sel[Math.max(0, Math.min(root.cursor, sel.length - 1))]]
  }

  function select(delta) {
    var n = root.selectableRows.length
    root.pointerLive = false
    if (root.actionFocused) {
      if (delta > 0 && n > 0) {
        root.actionFocused = false
        root.cursor = 0
        listView.positionViewAtIndex(root.selectableRows[0], ListView.Contain)
      }
      return
    }
    if (n === 0) { root.actionFocused = true; return }
    if (delta < 0 && root.cursor === 0) { root.actionFocused = true; return }
    root.cursor = (root.cursor + delta + n) % n
    listView.positionViewAtIndex(root.selectableRows[root.cursor], ListView.Contain)
  }

  function selectRow(flatIndex) {
    var pos = root.selectableRows.indexOf(flatIndex)
    if (pos >= 0) { root.cursor = pos; root.actionFocused = false }
  }

  // --------------------------------------------------- the typed query row

  readonly property var searchEngine: (root.omniboxIndex && root.omniboxIndex.search)
    ? root.omniboxIndex.search : null
  readonly property var queryAction: Omnibox.urlOrSearch(root.query, root.searchEngine)
    || Omnibox.newWindowAction()

  function actionLabel() {
    var base = root.queryAction ? root.queryAction.label : ""
    if (!base || root.target !== "current" || root.queryAction.kind === "window") return base
    return base + (root.canReplace ? " — navigate this window"
                                   : " — in a new window (nothing to navigate)")
  }

  function opensInBrowser() {
    if (root.actionActive) return true
    var row = root.currentRow()
    return !!(row && row.kind === "history")
  }

  function enterHint() {
    var primary = root.profileName(root.enterProfile)
    var secondary = root.profileName(root.shiftProfile)
    var suffix = (root.chromeProfiles.length > 2) ? " (⌃⇥ next)" : ""
    if (root.opensInBrowser() && root.canReplace)
      return "⏎ navigate this window"
        + (secondary ? "    ⇧⏎ " + secondary + " (new window)" : "")
    if (root.opensInBrowser() && primary)
      return "⏎ " + primary + (secondary ? " · ⇧⏎ " + secondary : "") + suffix
    var row = root.currentRow()
    var verb = (row && row.kind === "conversation") ? "resume" : "focus"
    return "⏎ " + verb
      + (primary ? ("    links ⏎ " + primary
                    + (secondary ? " · ⇧⏎ " + secondary : "") + suffix) : "")
  }

  // --------------------------------------------------------------- actions

  function execCmdDispatch(shellCommand) {
    var lua = shellCommand.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
    return 'hl.dsp.exec_cmd("' + lua + '")'
  }

  function launch(shellCommand) {
    launchProc.command = ["hyprctl", "dispatch", root.execCmdDispatch(shellCommand)]
    launchProc.running = true
  }

  readonly property string commandPath:
    Quickshell.env("HOME") + "/.local/state/literate/chrome-command.json"

  // Ask the Chrome profile that owns the RECORDED PARENT to point it at `url`.
  // Chrome has no command line for "navigate that window" and every profile
  // shares one process and one window class, so the literate-tabs extension is
  // the only thing that can name the window: the command goes to a file
  // (tmp+rename) and the profile holding a window with that title acts.
  //
  // The title is the one recorded at open(), NOT whatever has focus now -- by
  // the time this runs the proto has been and gone, and reading focus again
  // would aim at a different window.
  function navigateParent(url) {
    var now = Date.now()
    var payload = JSON.stringify({ id: now, issuedAt: now / 1000,
      action: "navigate", url: url, title: root.parentTitle })
    commandProc.command = ["sh", "-c",
      'printf %s "$1" > "$2.tmp" && mv "$2.tmp" "$2"', "sh", payload, root.commandPath]
    commandProc.running = true
  }

  // `secondary` is the Shift half of the chord, never a property of the row.
  // Shift+Enter always opens a NEW window even in replace mode: a tab cannot
  // move between Chrome profiles.
  function openUrlInBrowser(url, secondary) {
    if (url && root.canReplace && !secondary) { root.navigateParent(url); return }
    var profile = secondary ? root.shiftProfile : root.enterProfile
    // --app=, never a bare URL. Handing a URL to the already-running Chrome
    // makes it open a TAB in some existing window of that profile and
    // ACTIVATE that window, which on Hyprland drags the user to whatever
    // workspace that window lives on -- so the real window appears nowhere
    // near the slot that was just previewed. Measured from workspace 1 with a
    // Chrome window sitting on workspace 2: the focused workspace flipped to 2
    // within a second and the window landed there; the identical launch with
    // --app= stayed on workspace 1. A fresh process also skips the tile-tabs
    // tab->app conversion altogether, so there is no tab to flicker past.
    var arg = url ? (" --app=" + Util.shellQuote(url)) : " --new-window"
    root.launch((profile && profile.dir)
      ? ("setsid uwsm-app -- google-chrome-stable --profile-directory="
         + Util.shellQuote(profile.dir) + arg)
      : (url ? ("setsid uwsm-app -- google-chrome-stable" + arg)
             : ("omarchy launch browser" + arg)))
  }

  // Claude Code writes the conversation's ai-title into its terminal's window
  // title, so a live window whose stripped title matches the index entry IS
  // that conversation already open -- focus it instead of spawning a duplicate.
  function findOpenClaudeWindow(title) {
    var wins = (root.cache && Array.isArray(root.cache.windows)) ? root.cache.windows : []
    var want = String(title || "")
    if (!want) return null
    for (var i = 0; i < wins.length; i++) {
      var w = wins[i]
      if (!w || String(w.class || "").toLowerCase() !== "org.omarchy.claude") continue
      if (Omnibox.stripStatusGlyphs(w.title) === want) return w
    }
    return null
  }

  function focusAddress(address) {
    focusProc.command = ["hyprctl", "dispatch",
      'hl.dsp.focus({ window = "address:' + address + '" })']
    focusProc.running = true
  }

  // Enter. Everything is decided HERE, while the state is still intact, and
  // handed to runAfterClose() as a closure -- so the ordering (window gone,
  // parent refocused, then launch) is one rule in one place rather than
  // repeated per action.
  function activate(secondary) {
    if (root.actionActive) {
      var url = root.queryAction ? root.queryAction.url : ""
      root.runAfterClose(function() { root.openUrlInBrowser(url, secondary) }, true)
      return
    }
    var row = root.currentRow()
    if (!row) return

    if (row.kind === "history") {
      var hurl = (row.history && row.history.url) ? String(row.history.url) : ""
      if (!hurl) return
      root.runAfterClose(function() { root.openUrlInBrowser(hurl, secondary) }, true)
      return
    }
    if (row.kind === "conversation") {
      var conv = row.conversation
      root.runAfterClose(function() {
        var existing = root.findOpenClaudeWindow(conv ? conv.title : "")
        if (existing && existing.address) { root.focusAddress(existing.address); return }
        root.launch("setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.claude"
          + " --dir=" + Util.shellQuote(conv.project)
          + " -e claude --resume " + Util.shellQuote(conv.id))
      }, true)
      return
    }
    if (row.kind === "window") {
      var addr = (row.window && row.window.address) ? String(row.window.address) : ""
      if (!addr) return
      // Focusing an existing window is not a launch: it does not care where
      // the proto's slot was, so it does not need the parent refocused first.
      // It still has to wait for the proto to be gone, or Hyprland restores
      // focus over the top of it.
      root.runAfterClose(function() { root.focusAddress(addr) }, false)
      return
    }
  }

  // ------------------------------------------------------------------- keys

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      // Clear the filter first, close only once it is already empty -- same as
      // Menu.qml and Triage.qml.
      if (root.query) root.setQuery("")
      else root.dismiss()
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      root.select(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      root.select(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Tab && (event.modifiers & Qt.ControlModifier)) {
      root.cycleShiftProfile()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.activate((event.modifiers & Qt.ShiftModifier) !== 0)
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

  // ------------------------------------------------------------- the submap
  //
  // SUPER+SHIFT+<n> ("move window to workspace") is meaningless for a
  // transient menu: it would fling the proto onto another workspace without
  // the user and leave it there. Shadowing a GLOBAL bind needs a submap, and a
  // submap is exclusive -- while one is active none of the user's other global
  // binds fire either. So the plain SUPER+<n> workspace switch, which rule 4
  // depends on entirely, has to be RE-BOUND inside it.
  //
  // Defined at runtime with a wall-clock generation name, exactly as Shelf.qml
  // does and for the same reason: redefining a submap name APPENDS to it
  // rather than replacing it, and a runtime submap outlives the shell.
  // Keycodes rather than digits, matching omarchy's own binds
  // (`SUPER + code:` .. workspace + 9), so it survives a non-US layout.
  property string submapName: ""

  function luaString(text) {
    return '"' + String(text).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  }

  function defineSubmap() {
    var name = "literate-proto-" + Date.now()
    var lines = ['hl.define_submap(' + root.luaString(name) + ', function()']
    for (var n = 1; n <= 10; n++) {
      var code = "code:" + (n + 9)
      var id = (n === 10) ? "10" : String(n)
      lines.push('  hl.bind("SUPER + ' + code + '", hl.dsp.focus({ workspace = "'
        + id + '" }), { description = "Switch to workspace ' + id + '" })')
      lines.push('  hl.bind("SUPER + SHIFT + ' + code + '", hl.dsp.no_op(), '
        + '{ description = "Ignored while the omnibox is open" })')
    }
    // Safety exit only, and deliberately NOT plain Escape: a submap that
    // swallows Escape makes the surface take two presses to close and kills
    // the client's own "clear the query, then close". See CLAUDE.md.
    lines.push('  hl.bind("SUPER + Escape", hl.dsp.submap("reset"), '
      + '{ description = "Exit omnibox submap" })')
    lines.push('end)')
    submapProc.command = ["hyprctl", "eval", lines.join("\n")]
    submapProc.running = true
    root.submapName = name
  }

  Component.onCompleted: {
    // A hot reload of this plugin (which happens on every edit) hands the new
    // instance the old one's property values, `visible` included -- so a proto
    // that was up when the file changed comes back as a window nobody summoned,
    // mapped before open() has run and therefore without even its title. That
    // is precisely the "never left lying around" case, arriving by a route no
    // user action can produce. Start from closed, always.
    root.opened = false
    window.visible = false
    root.defineSubmap()
  }

  // ------------------------------------------------------------- processes

  Process {
    id: activeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = null
        try { d = JSON.parse(text) } catch (e) { d = null }
        root.parentAddress = (d && d.address) ? String(d.address) : ""
        root.parentClass = (d && d.class) ? String(d.class) : ""
        root.parentTitle = (d && d.title) ? String(d.title) : ""
        root.parentAt = (d && d.at) ? d.at : null
        root.parentSize = (d && d.size) ? d.size : null
        root.show()
      }
    }
  }

  Process {
    id: followProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = null
        try { d = JSON.parse(text) } catch (e) { d = null }
        // Empty on an empty workspace, which is a real answer: there is no
        // parent to split and nothing to refocus on the way out.
        root.parentAddress = (d && d.address) ? String(d.address) : ""
        root.parentClass = (d && d.class) ? String(d.class) : ""
        root.parentTitle = (d && d.title) ? String(d.title) : ""
        root.parentAt = (d && d.at) ? d.at : null
        root.parentSize = (d && d.size) ? d.size : null
        root.finishFollow()
      }
    }
  }

  // A bad dispatch prints to stderr and exits 0, so without these the whole
  // action is a silent no-op with no trace anywhere. Never drop them.
  Process {
    id: moveProc
    stderr: SplitParser {
      onRead: function(l) { if (String(l||"").trim()) console.warn("literate proto move:", l) }
    }
  }
  Process {
    id: placeProc
    stderr: SplitParser {
      onRead: function(l) { if (String(l||"").trim()) console.warn("literate proto place:", l) }
    }
  }
  Process {
    id: focusProc
    stderr: SplitParser {
      onRead: function(l) { if (String(l||"").trim()) console.warn("literate proto focus:", l) }
    }
  }
  // Its own process, not focusProc: the launch runs from this one's onExited,
  // and reassigning a Process from inside its own handler is asking for it.
  Process {
    id: parentFocusProc
    stderr: SplitParser {
      onRead: function(l) { if (String(l||"").trim()) console.warn("literate proto parent focus:", l) }
    }
    onExited: function(exitCode, exitStatus) {
      var fn = root.afterParentFocus
      root.afterParentFocus = null
      if (fn) fn()
    }
  }
  Process {
    id: launchProc
    stderr: SplitParser {
      onRead: function(l) { if (String(l||"").trim()) console.warn("literate proto launch:", l) }
    }
  }
  Process {
    id: commandProc
    stderr: SplitParser {
      onRead: function(l) { if (String(l||"").trim()) console.warn("literate proto command:", l) }
    }
  }
  Process {
    id: submapProc
    stderr: SplitParser {
      onRead: function(l) { if (String(l||"").trim()) console.warn("literate proto submap:", l) }
    }
  }

  // ------------------------------------------------------------------ data
  //
  // Both of these are already parsed before the key is ever pressed, because
  // Overlay.qml is keepLoaded -- which is what lets the first frame be useful.

  property var cache: null

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/literate/triage.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var d = null
      try { d = JSON.parse(text()) } catch (e) { d = null }
      root.cache = (d && Array.isArray(d.windows)) ? d : null
    }
    onLoadFailed: root.cache = null
  }

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

  // -------------------------------------------------------------- phosphor

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    return url.replace(/^file:\/\//, "").replace(/\/+$/, "")
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
  property color background: Color.menu.background
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property string fontFamily: Style.font.menuFamily
  property int rowHeight: Math.max(Style.space(30), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int footerHeight: Style.space(22)
  // Triage.qml's hero input, but sized to the TILE rather than to 60% of the
  // monitor. Triage picks one size because its card is always 60% of the
  // screen; dwindle can hand this window an eighth of it, and the hero has to
  // stay a hero without being clipped -- a placeholder cut off mid-word
  // ("Replace this window w") says less than a smaller one that finishes the
  // sentence. Three steps rather than a continuous scale, so the surface still
  // looks like itself at every size.
  property int inputFontSize: window.width >= Style.space(520) ? Style.font.displayLarge
    : window.width >= Style.space(400) ? Style.font.display
    : Style.font.heading
  property int inputHeight: Math.max(Style.space(44), root.inputFontSize + Style.space(22))

  // ----------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: root.windowTitle
    color: root.background
    // A size REQUEST only: tiled, dwindle decides, and that decision is the
    // whole point. It matters for the floating replace mode, which is then
    // moved and resized onto the window it is replacing.
    implicitWidth: 720
    implicitHeight: 420
    visible: false

    // The user closed it by some other route (a compositor close bind, a
    // crash of the parent). Treat it exactly like Escape.
    onVisibleChanged: if (!visible && root.opened) root.dismiss()

    Item {
      id: keyCatcher
      anchors.fill: parent
      anchors.margins: Style.spacing.md
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.handleKey(event) }

      // Spotlight, in a tile: one large input line with a blinking caret and a
      // placeholder, so the surface says "type here" before anything is typed,
      // and results grow downward from it.
      Item {
        id: searchField
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.inputHeight

        Text {
          id: searchIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.glyph(root.floatingMode ? "arrows-clockwise" : "magnifying-glass")
          color: Util.alpha(root.foreground, 0.35)
          font.family: phosphor.font.family
          font.pixelSize: Style.font.display
        }

        Row {
          anchors.left: searchIcon.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0
          clip: true

          Text {
            textFormat: Text.PlainText
            text: root.query
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.inputFontSize
          }

          Text {
            text: "▮"
            color: Util.alpha(root.foreground, 0.75)
            font.family: root.fontFamily
            font.pixelSize: root.inputFontSize
            SequentialAnimation on opacity {
              running: true
              loops: Animation.Infinite
              NumberAnimation { from: 1.0; to: 0.15; duration: 620; easing.type: Easing.InOutQuad }
              NumberAnimation { from: 0.15; to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.query.length === 0
            leftPadding: Style.space(6)
            text: root.floatingMode ? "Replace with…" : "Search or type a URL"
            color: Util.alpha(root.foreground, 0.38)
            font.family: root.fontFamily
            font.pixelSize: root.inputFontSize
            elide: Text.ElideRight
          }
        }
      }

      Rectangle {
        id: inputRule
        anchors.top: searchField.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(1, Style.spacing.hairline)
        color: Util.alpha(root.foreground, 0.10)
      }

      // The pinned query action: always present, never scrolled. With no
      // address bar left there must be no state in which Enter does nothing
      // with what was typed.
      Item {
        id: actionRow
        anchors.top: inputRule.bottom
        anchors.topMargin: Style.spacing.sm
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.rowHeight

        readonly property bool hasCursor: root.actionActive
        readonly property color fg: actionRow.hasCursor ? root.selectedText : root.foreground

        Rectangle {
          anchors.fill: parent
          visible: actionRow.hasCursor
          radius: Style.cornerRadius
          color: root.selectedBackground
        }

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            text: root.glyph(!root.queryAction ? "magnifying-glass"
              : root.queryAction.kind === "open" ? "arrow-up-right"
              : root.queryAction.kind === "window" ? "browser" : "magnifying-glass")
            color: actionRow.fg
            font.family: phosphor.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width - Style.space(18)
            text: root.actionLabel()
            color: actionRow.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: if (root.pointerLive) root.actionFocused = true
          // onPositionChanged also fires when an item slides under a
          // stationary pointer, which is every keystroke as rows refilter.
          // Only real movement counts. Same guard as Triage.qml's pointerLive.
          onPositionChanged: {
            if (root.pointerLive) return
            root.pointerLive = true
            root.actionFocused = true
          }
          onClicked: {
            root.pointerLive = true
            root.actionFocused = true
            root.activate(false)
          }
        }
      }

      ListView {
        id: listView
        anchors.top: actionRow.bottom
        anchors.topMargin: Style.spacing.xs
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.spacing.xs
        clip: true
        spacing: 0
        model: root.rows

        delegate: Item {
          id: rowRoot
          required property int index
          required property var modelData

          readonly property bool isTier: rowRoot.modelData.kind === "tier"
          readonly property bool hasCursor: !rowRoot.isTier
            && root.selectableRows[root.cursor] === rowRoot.index && !root.actionActive
          readonly property color fg: rowRoot.hasCursor ? root.selectedText : root.foreground

          width: listView.width
          height: rowRoot.isTier ? Style.space(20) : root.rowHeight

          Rectangle {
            anchors.fill: parent
            visible: rowRoot.hasCursor
            radius: Style.cornerRadius
            color: root.selectedBackground
          }

          Text {
            visible: rowRoot.isTier
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: rowRoot.isTier ? rowRoot.modelData.label : ""
            color: Util.alpha(root.foreground, 0.40)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            visible: !rowRoot.isTier
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              text: root.glyph(rowRoot.modelData.kind === "conversation" ? "chat-circle"
                : rowRoot.modelData.kind === "history" ? "clock-counter-clockwise"
                : "app-window")
              color: rowRoot.fg
              opacity: 0.75
              font.family: phosphor.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width - Style.space(26)
              // `app` and `subject` come resolved from the daemon; class and
              // title are the fallback for a record written before that did.
              text: {
                var m = rowRoot.modelData
                if (m.kind === "window") {
                  var w = m.window
                  return "[" + w.workspace + "] " + (w.app || w.class)
                    + ((w.subject || w.title) ? " — " + (w.subject || w.title) : "")
                }
                if (m.kind === "conversation") return String(m.conversation.title || "")
                if (m.kind === "history")
                  return String(m.history.title || m.history.url || "")
                return ""
              }
              color: rowRoot.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }

          MouseArea {
            anchors.fill: parent
            visible: !rowRoot.isTier
            enabled: !rowRoot.isTier
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: if (root.pointerLive) root.selectRow(rowRoot.index)
            onPositionChanged: {
              if (root.pointerLive) return
              root.pointerLive = true
              root.selectRow(rowRoot.index)
            }
            onClicked: {
              root.pointerLive = true
              root.selectRow(rowRoot.index)
              root.activate(false)
            }
          }
        }
      }

      Item {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.footerHeight

        Text {
          anchors.fill: parent
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: "↑↓ item    " + root.enterHint()
            + "    esc " + (root.query.length > 0 ? "clear" : "close")
          color: Util.alpha(root.foreground, 0.45)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }
}
