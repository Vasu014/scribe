import AppKit

/// Small formatting helpers shared by the menu bar capsule and (later) the
/// scratchpad header and History meta rows. Anything that ticks uses SF Mono
/// with tabular numerals (design/README "Design Tokens").
enum Formatting {

    /// Elapsed-time font: SF Mono per the design tokens, falling back to the
    /// system font with monospaced (tabular) digits if SF Mono can't be
    /// resolved for the requested weight.
    static func elapsedFont(ofSize size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: "SF Mono",
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        if let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// Wall-clock elapsed → `mm:ss` (e.g. `24:16`) or `h:mm:ss` once an hour
    /// rolls over — mirroring the per-timestamp forms in SPEC §4.5. The input
    /// is floored so the display never jumps ahead of the tick. Menu-bar
    /// elapsed derives from wall clock, never the session clock (SPEC §4.1).
    static func elapsedString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
