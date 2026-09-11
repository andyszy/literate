# Working on Literate

One Omarchy plugin that supplies four things: a **vendored fork** of Omarchy's
bar, a **workspace widget** that replaces the stock numbers, the **daemon**
that names those workspaces, and a **hold-to-open action menu** for a single
workspace. The manifest declares `kinds: ["bar", "bar-widget", "overlay"]`, so
`entryPoints.bar` draws the bar, `entryPoints.barWidget` fills the workspace
slot, and `entryPoints.overlay` is the menu.

Everything below is a thing that has already gone wrong once.

## What the shell will and won't discover

- Third-party plugins are found **only** as
  `~/.config/omarchy/plugins/<dir>/manifest.json` — one manifest, one plugin,
  at the top level. A widget nested in a subfolder with its own
  `widgets/*.manifest.json` is **never** registered; that sibling-manifest
  trick is first-party only. This is why `Workspaces.qml` sits at the repo
  root and is named by the top-level manifest, and *not* in `widgets/`.
- One manifest carries at most one `barWidget` entry point. One widget per
  plugin is the ceiling.
- A plugin may declare several kinds, and the active bar is not excluded from
  widget discovery: `syncPluginWidgets()` (shell.qml:669) walks every enabled
  plugin whose `kinds` contains `bar-widget` and registers it under its
  manifest id. That is what lets one plugin be both. `omarchy.menu` ships this
  way too.
- `omarchy.*` ids are reserved; a third-party manifest using one is dropped
  with a console warning. The install directory name must equal the manifest
  id (`omarchy plugin add` enforces it).
- `omarchy plugin validate` refuses **any symlink inside** the plugin folder.
  Symlinks *into* it from elsewhere (`~/.local/bin/literate-workspace-namer`)
  are fine. Run it on both `main-*` branches before pushing.
- `omarchy plugin update` is `git fetch` + `merge --ff-only` on `origin HEAD`.
  Keep the default branch fast-forwardable: no force pushes, no rebasing
  published history.

## The vendored bar must match the installed shell

`Bar.qml` imports `Style`, `Color` and `BarModel` from the host shell. A bar
vendored from a different Omarchy release can break on API drift, so the branch
you install has to match the Omarchy you run.

**`/usr/share/omarchy` is not necessarily basecamp's tree.** On Apple Silicon
it is omarchy-mac/omarchy-mac, byte-for-byte — even though `pacman -Qi omarchy`
reports `https://github.com/basecamp/omarchy` as the URL. At Omarchy 4.0.3 the
two bars differ by 265 lines, including the Apple Silicon notch handling
(`appleSiliconHost`, `notchFloor`) that basecamp has no trace of. Diff against
the fork you actually run before concluding anything about "upstream". Never
edit `/usr/share/omarchy` — it is package-owned and an `omarchy update`
overwrites it.

## Branches

| Branch | Role |
|---|---|
| `upstream-mac`, `upstream-basecamp` | pristine vendor bases, no patches, never edit by hand |
| `main-mac` (default), `main-basecamp` | vendor base + patches + everything this fork owns |

**The default branch must be the one the repo owner runs**, or every
`omarchy plugin update` fails to fast-forward. The widget, the daemon and the
docs are identical on both `main-*` branches; only the vendored bar differs.
Keep them that way — a fix applied to one belongs on the other.

## Patches are replayed, not cherry-picked

`tools/apply-patches.py` holds the patch set as a script. The two vendor bases
diverge by hundreds of lines, so cherry-picking the same commit onto both
conflicts; running the script on each is deterministic. It is idempotent, and it
**exits non-zero when a patch site changes shape** rather than emitting a
half-patched bar. Keep that property — a silently half-patched bar is much worse
than a failed sync.

Patch 2 (un-requiring the host-injected properties) applies only to the mac
base; basecamp already declares them plain. The script detects this and skips,
so do not "fix" it to apply unconditionally.

## `tools/sync-upstream` deletes anything it does not know about

It rsyncs `--delete` from the upstream bar directory **into the repo root**.
Every file this fork owns survives only because it is named in the
`--exclude` list — and since the merge that is most of the interesting files:
`Workspaces.qml`, `phosphor-codepoints.json`, `fonts/`, `bin/`, `fixtures/`,
`tools/`, and the docs. **Add any new fork-owned file to that list** or the
next sync silently deletes it.

Note that upstream's own `widgets/Workspaces.qml` is vendored and unused; ours
is the root-level one. Do not confuse them.

