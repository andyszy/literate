# Working on Literate Bar

This repo is a **vendored fork** of Omarchy's bar plugin, not a plugin that
extends it. The gestures being removed live inside a nested QML component
(`CenterGestureArea` inside `Bar.qml`), and QML gives no way to reach into a
nested component and delete something from outside the file. So the whole bar
is copied here, and three small patches are applied on top.

Everything below is a thing that has already gone wrong once.

## The vendored copy must match the installed shell

`Bar.qml` imports `Style`, `Color` and `BarModel` from the host shell. A bar
vendored from a different Omarchy release can break on API drift, so the branch
you install has to match the Omarchy you run.

## `/usr/share/omarchy` is not necessarily basecamp's tree

On Apple Silicon it is **omarchy-mac/omarchy-mac**, byte-for-byte — even though
`pacman -Qi omarchy` reports `https://github.com/basecamp/omarchy` as the URL.
At Omarchy 4.0.3 the two bars differ by 265 lines, including the Apple Silicon
notch handling (`appleSiliconHost`, `notchFloor`) that basecamp has no trace of.
Diff against the fork you actually run before concluding anything about
"upstream". Never edit `/usr/share/omarchy` — it is package-owned and an
`omarchy update` overwrites it.

## Branches

| Branch | Role |
|---|---|
| `upstream-mac`, `upstream-basecamp` | pristine vendor bases, no patches, never edit by hand |
| `main-mac` (default), `main-basecamp` | vendor base + patches |

**The default branch must be the one the repo owner runs.** `omarchy plugin
update` fetches `origin HEAD` and merges `--ff-only`; if the remote default is a
branch the local checkout is not tracking, every update fails to fast-forward.

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

It rsyncs `--delete` from the upstream bar directory. Fork-owned files survive
only because they are named in its `--exclude` list. **Add any new
fork-owned file to that list** or the next sync silently deletes it.

## `active: true` does not mean the bar rendered

`omarchy-shell shell listPlugins` reporting `"active": true` only means the
plugin was *selected* as the bar provider. A bar that throws during
construction still reads as active. Verify with the compositor instead:

```bash
hyprctl layers | grep omarchy-bar      # the layer must exist
hyprctl monitors | grep reserved       # e.g. "reserved: 0 32 0 0" for a top bar
```

Trusting `active: true` once meant shipping a bar that did not exist.

## A broken bar leaves *no* bar, not the stock one

`shell.qml` is supposed to fall back to the built-in bar when a plugin bar fails
to load, but that handler throws `ReferenceError: errorString is not defined`
before it can set `failedBarId`. So a bad patch here does not degrade to the
default bar — it leaves the desktop with no bar at all.

Recover with:

```bash
omarchy plugin enable omarchy.bar
```

Errors that never reach the log because of that same bug can be read with:

```bash
quickshell -n -p /usr/share/omarchy/shell log | tail -40
```

## Testing the drift hook notifies for real

The `check-literate-bar-drift` hook (which lives in the owner's `~/.config`, not
this repo) calls `omarchy-notification-send`. Exercising its drift path pushes a
real notification onto a real desktop. Use its `--quiet` flag.

## Plugin ids

`omarchy.*` is a reserved namespace and `omarchy plugin validate` rejects it.
This fork is `literate.bar`. The install directory name must equal the manifest
id. Run `omarchy plugin validate .` on both `main-*` branches before pushing.

## Sibling: Literate Workspaces

[Literate Workspaces](https://github.com/andyszy/literate-workspaces)
(`literate.workspaces`) replaces the stock workspace indicators and is meant
to be installed alongside this bar. It is a **separate plugin on purpose**:
the shell only registers third-party widgets that sit at the top level of
`~/.config/omarchy/plugins`, so a widget inside this repo's `widgets/` would
never be discovered (this vendored `widgets/` directory is dead code when
the bar runs under the host shell — slots resolve every layout id through
the host's `barWidgetRegistry`). Consequences for work here:

- The bar needs **no patch** to host it. If the widget stops rendering after
  a re-vendor, the suspects are `ModuleSlot` / `injectProps` in `Bar.qml`
  (how a registry component gets `bar`, `moduleName`, `settings`), not the
  widget.
- Its IPC target is `literate.workspaces` (`showNumbers` / `hideNumbers`,
  driven by Hyprland on Super press/release). Don't reuse that id.
- Widget bugs belong in that repo; read its `CLAUDE.md` before touching it.

