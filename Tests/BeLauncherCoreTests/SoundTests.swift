import Testing
import Foundation
@testable import BeLauncherCore

/// Un sonido que se oye cincuenta veces al día tiene reglas, y son medibles.
@Suite("El sonido de «ya lo tengo»")
struct SoundTests {

    @Test("ninguno dura lo suficiente como para estorbar")
    func allAreShort() {
        for cue in Sound.Cue.allCases {
            let ms = Sound.duration(of: cue) * 1_000
            #expect(ms > 30, "\(cue) es tan corto que no se oye")
            #expect(ms < 250,
                    "\(cue) dura \(Int(ms))ms y se oye a diario: tiene que acabar antes de que termines de notarlo")
        }
    }

    @Test("abrir y cerrar son mucho más discretos que copiar")
    func chromeIsQuieter() {
        let taken = Sound.samples(for: .taken).map(abs).max() ?? 0
        for cue in [Sound.Cue.opened, .closed] {
            let peak = Sound.samples(for: cue).map(abs).max() ?? 0
            #expect(peak < taken * 0.6,
                    "\(cue) suena cientos de veces al día; si iguala a copiar, cansa")
            #expect(Sound.duration(of: cue) < Sound.duration(of: .taken))
        }
    }

    @Test("nada recorta, que suena a altavoz roto y no a app")
    func neverClips() {
        for cue in Sound.Cue.allCases {
            let peak = Sound.samples(for: cue).map(abs).max() ?? 0
            #expect(peak <= 0.9, "\(cue) llega a \(peak)")
            #expect(peak > 0.02, "\(cue) es inaudible")
        }
    }

    @Test("empiezan desde el silencio, sin el clic que abarata un sonido")
    func fadesInFromSilence() throws {
        for cue in Sound.Cue.allCases {
            let samples = Sound.samples(for: cue)
            let first = try #require(samples.first)
            #expect(abs(first) < 0.01, "\(cue) arranca en \(first): eso es un clic")
        }
    }

    @Test("y terminan apagándose, no cortados a hachazo")
    func decaysToSilence() throws {
        for cue in Sound.Cue.allCases {
            let samples = Sound.samples(for: cue)
            let last = try #require(samples.last)
            #expect(abs(last) < 0.03, "\(cue) acaba en \(last): eso es un corte")
        }
    }

    @Test("el WAV es un WAV de verdad, con cabecera correcta")
    func producesAValidWAV() throws {
        let data = Sound.wav(for: .taken)
        #expect(data.count > 44, "solo cabecera y nada de sonido")

        let header = { (offset: Int) in String(decoding: data[offset..<(offset + 4)], as: UTF8.self) }
        #expect(header(0) == "RIFF")
        #expect(header(8) == "WAVE")
        #expect(header(12) == "fmt ")
        #expect(header(36) == "data")

        // Mono, 16 bits, 44.1 kHz: lo que dice la cabecera tiene que ser lo que hay detrás.
        let channels = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: UInt16.self) }
        let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 34, as: UInt16.self) }
        let rate = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }
        #expect(channels == 1)
        #expect(bits == 16)
        #expect(rate == 44_100)

        let declared = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) }
        #expect(Int(declared) == data.count - 44, "la longitud declarada no cuadra con los datos")
    }

    @Test("cada sonido es distinto de los demás")
    func eachOneIsItsOwn() {
        // Si dos coinciden, uno de los dos no informa de nada.
        let all = Sound.Cue.allCases.map { Sound.wav(for: $0) }
        #expect(Set(all).count == all.count)
    }

    @Test("todos tienen nombre para poder apagarlos con conocimiento")
    func allAreExplainable() {
        for cue in Sound.Cue.allCases {
            #expect(cue.label.count > 5)
            #expect(!cue.notes.isEmpty)
        }
    }
}