It also defaults `SOURCE_ROOT` to the **installed** Omarchy, which on an Apple
Silicon machine is omarchy-mac. Running it with that default while
`main-basecamp` is checked out replaces the basecamp bar with the mac one, and
nothing complains: the tree still validates and the bar still renders, because
the machine testing it is a Mac. That has happened once already — see
`Rebuild the basecamp bar from its own vendor base`. A cheaper tell is that the
two `main-*` trees go byte-identical, which cannot be right when the vendor
bases differ by 265 lines.

The script now refuses a mismatch, keying off `appleSiliconHost` in the source
`Bar.qml` (the defining difference between the bases) against the branch name.
On a basecamp branch, pass a basecamp checkout explicitly.

**Never fix a cross-branch difference by copying `Bar.qml` from the other
branch.** The patches land at different line numbers on different bases;
replay `tools/apply-patches.py` on the branch's own vendor base instead.

## `bar.foreground` is the *popup* text colour, not the bar's

Two properties, one letter apart, and upstream aliases them at `Bar.qml:65-69`:

- `barForeground` — what `WidgetButton`/`BarIconButton` paint with, i.e. every
  glyph and label actually drawn **on** the bar.
- `foreground` — what everything the bar **spawns** reads: the body text of
  every panel (audio, network, bluetooth, power, monitor, weather, clock,
  agents), `Ui/PanelSlider.qml`, and the tray menu. The bar's own chrome never
  reads it.

Upstream binds both to `Color.bar.text`, which is only safe while the bar and
its popups share a background. Set `[bar] text` in `~/.config/omarchy/shell.toml`
— as this machine does, pinning the bar white-on-black to match the notch over
a light theme — and that white leaks straight onto the light `[popups]` cards:
every panel renders white text on a white card, or on the light grey of a
selected row. Only the muted secondary labels stay legible, so it reads as "a
few widgets are broken" rather than "one colour is wrong".

Patch 4 in `tools/apply-patches.py` re-binds `foreground` to `Color.popups.text`.
Its one cost: `widgets/Tray.qml:19` reads the same property both for the tray
menu *and* to colorize **symbolic** tray icons drawn on the bar, so those now
follow the popup colour. That is upstream conflating two roles in one property;
patching it here is not an option, because the `omarchy.tray` widget is loaded
from `/usr/share/omarchy/shell/plugins/bar/widgets/`, never from this repo's
`widgets/` (see the discovery rules above — this repo's whole `widgets/` tree is
vendored and dead).

Do not "fix" this by darkening `[popups]` instead. `[controls]` is shared with
the menu, launcher, polkit and lock surfaces, so making panels dark would drag
all of those down with it.

## `active: true` does not mean the bar rendered

`omarchy-shell shell listPlugins` reporting `"active": true` only means the
plugin was *selected* as the bar provider. A bar that throws during
construction still reads as active. Verify with the compositor instead:

```bash
hyprctl layers | grep omarchy-bar      # the layer must exist
hyprctl monitors | grep reserved       # e.g. "reserved: 0 32 0 0" for a top bar
```

Trusting `active: true` once meant shipping a bar that did not exist. Widgets
are worse: `active` is false for every bar widget, healthy or not, so the only
evidence of a failed widget is the log line at shell.qml:801.

## A broken bar leaves *no* bar, not the stock one

`shell.qml` is supposed to fall back to the built-in bar when a plugin bar fails
to load, but that handler throws `ReferenceError: errorString is not defined`
before it can set `failedBarId`. So a bad patch here does not degrade to the
default bar — it leaves the desktop with no bar at all.

Recover with `omarchy plugin enable omarchy.bar`. Read the errors that never
reached the log with `quickshell -n -p /usr/share/omarchy/shell log | tail -40`.

## The widget

