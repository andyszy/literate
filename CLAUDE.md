# Working on Literate

One Omarchy plugin that supplies three things: a **vendored fork** of Omarchy's
bar, a **workspace widget** that replaces the stock numbers, and the **daemon**
that names those workspaces. The manifest declares `kinds: ["bar",
"bar-widget"]`, so `entryPoints.bar` draws the bar and `entryPoints.barWidget`
fills the workspace slot.

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

## Privacy

Window titles for every workspace go to the model. Keep `ignore_classes` and
the `local` backend working; they are the answer when someone asks.
