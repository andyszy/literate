# Literate Bar

The Omarchy status bar with the empty-bar click gestures removed.

Upstream's bar treats the blank stretch between widgets as a control surface:

- **double-click** toggles `bar.transparent`, and persists it to `shell.json`
- **drag** (or press-and-hold, then drag) moves the bar to the nearest screen
  edge, which reflows every tiled window

Both fire on ordinary misclicks, and both write to your config, so a slip is
sticky rather than transient. This fork deletes the `CenterGestureArea`
`MouseArea` that owns them. The bar's position is then whatever `shell.json`
says and nothing but an edit can change it.

Dragging individual *widgets* to rearrange them still works — that is a
separate handler and is untouched.

## Sibling project: Literate Workspaces

[Literate Workspaces](https://github.com/andyszy/literate-workspaces) replaces
the numbered workspace indicators with a Phosphor icon and a short name per
workspace, chosen by a model from the windows open there; hold Super and the
icons turn back into numbers. It is a separate plugin so each project tracks
its own upstream, but the two are meant to be used together:

```bash
omarchy plugin add https://github.com/andyszy/literate-bar.git --enable
omarchy plugin add https://github.com/andyszy/literate-workspaces.git --enable
```

## Install

```bash
omarchy plugin add https://github.com/andyszy/literate-bar.git --enable
```

Then confirm it took:

```bash
hyprctl layers | grep omarchy-bar     # the layer should be present
```

Remove it with `omarchy plugin remove literate.bar`, which restores the
built-in bar.

## Which branch you want

The Omarchy bar is vendored, not subclassed — QML gives no way to reach into a
nested component and delete a gesture from outside. So this repo carries a full
copy of the bar, and the copy has to match the shell it runs against: `Bar.qml`
imports `Style`, `Color` and `BarModel` from the host, and those drift between
releases.

| Branch | Vendored from | For |
|---|---|---|
| `main-mac` (default) | [`omarchy-mac/omarchy-mac`](https://github.com/omarchy-mac/omarchy-mac) | Omarchy on Apple Silicon |
| `main-basecamp` | [`basecamp/omarchy`](https://github.com/basecamp/omarchy) `v4.0.3` | mainline Omarchy |
| `upstream-mac`, `upstream-basecamp` | — | pristine vendor bases, no patches |

`main-mac` is the default branch because `omarchy plugin update` fetches
`origin HEAD` and merges `--ff-only`; a default branch you are not tracking
makes every update fail to fast-forward.

On mainline Omarchy, install the other branch by hand:

```bash
git clone -b main-basecamp https://github.com/andyszy/literate-bar.git \
  ~/.config/omarchy/plugins/literate.bar
omarchy plugin enable literate.bar
```

If neither branch matches your Omarchy, re-vendor from your own install —
see below.

## The patches

Kept as a script rather than as commits, so they can be replayed onto a new
upstream instead of rebased through conflicts. `tools/apply-patches.py` is
idempotent and exits non-zero if a patch site has changed shape, so a bad
re-sync fails loudly instead of shipping a half-patched bar.

1. **Rename the plugin** — `manifest.json` becomes `literate.bar` /
   "Literate Bar". The `omarchy.*` id namespace is reserved.
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

## Re-syncing after an Omarchy release

```bash
git checkout upstream-mac
tools/sync-upstream                      # or: tools/sync-upstream /path/to/checkout
git commit -am "Vendor bar from omarchy-mac <version>"
git checkout main-mac && git merge upstream-mac
```

`tools/sync-upstream` re-vendors every file upstream ships, preserving this
fork's `README.md` and `tools/`, then re-applies the patches. Repeat for
`upstream-basecamp` / `main-basecamp`.

## Credit and license

All of the interesting code is Omarchy's, by DHH and the Omarchy contributors,
MIT licensed. This fork is three small patches on top; the upstream license and
copyright carry over unchanged.