- `moduleName` **must equal the layout id**, which since the merge is the
  plugin id `literate`. `BarWidget.broadcast()` finds the widget's
  instances (one per monitor) by matching `slot.moduleName`, so anything
  IPC-driven lands nowhere on a mismatch. (There is no IPC surface today. A
  Super-hold "show numbers" mode driven by bare `SUPER_L` press/release binds
  was tried and removed: the key-state tracking wasn't reliable, and numbers
  always visible is simpler. Don't reintroduce it without asking.)
- The shell hot-reloads files under `~/.config/omarchy/plugins/`, but its
  "reloading" log line lies for visual changes. **`omarchy restart shell`**
  before judging a rendering change, then look at the bar (a `grim` crop of
  the top 32 logical px is enough).
- Phosphor is not in the Omarchy shell; the font is bundled and loaded with
  `FontLoader` (Qt 6: read `loader.font.family`, `name` is gone). Codepoints
  are in the BMP private use area, so `String.fromCharCode` is enough — no
  surrogate pairs. `phosphor-codepoints.json` is generated from the
  `style.css` in the phosphor-icons/web release matching `fonts/Phosphor.ttf`;
  regenerate both together.
- Focus is signalled by the name being bright, not by colour. `active: true`
  on a `WidgetButton` paints the bar's *urgent* colour; keep it behind the
  `accentFocused` setting.
- State comes from a `FileView` with `watchChanges`. The daemon writes the file
  atomically (`tmp` + `rename`) so the widget never parses a half-written file.
  Keep it that way.

## The daemon

- It listens on Hyprland's `socket2`. **A terminal whose title carries a
  spinner emits `windowtitlev2` every second** (Claude Code does this while it
  works), so a plain debounce never settles. `schedule()` has a `max_wait`
  ceiling for that reason, and `strip_status_glyphs()` removes leading symbol
  characters so the spinner doesn't change the workspace's signature every
  tick (which would mean a model call per tick). Test with a session running.
- Titles have their app-name suffix stripped (`Gmail - Google Chrome` →
  `Gmail`) before the model sees them. That single change was the difference
  between the model naming the *tool* ("browsing") and the *subject*
  ("email"). Don't remove it; extend `RE_APP_SUFFIX` when a new app shows up.
- The model gets each workspace's previous name and is told to keep it when
  the activity hasn't changed. Without that, switching Gmail threads flips the
  label between "email" and the thread subject.
- **Check the prompt against the fixture before and after any prompt change**:
  `bin/literate-workspace-namer --test fixtures/eval.json`. It prints a
  table and writes nothing. Add a case whenever a real workspace gets a bad
  name. Workspaces 6 and 7 in the fixture mirror the few-shot examples, so
  they prove less than the rest.
- Backends: `auto` → `api` (Anthropic SDK from the venv at
  `~/.local/share/literate/venv`; the daemon adds its
  `site-packages` to `sys.path` and keeps a plain `python3` shebang so it still
  runs without the venv) → else `claude-cli`. The CLI path only behaves with
  `--system-prompt`, `--tools ""`, an empty `--mcp-config` with
  `--strict-mcp-config`, and `MAX_THINKING_TOKENS=0` (Claude Code enables
  extended thinking by default; Haiku thought for ~90 s per call). `--bare`
  skips the keychain read and breaks its login. Prefer the API.
- `hyprctl` is called with a timeout: it can hang while the compositor is busy
  (a shell restart), and an unbounded call wedges the pass lock forever.
- Under `uwsm` the interpreter comes from mise, so the process's argv doesn't
  start with `python3`; match on the script path when you `pgrep`/`pkill`, and
  never `pkill -f` a pattern that also matches your own shell command.
- Launch it the way autostart does when testing:
  `hyprctl dispatch 'hl.dsp.exec_cmd("uwsm-app -- literate-workspace-namer")'`.
  `hyprctl dispatch exec …` is not a dispatcher on this Lua-configured Hyprland.
  Logs go to `~/.local/state/literate/daemon.log` (uwsm swallows
  stderr).
- State, config and the venv live under `~/.local/state/literate/`,
  `~/.config/literate/` and `~/.local/share/literate/`, set in four constants
  near the top of the daemon. Change them together, or the widget ends up
  watching a file nobody writes. The daemon keeps its descriptive name,
  `literate-workspace-namer`: it is a command, not a namespace, and the
  Hyprland autostart line refers to it.

## The overlay

`Overlay.qml` is the hold-to-open action menu (rename, spin out a group,
close all) for one workspace. It is a fork-owned file, exactly like
`Workspaces.qml`: it must stay in `tools/sync-upstream`'s `--exclude` list, or
the next re-vendor deletes it silently.

- The manifest needs `kinds` to include `"overlay"`,
  `entryPoints.overlay: "Overlay.qml"`, **and** a top-level `"keepLoaded":
  true`. All three live in `tools/apply-patches.py`'s `FORK_MANIFEST` dict,
  same as the bar-widget registration — hand-editing `manifest.json` is
  useless, it's regenerated from that dict on every sync.
- `keepLoaded` is not optional. `shell.qml`'s panel `Loader` (the one that
  covers `panel`/`overlay`/`menu` kinds) is only `active` when the plugin is
  `keepLoaded` **or** currently summoned — see `computePanelEntries()` and the
  `panelLoader` in the `Instantiator` delegate. Without `keepLoaded`, the
  first `summon()` has to activate the Loader and wait on asynchronous QML
  compilation before `open()` ever runs, so the very first hold feels broken
  (nothing appears, or appears late). `keepLoaded: true` mounts the overlay at
  shell startup instead, so every summon after that is instant.
