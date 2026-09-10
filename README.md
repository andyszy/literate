# Literate

Omarchy's status bar, with two changes: the empty-bar click gestures are gone,
and the workspaces say what you are doing on them.

    1 ⚙ keybindings   2 </> auth refactor   3 ✉ email   4 ✈ lisbon trip   5

One plugin supplies both. An Omarchy plugin may declare several `kinds`; this
one declares `bar` and `bar-widget`, so `Bar.qml` draws the bar and
`Workspaces.qml` fills the workspace slot in it.

## Install

```bash
omarchy plugin add https://github.com/andyszy/literate.git --enable
~/.config/omarchy/plugins/literate/tools/install
```

`tools/install` creates a venv with the Anthropic SDK, links the daemon into
`~/.local/bin`, and prints the autostart line for you to paste. It edits
nothing behind your back.

Then give the daemon a credential: an API key in
`~/.config/literate/api-key` (chmod 600, scoped to this daemon),
`ANTHROPIC_API_KEY` in the session environment, or `ant auth login`.

Confirm the bar took:

```bash
hyprctl layers | grep omarchy-bar     # the layer should be present
hyprctl monitors | grep reserved      # e.g. "reserved: 0 32 0 0" for a top bar
```

Update with `omarchy plugin update literate`. Remove with
`omarchy plugin remove literate`. The shell gates the active bar on the
plugin still being installed, so removal falls straight back to the built-in
bar; `bar.id` stays in `shell.json` as a harmless leftover.

## What changed in the bar

Upstream treats the blank stretch between widgets as a control surface:

- **double-click** toggles `bar.transparent`, and persists it to `shell.json`
- **drag** (or press-and-hold, then drag) moves the bar to the nearest screen
  edge, which reflows every tiled window

Both fire on ordinary misclicks, and both write to your config, so a slip is
sticky rather than transient. This fork deletes the `CenterGestureArea`
`MouseArea` that owns them. The bar's position is then whatever `shell.json`
says and nothing but an edit can change it.

Dragging individual *widgets* to rearrange them still works — that is a
separate handler and is untouched.

## What the workspace names do

`bin/literate-workspace-namer` sits on Hyprland's event socket. Window
open/close/move/title events reset a 3 s debounce; when things settle it
snapshots `hyprctl clients`, strips app-name suffixes from titles
(`Gmail - Google Chrome` → `Gmail`) so the model sees the subject rather than
the tool, and for any workspace whose window set changed asks the model for a
name and an icon — feeding it the previous name so it doesn't flap between
"email" and "q3 invoice" on every tab switch. Identical window sets are cached
and never asked twice. Results are written atomically to
`~/.local/state/literate/workspaces.json`, which the widget watches.

The widget shows number + icon + name for every workspace, the focused one
bright, empty ones as just their number.

## Layout

| What | Where |
|---|---|
| Bar | `Bar.qml` (vendored from Omarchy, patched) |
| Workspace widget | `Workspaces.qml` |
| Daemon | `bin/literate-workspace-namer` (linked to `~/.local/bin`) |
| Phosphor font + name→codepoint map | `fonts/Phosphor.ttf`, `phosphor-codepoints.json` (1530 icons) |
| Prompt eval fixture | `fixtures/eval.json` |
| Daemon config (optional) | `~/.config/literate/config.json` |
| State, cache, log | `~/.local/state/literate/` |
| SDK venv | `~/.local/share/literate/venv` |

## Tuning

Widget settings go on the `literate` entry in `bar.layout`. That is the
same id that `bar.id` uses to select the bar — one plugin, one id, two roles.
It looks odd and is correct; `omarchy.menu` does the same thing.

```json
{ "id": "literate", "showNames": "all", "gap": 1.0, "accentFocused": false }
```

- `showNames`: `all` (default) / `focused` / `never`
- `gap`: space between workspaces (and before the first), in em
- `accentFocused`: paint the focused workspace in the bar's active colour

Daemon settings, `~/.config/literate/config.json` (all optional):

```json
{
  "backend": "auto",
  "model": "claude-haiku-4-5",
  "api_key_file": "~/.config/literate/api-key",
  "debounce": 3.0,
  "max_name_chars": 18,
  "ignore_classes": ["1password"]
}
```

