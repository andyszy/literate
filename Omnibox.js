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
  matched.sort(function(a, b) {
    if (a.rank !== b.rank) return a.rank - b.rank
    var byVisit = (Number(b.item.lastVisit) || 0) - (Number(a.item.lastVisit) || 0)
    if (byVisit !== 0) return byVisit
    return (Number(b.item.visits) || 0) - (Number(a.item.visits) || 0)
  })
  return matched.map(function(m) { return m.item })
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