- Same trap as the bar (see above), same fix: `omarchyPath`, `shell`,
  `manifest` and `pluginRegistry` are injected by the host **after**
  construction, in the panel `Loader`'s `onLoaded` handler. Declare all four
  as plain properties with defaults — `property var shell: null`, not
  `required property var shell` — or the overlay fails to load at all. This
  is the exact bug that once took down the whole bar on this machine; it is
  just as fatal on an overlay, it just fails more quietly (no bar disappears,
  the menu just never opens, and the failure is a Loader.Error console
  warning rather than a black screen).
- Lifecycle contract is `open(payloadJson)` / `close()` / `ping()`, copied
  from `/usr/share/omarchy/shell/plugins/menu/Menu.qml` and
  `plugins/clipboard/Clipboard.qml`. `open()` gets `{"workspace":"N"}` and
  must render something before the `--suggest` model call returns — show the
  header and static rows immediately, replace a real animated progress bar
  (not a "Thinking…" row) with the suggested name once the call lands or
  fails or hits its ~10s timeout.

## Window classes are not app names

Hyprland hands out a window *class* and nothing else. Left alone it reaches
the UI verbatim, and the UI then shows people `chrome-gmail.com__-Default`.
`window_identity()` resolves it, in a fixed order, each layer running only
because the one above it had nothing:

1. **the desktop entry** that claims the class -- `StartupWMClass` first (the
   field that exists to say exactly this), then the `.desktop` filename stem.
   `DesktopIndex` walks `/usr/share/applications` and
   `~/.local/share/applications` once and rebuilds only when a directory's
   mtime moves, so a lookup is a dict hit plus two `stat()`s. The parser is
   hand-rolled on purpose: `configparser` rejects real desktop files
   (duplicate keys, `Name[de]=`), and only the `[Desktop Entry]` group is
   read -- the `[Desktop Action *]` groups below it carry their own `Name=`.
2. **a Chrome site-app class**, `chrome-<host>__<path>-<Profile>`, unwrapped
   to its host and named through `KNOWN_HOSTS`.
3. **a bare browser window**, which is not an app identity at all. Browser
   classes take this *before* the desktop entry: "Google Chrome" is a true
   answer and a useless one -- nobody's window is Chrome, it is the page they
   are reading. The active tab comes from the same `chrome-tabs.json` join the
   model prompt uses, and its site's own branding (the short trailing title
   segment) beats anything derived from the host. The desktop entry stays the
   fallback for a browser window that could not be joined.
4. **reverse-DNS prettification** -- last segment of `org.foo.Bar`, title-cased.
   `REVERSE_DNS_NAMES` overrides the handful that prettify wrong, which is how
   `org.omarchy.claude` becomes "Claude Code" rather than "Claude". Nothing
   machine-shaped ever escapes this layer.

`KNOWN_HOSTS`/`site_name()` is **one** table, deliberately shared with the
omnibox index's Chrome history rows (`build_history()` sets each row's `app`
through it). An open Gmail window and a Gmail history hit are labelled by one
code path; teach it a host and both learn at once. Two tables would drift
within a week.

The run-on title is split at the same time into `app` / `subject` / `context`
(plus `host`, `appIcon`, `appSource`), so a UI can lay out columns instead of
rendering one string: `"Further your mission with GitHub 🚀 - andyszy@gmail.com
- Gmail"` becomes subject `"Further your mission with GitHub 🚀"` and context
`"andyszy@gmail.com"`. `split_title()` only ever strips *trailing* segments,
and only ones it can prove redundant (the app's own name, the host, an email
address), never down to nothing -- subject matter is never thrown away.
`strip_status_glyphs()` still runs on the subject, because Claude Code writes
a spinner into its title.

Identity is computed in `_filtered_clients()` **before** `chrome_url_suffix()`
folds the URL and other-tab list into the title. That suffix exists for the
model; it must not end up inside the subject a person reads. Note also that
`host` is suppressed when `chrome_urls` is `"off"` -- the app name still
resolves, since the tab's branding is already in the window title, but the
URL-derived field is the privacy-sensitive one and follows the setting.

