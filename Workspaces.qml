import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Literate Workspaces: indicators that show what you're actually doing on
// each workspace -- its number, a Phosphor icon and a short name, the last two
// chosen by a model. The names come from bin/literate-workspace-namer, which
// watches Hyprland's socket and writes
// ~/.local/state/literate-workspaces/workspaces.json. When the daemon isn't
// running this degrades to the stock number indicators.
BarWidget {
  id: root
  moduleName: "literate.bar"

  // "all"     - every named workspace spells its name out (default)
  // "focused" - only the focused workspace does
  // "never"   - number and icon only
  readonly property string nameMode: root.setting("showNames", "all")
  // Paint the focused workspace in the bar's active colour. Off by default:
  // the name being bright is already an unmissable focus cue.
  readonly property bool accentFocused: root.setting("accentFocused", false)
  // Space between one workspace and the next, and before the first one, in em.
  readonly property real gap: root.setting("gap", 1.0)
  readonly property real gapPx: Math.round(Style.font.body * root.gap)

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  property var names: ({})
  property var codepoints: ({})

  FontLoader {
    id: phosphor
    source: Qt.resolvedUrl("fonts/Phosphor.ttf")
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/literate-workspaces/workspaces.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.names = JSON.parse(text())
    onLoadFailed: root.names = ({})
  }

  FileView {
    path: root.pluginDir + "phosphor-codepoints.json"
    printErrors: false
    onLoaded: root.codepoints = JSON.parse(text())
  }

  // Phosphor lives in the BMP private use area, so a single char is enough.
  function glyph(iconName) {
    var cp = root.codepoints[iconName]
    return cp ? String.fromCharCode(parseInt(cp, 16)) : ""
  }

  function entryFor(id) {
    return root.names[String(id)] || null
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  readonly property real leadingGap: root.vertical ? 0 : root.gapPx
  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: leadingGap + grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  Behavior on implicitWidth {
    enabled: !root.vertical
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.leftMargin: root.leadingGap
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : root.gapPx
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      RowLayout {
        id: slot
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
        readonly property var entry: root.entryFor(modelData)
        readonly property string iconGlyph: entry ? root.glyph(entry.icon) : ""
        readonly property string number: modelData === 10 ? "0" : String(modelData)
        readonly property real tone: focused ? 1 : (occupied ? 0.6 : 0.35)
        // Vertical bars have no room to spell anything out.
        readonly property bool nameVisible: !root.vertical && entry && entry.name !== ""
          && (root.nameMode === "all" || (root.nameMode === "focused" && focused))

        spacing: 0

        // The number: always there, so the Super chord is always readable.
        WidgetButton {
          bar: root.bar
          text: slot.number
          fontSize: Style.font.body
          active: slot.focused && root.accentFocused
          opacity: slot.tone
          horizontalMargin: 0
          verticalPadding: 6
          fixedWidth: root.vertical ? root.barSize : -1
          fixedHeight: root.barSize
          tooltipText: slot.entry ? slot.entry.name : ""
          onPressed: function() { root.focusWorkspace(slot.modelData) }
        }

        // The icon, once the daemon has named the workspace.
        WidgetButton {
          visible: slot.iconGlyph !== ""
          bar: root.bar
          text: slot.iconGlyph
          fontFamily: phosphor.font.family
          fontSize: Style.bar.iconFont
          active: slot.focused && root.accentFocused
          opacity: slot.tone
          horizontalMargin: 0
          verticalPadding: 6
          fixedHeight: root.barSize
          Layout.leftMargin: slot.iconGlyph !== "" ? Style.spaceReal(2) : 0
          tooltipText: slot.entry ? slot.entry.name : ""
          onPressed: function() { root.focusWorkspace(slot.modelData) }
        }

        // The name itself. Never elided: keeping it short is the model's job.
        WidgetButton {
          visible: slot.nameVisible
          bar: root.bar
          text: slot.nameVisible ? slot.entry.name : ""
          active: slot.focused && root.accentFocused
          opacity: slot.tone
          fontSize: Style.font.body
          horizontalMargin: 0
          verticalPadding: 6
          fixedHeight: root.barSize
          Layout.leftMargin: slot.nameVisible ? Style.spaceReal(1.5) : 0
          onPressed: function() { root.focusWorkspace(slot.modelData) }
        }
      }
    }
  }
}
