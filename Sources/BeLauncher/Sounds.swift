import AppKit
import BeLauncherCore

/// Plays the cues, once each and never on top of themselves.
@MainActor
enum Sounds {

    /// Built once. Synthesising 8000 samples per keystroke would be silly, and an `NSSound`
    /// re-created each time restarts audio hardware that is already warm.
    private static var cached: [Sound.Cue: NSSound] = [:]

    /// The copy sound: the one that answers "did it take it?", so it is on.
    static var enabled = true
    /// Opening and closing: a hundred times a day, so off until asked for. A sound that wears
    /// people out gets sound switched off entirely, and that costs the useful one too.
    static var chromeEnabled = false

    static func play(_ cue: Sound.Cue) {
        guard enabled else { return }
        if cue == .opened || cue == .closed, !chromeEnabled { return }
        let sound = cached[cue] ?? {
            let made = NSSound(data: Sound.wav(for: cue))
            cached[cue] = made
            return made
        }()
        guard let sound else { return }
        // Retriggering while it is still ringing sounds like a stutter, not two events.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Lets the person hear it before deciding whether they want it.
    static func preview(_ cue: Sound.Cue) {
        let wasEnabled = enabled
        enabled = true
        play(cue)
        enabled = wasEnabled
    }
}