## `lastFocus`: the datum Hyprland does not keep

Hyprland exposes no per-window last-focus time, and nothing else on the
machine does either -- joining against Chrome history to answer "when did I
last touch this" lies, because a window open right now can sit behind a
six-day-old visit row. The daemon is already on the event socket, so it
records focus itself.

- The event is **`activewindowv2`**, payload a bare window address with no
  `0x` prefix (`activewindowv2>>aaaaf6e5f8c0`) -- `hyprctl` spells the same
  address `0xaaaaf6e5f8c0`, so everything goes through `normalize_address()`.
  An empty payload means focus left everything and is ignored.
- It is deliberately **not** in the listener's `watched` tuple. Which window
  has focus is not a change to the window *set*; adding it there would cost a
  naming pass, and eventually a model call, on every alt-tab.
- Writes are coalesced (`FOCUS_FLUSH_INTERVAL`), because focus changes arrive
  as fast as someone can hold Alt. `focus.json` is only ever interesting to a
  UI that is about to open.
- Pruning is twofold: `closewindow` carries the address, so `forget_focus()`
  is exact and free; `prune_focus()` then sweeps whatever closed while the
  daemon was down, against the **unfiltered** address set `_filtered_clients()`
  collects on its way past (filtering it would forget every scratchpad window
  once a pass).
- `lastFocus` is **not** part of `triage_signature()`, or alt-tabbing would
  throw away the precomputed grouping. That does mean a cache hit carries a
  stale timestamp, so `triage()` re-stamps from the live map on the way out.
- A window the daemon has never watched take focus reports **null**. Not the
  window's age, not "now" -- the one column that exists to be trusted must not
  contain a confident guess. The single exception is `seed_focus()`, which
  stamps the window that is focused when the daemon connects: nothing replays
  the focus we missed, and "this window is focused at this instant" is an
  observation rather than a guess. It only ever applies to an address with no
  record, so a restart cannot overwrite a real earlier timestamp.

## The triage view

`Triage.qml` is the SUPER+0 full-desktop overview: every window on every
real workspace, grouped by activity via `literate-workspace-namer --triage`.
It is a fork-owned file exactly like `Workspaces.qml` and `Overlay.qml` —
it must stay in `tools/sync-upstream`'s `--exclude` list.

- It is **not** a manifest entry point. The obvious design — a new `"panel"`
  kind with `entryPoints.panel: "Triage.qml"` — doesn't work: shell.qml's
  `computePanelEntries()` builds exactly one panel/overlay/menu Loader **per
  plugin id**, picking a single entry point by kind priority
  `panel > overlay > menu`. Adding `"panel"` alongside this plugin's existing
  `"overlay"` kind would make the host pick `"panel"` and never resolve
  `entryPoints.overlay` again — `Overlay.qml`, and the whole per-workspace
  hold-menu, would silently stop being summonable. So `Triage.qml` is a plain
  QML component that `Overlay.qml` instantiates directly (implicit
  same-directory import), mounted inside `Overlay.qml`'s existing
  `PanelWindow`. Summon it with
  `omarchy-shell shell summon literate '{"mode":"triage"}'`; `Overlay.qml`'s
  `open()` reads the payload's `"mode"` field to pick which of the two
  lifecycles to run.
- Same host-injection trap as `Overlay.qml` (see above): `Triage.qml` itself
  is never injected into by the host, since it isn't an entry point — only
  `Overlay.qml` receives `omarchyPath`/`shell`/`manifest`/`pluginRegistry`,
  and hands `Triage.qml` only what it needs (`binPath`) as a plain property.
- `literate-workspace-namer --triage` groups every filtered window on every
  real workspace (reusing `_filtered_clients()`) by what the user is *doing*,
  not by which app is open. The model call and all of its validation live in
  `compute_triage()`: every category name/icon goes through `self.clean()`
  like a workspace name does, indices the model invents or reuses across
  categories are dropped/deduped, and anything left uncategorised lands in a
  final "Uncategorised" group rather than being lost.
- **The answer is precomputed, not computed on the keypress.** The daemon is
  already sitting on the event socket and already knows when the window set
  settled, so `fire()` calls `maybe_precompute_triage()` after each debounced
  pass and writes the result to `~/.local/state/literate/triage.json`.
  `--triage` then returns that file when its `signature` matches the live
  window set: ~45 ms instead of ~1.4 s, and no model call. The payload is the
  same shape either way plus `"cached": true|false`, so the UI parses one
  format. `--triage --no-cache` always asks the model.