Backends: `auto` (default — the API when a credential can be found, else
`claude-cli`), `api`, `claude-cli` (`claude -p` on your Claude Code login; no
key needed but ~4 s a call), `local` (any OpenAI-compatible endpoint such as
`llama-server`; set `local_url` and `local_model` — keeps window titles on the
machine).

## Testing the prompt

```bash
literate-workspace-namer --test ~/.config/omarchy/plugins/literate/fixtures/eval.json
literate-workspace-namer --once      # one pass over the live desktop
tail -f ~/.local/state/literate/daemon.log
```

## Privacy

Window classes and titles for every workspace go to the model. Titles can
carry email subjects, document names, URLs. Use `ignore_classes` to keep an
app out entirely, or the `local` backend to keep everything on the machine.

## Which branch you want

The bar is vendored, not subclassed — QML gives no way to reach into a nested
component and delete a gesture from outside. So this repo carries a full copy
of the bar, and the copy has to match the shell it runs against: `Bar.qml`
imports `Style`, `Color` and `BarModel` from the host, and those drift between
releases.

| Branch | Vendored from | For |
|---|---|---|
| `main-mac` (default) | [`omarchy-mac/omarchy-mac`](https://github.com/omarchy-mac/omarchy-mac) @ `09f16de` | Omarchy on Apple Silicon |
| `main-basecamp` | [`basecamp/omarchy`](https://github.com/basecamp/omarchy) @ `v4.0.3` | mainline Omarchy |
| `upstream-mac`, `upstream-basecamp` | — | pristine vendor bases, no patches |

Both branches are vendored against **Omarchy 4.0.3**. A newer Omarchy still
works until upstream changes the shell API the bar imports; if the bar
disappears after an `omarchy update`, that is the signal to re-sync.

`main-mac` is the default branch because `omarchy plugin update` fetches
`origin HEAD` and merges `--ff-only`; a default branch you are not tracking
makes every update fail to fast-forward.

On mainline Omarchy, install the other branch by hand:

```bash
git clone -b main-basecamp https://github.com/andyszy/literate.git \
  ~/.config/omarchy/plugins/literate
omarchy plugin enable literate
```

The workspace widget is identical on every branch; only the vendored bar
differs.

## The patches

Kept as a script rather than as commits, so they can be replayed onto a new
upstream instead of rebased through conflicts. `tools/apply-patches.py` is
idempotent and exits non-zero if a patch site has changed shape, so a bad
re-sync fails loudly instead of shipping a half-patched bar.

1. **Rename the plugin** — `manifest.json` becomes `literate` /
   "Literate". The `omarchy.*` id namespace is reserved.
2. **Un-require the host-injected properties** *(mac branch only)* —
   `shell.qml` loads a non-default bar with `Loader { source: url }` and only
   then assigns `omarchyPath`, `barWidgetRegistry` and `barConfig`, in
   `configureBar()` from `onLoaded`. QML required properties must be supplied
   at construction, so declaring them `required` makes **any** third-party bar
   fail with *"Required property was not initialized"* — and the fallback to
   the built-in bar throws `ReferenceError: errorString is not defined`, so
   the failure leaves you with no bar at all. `basecamp/omarchy` already
   declares these as plain properties (*"declaring it keeps clone construction
   atomic"*); the `omarchy-mac` fork regressed them, so only that branch needs
   this.
3. **Remove `CenterGestureArea`** — the actual point of the fork.
4. **Re-bind `bar.foreground` to `Color.popups.text`** — that property is read
   only by surfaces the bar *spawns* (every panel's body text, the tray menu),
   never by the bar's own chrome, which uses `barForeground`. Upstream aliases
   the two, which holds only while the bar and its popups share a background;
   a bar pinned to black over a light theme then paints white text on white
   popup cards.

## Re-syncing after an Omarchy release

```bash
git checkout upstream-mac
tools/sync-upstream                      # or: tools/sync-upstream /path/to/checkout
git commit -am "Vendor bar from omarchy-mac <version>"
git checkout main-mac && git merge upstream-mac
```

`tools/sync-upstream` re-vendors every file upstream ships, preserving the
files this fork owns, then re-applies the patches. It rsyncs `--delete`, so a
new fork-owned file must be added to its `--exclude` list or the next sync
deletes it.

## Credit and license

The bar and the workspace widget both derive from Omarchy, by DHH and the
Omarchy contributors, MIT licensed. Icons are
[Phosphor](https://phosphoricons.com) (MIT). See `LICENSE`.
