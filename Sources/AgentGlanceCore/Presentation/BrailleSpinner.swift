import Foundation

/// The braille dot-matrix frames and cadence shared by every working spinner
/// (the ora / Convoy progress style). Extracted from the view so the
/// frame-selection clock math is unit-testable, and so independently mounted
/// spinners advance from one absolute-clock source in lockstep.
public enum BrailleSpinner {
    /// Seconds each frame is held before advancing.
    public static let stepInterval: TimeInterval = 0.08

    /// The ten-frame braille cycle: several dots lit per frame rather than one
    /// pixel chasing itself.
    public static let frames: [Character] = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// Index into `frames` for a clock reading, advancing exactly one frame per
    /// `stepInterval`. Referenced to the absolute clock the animation samples,
    /// so every visible spinner stays in phase. The step is floored and the
    /// modulo taken floor-style, so readings before the reference date still
    /// land in range instead of producing a negative index.
    public static func frameIndex(at date: Date) -> Int {
        let step = Int((date.timeIntervalSinceReferenceDate / stepInterval).rounded(.down))
        let count = frames.count
        return ((step % count) + count) % count
    }

    public static func frame(at date: Date) -> Character {
        frames[frameIndex(at: date)]
    }
}