- The precompute deliberately runs **outside `pass_lock`**, after `apply()`
  has returned. Naming is the daemon's job; triage is opportunistic. A failed
  precompute is logged and dropped (the signature is not recorded, so the next
  settled pass retries) and `--triage` just asks live in the meantime.
- `triage_signature()` is a hash of every window's address+class+title+
  workspace, **sorted** — hyprctl reorders its reply on focus changes and that
  is not a change. It is global, unlike the per-workspace naming cache, so one
  chatty title would otherwise re-ask about the whole desktop every debounce
  window. `triage_min_interval` (30 s) is the floor that stops that. When it
  bites the precompute is *deferred* -- one `threading.Timer` re-runs the pass
  once the floor expires, which is not a poll (the change has already
  happened) and is what keeps a burst-then-quiet desktop from sitting on a
  stale cache until the next Hyprland event, which on an idle machine is
  never. Should even that miss, `--triage` just falls back to a live call,
  which is only ever as slow as the old behaviour. Set `triage_precompute: false` to
  get exactly the old behaviour back.
- `run_pass()` gathers `_filtered_clients()` once and derives both the naming
  snapshot (`group_by_workspace()`) and the triage window list
  (`triage_windows()`) from it — the precompute costs no extra `hyprctl`.
- `Triage.qml` does not even wait for that ~45 ms: it keeps its own `FileView`
  on `triage.json`, and because `Overlay.qml` is `keepLoaded` the file is
  already parsed before the key is ever pressed, so `open()` paints a full
  grouping in its first frame and *then* runs `--triage` to confirm it. Which
  is why `blocking` (nothing on screen yet) and `refreshing` (an answer in
  flight over rows already drawn) are separate: only the first gets the
  progress bar, the second gets " · refreshing…" in the header. A grouping
  that is slightly stale beats a spinner over data we already have — and when
  the confirmation comes back byte-identical the handler returns early rather
  than resetting the cursor under someone who has started arrowing around.

## The omnibox index

`literate-workspace-namer --index-omnibox` writes
`~/.local/state/literate/omnibox-index.json`: past Claude Code conversations
plus Chrome history, for a UI to search over. Unlike everything else in this
file it makes **no model call** and is pure local indexing, so it can run far
more often than a naming pass.

- Conversations come from `~/.claude/projects/<slug>/<sessionId>.jsonl`. The
  label is whatever the transcript's own `{"type":"ai-title",...}` record
  says -- a transcript with none is skipped rather than given an invented
  name. `scan_transcript()` reads every line once (it needs the line count
  anyway, as a cheap stand-in for message count) but only ever calls
  `json.loads` on a line that contains the literal substring `"ai-title"`,
  so a multi-megabyte transcript costs one linear byte scan, not one JSON
  parse per line. A retitle mid-session can emit the record more than once;
  the last one wins.
- `decode_project_slug()` reverses the directory name Claude Code stores
  transcripts under (e.g. `-home-andy` for `/home/andy`) by replacing "/"
  with "-". That is lossy to invert on its own: a scratchpad directory
  embeds a session id, which already contains "-", so
  `-tmp-claude-1001--home-andy-<uuid>-scratchpad` looks identical to a path
  with more slashes once encoded. Rather than guess at a split, it only
  trusts a decode that resolves to a directory that actually exists on
  disk; anything else falls back to `$HOME`. This is why a scratchpad
  session's `project` in the index is just `$HOME`, not its real (and
  unrecoverable) working directory.
- Chrome history comes straight from `~/.config/google-chrome/Default/History`
  -- the live sqlite file, never a copy -- opened with the URI form
  `file:<path>?immutable=1`. That tells sqlite the file won't change under
  it and to skip its normal locking, which is what makes it safe to open
  read-only while Chrome itself has the file open (verified: a few ms, no
  lock contention). **Never open this file without `immutable=1`, and never
  read-write** -- it is Chrome's live database, not this plugin's.
  `last_visit_time` is microseconds since 1601-01-01 (`webkit_to_unix()`
  converts); getting that wrong silently puts every timestamp 369 years off
  rather than erroring, so it's worth spot-checking a real row's date after
  touching this.
- Both sources are capped (`OMNIBOX_CONV_LIMIT`, `OMNIBOX_HISTORY_LIMIT`) so
  the JSON stays small enough for a UI to hold in memory and filter locally.
