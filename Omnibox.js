.pragma library

// Query matching over the omnibox index (past Claude Code conversations,
// Chrome history) and the title-normalisation both Triage.qml and Shelf.qml
// need. Extracted from Triage.qml unchanged so the two views cannot drift:
// one ranking rule, one spinner-stripping rule, two callers. Pure functions
// only -- `.pragma library` means there is no QML context here, so every
// input (including the parsed index itself) arrives as an argument.

// Rank helper shared by both index tiers: 0 = query starts the text, 1 =
// query starts a word inside it, 2 = anywhere else, -1 = no match at all.
// Deliberately simple -- plain substring at heart, no fuzzy subsequence
// scoring -- so ordering stays predictable.
function textRank(text, query) {
  var t = String(text || "").toLowerCase()
  var q = query
  if (!q) return -1
  var idx = t.indexOf(q)
  if (idx < 0) return -1
  if (idx === 0) return 0
  return /[^a-z0-9]/i.test(t.charAt(idx - 1)) ? 1 : 2
}

function matchConversations(query, index) {
  var q = String(query || "").toLowerCase()
  var convs = (index && Array.isArray(index.conversations)) ? index.conversations : []
  var matched = []
  for (var i = 0; i < convs.length; i++) {
    var conv = convs[i]
    if (!conv) continue
    var rank = textRank(conv.title, q)
    if (rank < 0) continue
    matched.push({ item: conv, rank: rank })
  }
  matched.sort(function(a, b) {
    if (a.rank !== b.rank) return a.rank - b.rank
    return (Number(b.item.mtime) || 0) - (Number(a.item.mtime) || 0)
  })
  return matched.map(function(m) { return m.item })
}

function matchHistory(query, index) {
  var q = String(query || "").toLowerCase()
  var hist = (index && Array.isArray(index.history)) ? index.history : []
  var matched = []
  for (var i = 0; i < hist.length; i++) {
    var h = hist[i]
    if (!h) continue
    var titleRank = textRank(h.title, q)
    var domainRank = textRank(h.domain, q)
    var rank = -1
    if (titleRank >= 0 && domainRank >= 0) rank = Math.min(titleRank, domainRank)
    else if (titleRank >= 0) rank = titleRank
    else if (domainRank >= 0) rank = domainRank
    if (rank < 0) continue
    matched.push({ item: h, rank: rank })
  }
  matched.sort(compareHistory)
  return matched.map(function(m) { return m.item })
}

// The ranking an ADDRESS BAR needs, which is not the ranking a history search
// needs. Ordered by:
//
//   1. where the query matched  -- prefix, then word start, then mid-string.
//      A match at the front of a domain is a different kind of answer from a
//      match buried in a page title, and no count outranks that.
//   2. typedCount, DOMINANT among the counts. Chrome records how often a URL
//      was reached by someone typing it, and that is the only signal that
//      distinguishes a destination from a page: gmail.com is typed 90 times
//      here, while the most recently loaded page whose title happens to
//      contain "gm" was typed never. Ranking on visits and recency instead
//      (which is what this did) answers "what did I look at", when the
//      question an address bar is asked is "where do I go".
//   3. visits, then last visit, as tiebreakers -- among URLs nobody ever
//      typed, which is most of them, this is exactly the old order.
function compareHistory(a, b) {
  if (a.rank !== b.rank) return a.rank - b.rank
  var byTyped = (Number(b.item.typedCount) || 0) - (Number(a.item.typedCount) || 0)
  if (byTyped !== 0) return byTyped
  var byVisit = (Number(b.item.visits) || 0) - (Number(a.item.visits) || 0)
  if (byVisit !== 0) return byVisit
  return (Number(b.item.lastVisit) || 0) - (Number(a.item.lastVisit) || 0)
}

// ------------------------------------------------------- the typed query
//
// With Chrome's own address bar gone, the text someone typed is itself an
// answer and there must never be a state where Enter does nothing with it.
// These three functions are that answer, and they live here rather than in
// Shelf.qml so the rules are testable without a compositor.

