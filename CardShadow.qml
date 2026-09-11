import QtQuick
import QtQuick.Effects
import qs.Commons

// A single soft drop-shadow, shared by every card-style surface this plugin
// draws. The workspace action menu and the triage view both render inside
// the same `card` BorderSurface in Overlay.qml, so one
// `CardShadow { target: card }` already covers both; a future surface just
// adds another one-liner instead of copy-pasting an effect.
//
// This is its own proxy Rectangle sitting behind `target`, with a
// MultiEffect shadow layered onto that proxy -- not onto `target` itself.
// BorderSurface already uses `layer.effect` internally for its own
// gradient-border overlay, and stacking a second layer effect on the same
// item would fight that one instead of composing with it.
//
// Colour is intentionally not theme-derived: a shadow reads as an absence of
// light, which is black at low opacity whether the surface it falls under is
// light or dark -- Linear's own dark mode still shadows in black, not white.
// Only the geometry (blur radius, offset) scales with Style's spacing token,
// so it stays proportionate if the user changes the base font size.
Rectangle {
  id: root

  required property Item target
  // How dark the shadow reads at its densest point, just under the card.
  // Large + soft (think a macOS sheet) rather than a tight drop shadow, so
  // this stays low even though the blur radius below is generous.
  property real intensity: 0.24

  anchors.fill: target
  radius: target.radius || 0
  color: "black"
  z: target.z - 1
  visible: target.visible

  layer.enabled: true
  layer.effect: MultiEffect {
    shadowEnabled: true
    shadowColor: "black"
    shadowOpacity: root.intensity
    shadowBlur: 1.0
    shadowScale: 1.0
    shadowVerticalOffset: Style.space(18)
    shadowHorizontalOffset: 0
    blurMax: Style.space(80)
    autoPaddingEnabled: true
  }
}