- The daemon also rebuilds the index opportunistically, the same shape as
  `maybe_precompute_triage()`: `run_pass()` calls
  `maybe_refresh_omnibox_index()` after every settled naming pass, which is
  guarded by its own monotonic floor (`OMNIBOX_MIN_INTERVAL`) and a
  stat-only change check (`_omnibox_changed()` -- Chrome's History file
  mtime, or any transcript newer than the index) so a quiet desktop costs a
  handful of `stat()` calls, not a rescan. Set `omnibox_index: false` to
  turn this off; `--index-omnibox` still works standalone either way.

## Privacy

Window titles for every workspace go to the model. Keep `ignore_classes` and
the `local` backend working; they are the answer when someone asks.

The omnibox index goes further than any of the above: it reads all of
Chrome's browsing history and every past Claude Code conversation's title,
not just what's open right now. `omnibox_index: false` is the off switch.

## Live window thumbnails work, and the join is the interesting part

Quickshell ships `ScreencopyView` (`Quickshell.Wayland`, from
`_Screencopy`). It captures a real window's pixels **including windows on a
workspace that is not currently visible**, which is the whole premise of the
shelf. Verified with a throwaway `quickshell -p` config against a window
parked on workspace 2 while workspace 1 was showing: `hasContent` went true,
`sourceSize` reported the window's real size in physical pixels
(2968x1844 for a 1484x922 logical window at scale 2), and the grab was a
legible Gmail screenshot. Nine of them render at once with no visible
difference.

The sticking point is the mapping, and Hyprland's own module solves it:

- `captureSource` wants a `qs::wayland::toplevel::Toplevel` — the object in
  `ToplevelManager.toplevels`. That type exposes only `appId`, `title`,
  `activated` and friends. **None of those is a key**, so matching a
  `hyprctl` address to a Toplevel by app-id and title is guesswork the moment
  two windows share both.
- `Quickshell.Hyprland`'s `Hyprland.toplevels` holds `HyprlandToplevel`
  objects instead, and each one carries **`address` AND `wayland`** (the
  Wayland `Toplevel`), plus `workspace` and a `lastIpcObject` that is the
  whole `hyprctl -j clients` record (`at`, `size`, `class`, ...). So the join
  already exists: address for the daemon's data, `.wayland` for the pixels,
  `lastIpcObject` for the geometry. Never reconstruct it by title.
- `HyprlandToplevel.address` has **no `0x` prefix**; `hyprctl` and the daemon
  both write `0xaaaa...`. Everything goes through
  `Omnibox.normalizeAddress()`, same rule as the daemon's own
  `normalize_address()`.
- `ToplevelManager.toplevels` is **empty at `Component.onCompleted`** — it
  fills asynchronously. Anything that walks it has to do so later.

Cost: nine `live: true` views cost the shell **~16% of a core** for as long as
they are on screen. The shelf therefore sets `live: false` and pulls one frame
per view off a 1.5 s timer that only runs while the surface is visible, which
measures at **~1% over idle**. A thumbnail a second and a half stale is not
one anybody can pick out; a fan spinning up while you glance at your
workspaces is.

## The shelf

`Shelf.qml` is the SUPER+SLASH view: a full-width black shelf of live
workspace boards over an omnibox panel. Same rules as `Triage.qml` — not a
manifest entry point, instantiated by `Overlay.qml`, selected by the summon
payload (`{"mode":"shelf"}`, optionally with `"query"`), and in
`tools/sync-upstream`'s `--exclude` list along with `Omnibox.js`. Triage keeps
its own chord on SUPER+SHIFT+SLASH while the two are being compared.

- **It covers the bar; it does not hang below it.** The bar already draws the
  workspace list, so a shelf drawn underneath showed the same list twice. The
  surface starts at `y = 0` on `Color.bar.background` and draws its own
  headers. The bar's other modules (menu button, clock, tray) are hidden for
  as long as it is up; that is the accepted cost.
- The transition is a **cross-fade, not a morph**. An earlier version lerped
  each board from a reconstruction of where the bar draws its labels out to
  the expanded layout; that can only be seamless if the reconstruction matches
  the vendored bar's font metrics exactly, and the mismatch read as a snap at
  the handoff. Two dials drive it instead: `extent` (how far the black surface
  has grown) and `reveal` (how present the content is). The ORDER on close is
  the whole trick — `reveal` reaches 0 *before* `extent` starts shrinking, so
  the frame where the real bar takes over is a frame with nothing of ours
  drawn.
