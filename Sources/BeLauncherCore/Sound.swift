import Foundation

/// The little sound that says "taken".
///
/// The window disappears the instant you press Enter, which is right — but it leaves nothing
/// behind, so for a moment you do not know whether it worked. A sound is the cheapest possible
/// confirmation: it costs no pixels, no delay and no attention, and it arrives while you are
/// already looking somewhere else.
///
/// It is synthesised rather than shipped as a file. A launcher that borrows a stock chime sounds
/// like every other app on the machine, and the whole point is that you learn *this* sound and
/// stop thinking about it. Building it from tones also means it can be tuned by changing two
/// numbers instead of re-recording anything.
///
/// The design rules, which are what keep it from becoming annoying at fifty times a day:
/// under 200 milliseconds, quiet enough to sit under whatever else is playing, no click at the
/// start, and pitched high so it cuts through speech without being shrill.
public enum Sound {

    public struct Note: Sendable, Equatable {
        public let frequency: Double
        /// Seconds from the beginning of the sound.
        public let start: Double
        public let duration: Double
        public let amplitude: Double

        public init(frequency: Double, start: Double, duration: Double, amplitude: Double) {
            self.frequency = frequency
            self.start = start
            self.duration = duration
            self.amplitude = amplitude
        }
    }

    public enum Cue: String, Sendable, CaseIterable {
        /// The launcher took what you gave it: a copy, a snippet, an answer.
        case taken
        /// Something went into the brain and is waiting for you to confirm it.
        case proposed
        /// It could not.
        case refused
        /// The window arrived.
        case opened
        /// And left.
        case closed

        public var label: String {
            switch self {
            case .taken: L("When you copy")
            case .proposed: L("When it offers a memory")
            case .refused: L("When something fails")
            case .opened: L("When the window opens")
            case .closed: L("When it closes")
            }
        }

        /// Two notes rising a fifth for "taken" — the shape ears read as a question answered.
        /// The pair is deliberately not a major third, which is the sound every notification on
        /// the machine already makes.
        public var notes: [Note] {
            switch self {
            case .taken:
                [
                    Note(frequency: 1_174.66, start: 0, duration: 0.085, amplitude: 0.22),
                    Note(frequency: 1_760.00, start: 0.052, duration: 0.105, amplitude: 0.19),
                ]
            case .proposed:
                // The same interval, held a touch longer and softer: something happened, but it
                // is still waiting for you.
                [
                    Note(frequency: 987.77, start: 0, duration: 0.10, amplitude: 0.17),
                    Note(frequency: 1_318.51, start: 0.065, duration: 0.13, amplitude: 0.15),
                ]
            case .refused:
                // Falling, and only just audible. A failure sound loud enough to startle makes
                // people switch sound off entirely, which loses the useful one too.
                [
                    Note(frequency: 622.25, start: 0, duration: 0.09, amplitude: 0.16),
                    Note(frequency: 466.16, start: 0.055, duration: 0.12, amplitude: 0.14),
                ]
            case .opened:
                // A single tick, half the length and a third of the volume of the others. This
                // one fires every time the window appears — a hundred times a day — so it has to
                // be closer to a key press than to a chime.
                [Note(frequency: 1_567.98, start: 0, duration: 0.045, amplitude: 0.07)]
            case .closed:
                [Note(frequency: 1_046.50, start: 0, duration: 0.040, amplitude: 0.055)]
            }
        }
    }

    public static let sampleRate = 44_100.0

    /// How long the whole thing lasts. Kept under a fifth of a second on purpose: anything you
    /// hear fifty times a day has to be over before you have finished noticing it.
    public static func duration(of cue: Cue) -> Double {
        cue.notes.map { $0.start + $0.duration }.max() ?? 0
    }

    /// The waveform, as samples between -1 and 1.
    ///
    /// Each note is a sine with a little third harmonic for body and an exponential decay, which
    /// together read as a pluck rather than a beep. The three-millisecond fade in is not
    /// decoration: a sine that starts at full amplitude produces an audible click, and a click is
    /// exactly what makes a sound feel cheap.
    public static func samples(for cue: Cue, sampleRate: Double = Sound.sampleRate) -> [Float] {
        let total = Int((duration(of: cue) * sampleRate).rounded(.up))
        guard total > 0 else { return [] }
        var buffer = [Float](repeating: 0, count: total)

        let fadeIn = 0.003
        for note in cue.notes {
            let first = Int(note.start * sampleRate)
            let count = Int(note.duration * sampleRate)
            for index in 0..<count {
                let position = first + index
                guard position < total else { break }
                let time = Double(index) / sampleRate

                let attack = min(1, time / fadeIn)
                let decay = exp(-time / (note.duration * 0.32))
                let phase = 2 * Double.pi * note.frequency * time
                let tone = sin(phase) + 0.18 * sin(phase * 3)

                buffer[position] += Float(note.amplitude * attack * decay * tone)
            }
        }

        // Two overlapping notes can add past 1 and clip, which sounds like a fault in the speaker
        // rather than a sound in an app.
        let peak = buffer.map(abs).max() ?? 0
        if peak > 0.9 {
            let scale = 0.9 / peak
            for index in buffer.indices { buffer[index] *= scale }
        }
        return buffer
    }

    /// A complete WAV file in memory, so it can be handed straight to the system with no file on
    /// disk and nothing to install.
    public static func wav(for cue: Cue, sampleRate: Double = Sound.sampleRate) -> Data {
        let samples = samples(for: cue, sampleRate: sampleRate)
        var data = Data()

        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }

        let bytesPerSample = 2
        let payload = UInt32(samples.count * bytesPerSample)

        append("RIFF")
        append(UInt32(36) + payload)
        append("WAVE")
        append("fmt ")
        append(UInt32(16))                       // PCM header length
        append(UInt16(1))                        // PCM, uncompressed
        append(UInt16(1))                        // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * UInt32(bytesPerSample))
        append(UInt16(bytesPerSample))
        append(UInt16(16))                       // bits per sample
        append("data")
        append(payload)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(UInt16(bitPattern: Int16(clamped * 32_767)))
        }
        return data
    }
}
