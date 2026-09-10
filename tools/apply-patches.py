#!/usr/bin/env python3
"""Apply the Literate Bar patches to a vendored copy of the Omarchy bar.

Idempotent: running it on an already-patched tree is a no-op. Exits non-zero
if upstream has changed shape enough that a patch no longer applies, so a
re-sync fails loudly instead of producing a half-patched bar.
"""

import json
import sys
from pathlib import Path

PLUGIN_ID = "literate.bar"
PLUGIN_NAME = "Literate Bar"

# manifest.json is re-vendored from upstream on every sync -- it is deliberately
# not in sync-upstream's --exclude list -- so every field this fork depends on
# has to be re-stated here. Anything merely edited by hand in the checkout is
# gone after the next sync. In particular the bar-widget registration lives
# here: drop it and the workspace widget silently stops being discovered.
FORK_MANIFEST = {
    "id": PLUGIN_ID,
    "name": PLUGIN_NAME,
    "author": "andyszy",
    "description": "Omarchy's bar without the misclick gestures, and workspaces named by a model",
    "kinds": ["bar", "bar-widget"],
    "entryPoints": {"bar": "Bar.qml", "barWidget": "Workspaces.qml"},
    "barWidget": {
        "displayName": "Literate Workspaces",
        "description": "Workspaces named by a model, with a Phosphor icon each",
        "category": "Compositor",
        "allowMultiple": False,
        "defaultSection": "left",
    },
}


def patch_manifest(path: Path) -> None:
    manifest = json.loads(path.read_text())
    manifest.update(FORK_MANIFEST)
    path.write_text(json.dumps(manifest, indent=2) + "\n")


def unrequire_injected_properties(src: str) -> str:
    """Drop `required` from the three properties the host injects late.

    shell.qml loads a non-default bar with `Loader { source: url }` and only
    then assigns these, in configureBar() from onLoaded. QML required
    properties must be supplied at construction, so a required declaration
    makes any third-party bar die with "Required property was not
    initialized" -- and the fallback to the built-in bar throws ReferenceError
    on an undefined `errorString`, so the failure leaves no bar at all.

    basecamp/omarchy already declares these as plain properties ("declaring it
    keeps clone construction atomic"); omarchy-mac's fork regressed them. Skip
    the patch on an upstream that never needed it.
    """
    replacements = [
        ("  required property string omarchyPath\n",
         '  property string omarchyPath: Quickshell.env("OMARCHY_PATH")\n',
         "  property string omarchyPath"),
        ("  required property var barWidgetRegistry\n",
         "  property var barWidgetRegistry: fallbackBarWidgetRegistry\n",
         "  property var barWidgetRegistry"),
        ("  required property var barConfig\n",
         "  property var barConfig: ({})\n",
         "  property var barConfig"),
    ]
    for required_form, patched_form, plain_prefix in replacements:
        if required_form in src:
            src = src.replace(required_form, patched_form, 1)
        elif plain_prefix not in src:
            sys.exit(f"neither `{required_form.strip()}` nor a plain declaration found")
    return src


def remove_gesture_area(src: str) -> str:
    """Remove the empty-bar gesture MouseArea.

    It carried two gestures: dragging moved the bar between screen edges, and
    double-clicking toggled bar.transparent. Nothing else lives in it, so the
    whole component goes along with its two instantiations.
    """
    usage = "\n        CenterGestureArea { anchors.fill: parent }\n"
    start_marker = "  component CenterGestureArea: MouseArea {"
    end_marker = "  component ModuleList: Loader {"

    if usage not in src and start_marker not in src:
        return src  # already patched
    if src.count(usage) != 2 or start_marker not in src or end_marker not in src:
        sys.exit("CenterGestureArea no longer has the expected shape")

    src = src.replace(usage, "\n")
    start, end = src.index(start_marker), src.index(end_marker)
    return src[:start] + src[end:]


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    patch_manifest(root / "manifest.json")

    bar = root / "Bar.qml"
    src = original = bar.read_text()
    src = unrequire_injected_properties(src)
    src = remove_gesture_area(src)
    if src != original:
        bar.write_text(src)
    print(f"patched {root}")


if __name__ == "__main__":
    main()