- **A board carries the screen's aspect ratio**, computed from the monitor and
  the compositor's reserved area, never hardcoded. A board at some invented
  ratio does not read as a workspace. Nine of them at true aspect do not fit
  at a generous size, so occupied boards share the free width equally up to a
  height cap and **empty workspaces collapse to outlines** and absorb the
  slack — they hold nothing, so a board shape would be claiming something
  false. Windows sit at their real fraction of the usable area
  (`lastIpcObject.at`/`size`), so the board is a real miniature and a
  master/stack split looks like one.
- **The outer height is fixed.** `PanelWindow.implicitHeight` is the layer
  surface's height, and a Wayland surface that resizes mid-interaction reads
  as the shelf flinching. A panel height derived from the row count made it
  flinch every time Tab landed on a workspace with a different number of
  windows. Same call `Triage.qml` already made about its card.
- **Anything that moves compositor focus has to wait for this surface to be
  gone.** The shelf holds exclusive keyboard focus, and when that layer unmaps
  Hyprland restores focus to the window that had it before — which silently
  undoes the switch. Verified: "go to workspace 5" dispatched while the shelf
  is open lands on 5 and bounces back to 3 the moment it closes. `runAfterClose()`
  queues those dispatches until the collapse animation has hidden the window.
  Launching something new is unaffected and stays inline.
- **Selection holds a real workspace id, never a tile ordinal.** They agree
  only while the boards are a contiguous 1..N, and the place the difference
  surfaces is the dispatch that switches workspace — i.e. it sends you
  somewhere else entirely, silently. Proven against a desktop with workspaces
  1, 2, 3 and 5.
- **Focus is a region, not just an index.** `focusRegion` says whether Enter
  belongs to the shelf (go to that workspace) or the panel (act on that row).
  Without it, hovering board 3 and pressing Enter focused the panel's first
  row, which was a window on workspace 1.
- `MouseArea.onPositionChanged` fires whenever the pointer moves **relative to
  the item**, which includes an item sliding under a stationary pointer. That
  is how a re-created panel row stole focus back the instant a board was
  selected. `pointerMoved()` compares against the last position in window
  coordinates; only real movement counts. This is the same class of bug
  `Triage.qml`'s `pointerLive` already guards, one level deeper.

## The omnibox's launcher chords

With a query typed, the user's own Terminal / Browser / agent chords act on
that text instead of launching an empty app. **The chords are discovered, not
hardcoded**: `hyprctl binds -j` is matched against the human `description`
field ("Terminal", "Browser", and an ordered preference over "Claude Code
(Opus)" / "(Sonnet)" / "(Fable)" / "Claude Code" / "Agent"). Rebind Terminal
tomorrow and the omnibox follows; a description that is not found simply
yields no affordance.

- The bind's **action** cannot be reused. On this Lua-configured Hyprland
  every user bind reports `dispatcher: "__lua"` with an opaque callback index
  as its `arg`, so there is no command string to recover. The commands are
  reconstructed from Omarchy's own launchers, with one detail taken from the
  discovery rather than assumed: the agent's model comes out of the matched
  description, so a user who binds Sonnet gets Sonnet.
- Those are GLOBAL binds, so the compositor would consume them and launch an
  empty terminal — the same trap SUPER+SHIFT+digit hit. They are shadowed in a
  submap. Since the chords are discovered, the submap is **defined at
  runtime**: `hyprctl keyword` is refused here ("keyword can't work with
  non-legacy parsers, use eval"), but `hyprctl eval` runs Lua in the config's
  own context, where `hl.define_submap` and `hl.bind` are both callable.
- Redefining a submap name **appends to it rather than replacing it** — a
  shell restart once left one submap holding both the old and the new Escape
  bind. Each definition therefore gets a wall-clock generation name, which
  also has to be unique across restarts because a runtime submap outlives the
  shell. Same lesson as the Lua layout API.
- **Plain Escape must never be bound in these submaps.** It was, as a safety
  exit, and that made Escape take two presses: the compositor ate the first,
  reset the submap and *spawned a process* to ask the overlay to hide, so
  nothing visibly happened; only the second press reached the client. It also
  meant the overlay's "clear the query first, close only when it is already
  empty" never ran. The safety net lives on SUPER+Escape.
- Terminal opens the query **pre-filled but not executed** — running arbitrary
  typed text as a shell command out of a search box is a foot-gun. The line
  gets into readline's buffer via the terminal's own Device Status Report
  reply (`printf '\e[5n'` → the terminal answers `\e[0n` → readline expands
  the macro bound to it). A query that is an existing directory opens the
  terminal *there* instead.
