import Foundation

/// How many frames a second a scene should draw, given what it is showing and
/// what the Mac can spare. One table for every kind of scene.
///
/// Whether to draw at all (covered, asleep, paused) is decided elsewhere, in
/// `AppDelegate.updatePlayback()`; this only sets the pace while drawing.
enum FramePolicy {
    /// What the picture is doing right now.
    enum Hint {
        case still      // nothing moves faster than the sun
        case slow       // drifting clouds: updates above ten a second are invisible
        case lively     // stars twinkling, aurora, a generic animated scene
        case moving     // something the eye tracks: ridges following the pointer, a time-lapse
        case burst      // a second or so of fast motion (a shooting star)
    }

    struct Conditions: Equatable {
        var saving = false           // Low Power Mode, or the Mac is hot
        var onBattery = false
        var desktopInFront = false   // the user is looking at the desktop
    }

    static func rate(_ c: Conditions, hint: Hint, cap: Float = 60) -> Float {
        let rate: Float
        if c.saving {
            rate = hint == .still ? 1 : 5
        } else {
            switch hint {
            case .still: rate = 1
            case .slow: rate = c.onBattery && !c.desktopInFront ? 6 : 10
            case .lively: rate = c.desktopInFront ? (c.onBattery ? 15 : 20) : (c.onBattery ? 6 : 10)
            case .moving: rate = 30
            case .burst: rate = c.onBattery || !c.desktopInFront ? 30 : 60
            }
        }
        return max(1, min(rate, cap))
    }
}

extension Conditions {
    var framePolicy: FramePolicy.Conditions {
        FramePolicy.Conditions(saving: saving, onBattery: onBattery, desktopInFront: desktopInFront)
    }
}