// "" when the query is not a location, otherwise the URL to open. A location
// is a scheme we can hand to a browser, a host with a port (localhost:3000),
// an IP, or a bare domain whose last label looks like a TLD -- that last check
// is what keeps "3.5" and a version number out.
function looksLikeUrl(query) {
  var q = String(query || "").replace(/^\s+|\s+$/g, "")
  if (!q || /\s/.test(q)) return ""
  if (/^[a-z][a-z0-9+.\-]*:\/\//i.test(q)) return q
  // A loopback or .local name: https would fail on almost every dev server,
  // and http on localhost is not a downgrade anybody can intercept.
  if (/^(localhost|127(\.\d{1,3}){3}|\[::1\])(:\d+)?(\/.*)?$/i.test(q)
      || /^[a-z0-9\-]+\.local(host)?(:\d+)?(\/.*)?$/i.test(q))
    return "http://" + q
  if (/^\d{1,3}(\.\d{1,3}){3}(:\d+)?(\/.*)?$/.test(q)) return "http://" + q
  // host:port, and the bare domain case. Both go to https: a browser that
  // wants http will be told so by the redirect.
  if (/^[a-z0-9][a-z0-9\-]*(\.[a-z0-9\-]+)*:\d+(\/.*)?$/i.test(q)) return "https://" + q
  if (/^[a-z0-9][a-z0-9\-]*(\.[a-z0-9\-]+)*\.[a-z]{2,}(:\d+)?([\/?#].*)?$/i.test(q))
    return "https://" + q
  return ""
}

// The user's OWN search engine, which arrives in the index because the daemon
// reads it out of Chrome's Preferences (see chrome_search_engine()). Google is
// the fallback for a missing or unreadable index, never an override.
function searchUrl(query, template) {
  var t = String(template || "")
  if (t.indexOf("{searchTerms}") < 0) t = "https://www.google.com/search?q={searchTerms}"
  return t.replace("{searchTerms}", encodeURIComponent(String(query || "")))
}

// With nothing typed there is still one thing an address bar has to be able
// to do, now that no keybind opens a browser any more: give you a window.
// Deliberately the same shape as the other two actions, so the pinned row has
// one renderer and one activation path rather than a special case.
function newWindowAction() {
  return { kind: "window", url: "", engine: "Browser",
           label: "Open a new browser window" }
}

// The one row that is always available with something typed: open it if it is
// a place, search for it if it is not. null only for an empty query, where
// the caller falls back to newWindowAction().
function urlOrSearch(query, search) {
  var q = String(query || "").replace(/^\s+|\s+$/g, "")
  if (!q) return null
  var url = looksLikeUrl(q)
  if (url)
    return { kind: "open", url: url, engine: "Open", label: "Open " + url }
  return { kind: "search", url: searchUrl(q, search && search.template),
           engine: (search && search.name) ? String(search.name) : "Google",
           label: "Search the web for “" + q + "”" }
}

// Which profile(s) a history row is known in, as initials of the DISPLAY
// names ("Andy" + "tradewinds.school" -> "AT"). Initials because the column is
// eighteen pixels wide, display names because the directory name ("Profile 1")
// is an internal identifier nobody should have to read. It says where a row
// has been seen; it does not say where Enter will open it -- that is the key's
// decision and the footer's job to state.
function profileMark(row) {
  // NOT Array.isArray. A row reaching here came through a ListView's model,
  // and QML converts the JS objects in a model to QVariantMap -- so a nested
  // array comes back as something that indexes and has .length but is not an
  // Array to the JS engine. Asking isArray silently took the one-profile
  // branch and every merged row drew a single initial. Duck-type instead.
  var names = (row && row.profileNames && typeof row.profileNames.length === "number")
    ? row.profileNames
    : (row && row.profileName) ? [row.profileName] : []
  var out = ""
  for (var i = 0; i < names.length; i++) {
    var name = String(names[i] || "").replace(/^[^a-z0-9]+/i, "")
    if (name) out += name.charAt(0).toUpperCase()
  }
  return out
}

// Mirrors bin/literate-workspace-namer's strip_status_glyphs(): drop leading
// whitespace and symbol/spinner characters so a live Claude Code window title
// (which carries a status glyph while the agent is working) compares equal to
// the index's already-clean ai-title. Written as explicit code-point ranges
// for the Unicode symbol blocks CLI spinners draw from (arrows/math/
// misc-technical/geometric-shapes/dingbats/braille/misc-symbols, plus emoji)
// rather than the daemon's unicodedata-category test, since this QML engine's
// regex support for \p{..} Unicode property escapes is not something to
// depend on. This never touches real letters (Latin, CJK, ...), only the
// code-point ranges the spinner glyphs themselves live in.
function isStatusGlyphCodePoint(cp) {
  return (cp >= 0x2190 && cp <= 0x2BFF) || (cp >= 0xFE00 && cp <= 0xFE0F)
    || (cp >= 0x1F300 && cp <= 0x1FAFF)
}

function stripStatusGlyphs(title) {
  var s = String(title || "")
  var i = 0
  while (i < s.length) {
    var cp = s.codePointAt(i)
    if (cp === 0x20 || cp === 0x09) { i += 1; continue }
    if (isStatusGlyphCodePoint(cp)) { i += (cp > 0xFFFF ? 2 : 1); continue }
    break
  }
  return s.slice(i)
}

// Hyprland's IPC module spells a window address bare ("aaaaf6e5f8c0"); the
// daemon and `hyprctl -j clients` spell the same address "0xaaaaf6e5f8c0".
// Every join between the two goes through here.
function normalizeAddress(address) {
  var a = String(address || "").toLowerCase()
  return a.indexOf("0x") === 0 ? a.slice(2) : a
}

// Relative age for a unix timestamp, in the shape the design's right-hand
// column uses: now / 6m / 2h / 1d. null means "never observed" -- the daemon
// is deliberate about not guessing a lastFocus, so neither is this.
function age(unixSeconds, nowSeconds) {
  var t = Number(unixSeconds)
  if (!isFinite(t) || t <= 0) return ""
  var d = Math.max(0, Math.round(nowSeconds - t))
  if (d < 60) return "now"
  if (d < 3600) return Math.floor(d / 60) + "m"
  if (d < 86400) return Math.floor(d / 3600) + "h"
  return Math.floor(d / 86400) + "d"
}
