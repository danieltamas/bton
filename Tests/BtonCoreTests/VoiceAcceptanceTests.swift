import Foundation
import Testing
@testable import BtonCore

/// Written by the implementer from docs/superpowers/specs/2026-10-27-voice-input.md, not by another author.
private struct Canned: Transcriber {
    let text: String
    func transcribe(_ samples: [Float], language: String?) async throws -> String { text }
}

private func tone(seconds: Double, amplitude: Float) -> [Float] {
    (0 ..< Int(seconds * Voice.sampleRate)).map { amplitude * sin(Float($0) * 0.05) }
}

@Suite struct VoiceAcceptanceTests {
    @Test func silenceIsNeverTranscribed() async {
        let silence = [Float](repeating: 0, count: Int(Voice.sampleRate))
        await #expect(throws: VoiceError.nothingHeard) {
            try await Voice.text(of: silence, language: nil, using: Canned(text: "invented words"))
        }
    }

    @Test func speechBetweenSilenceIsHeard() async throws {
        let samples = [Float](repeating: 0, count: 16_000) + tone(seconds: 0.5, amplitude: 0.3)
        #expect(Voice.hasSpeech(samples))
        #expect(try await Voice.text(of: samples, language: "ro", using: Canned(text: "  bună ziua \n")) == "bună ziua")
    }

    @Test func anEmptyResultIsNothingHeard() async {
        await #expect(throws: VoiceError.nothingHeard) {
            try await Voice.text(of: tone(seconds: 1, amplitude: 0.3), language: nil, using: Canned(text: " \n"))
        }
    }

    @Test func barsRiseWithTheVoiceAndSitFlatInSilence() {
        #expect(Voice.barHeight(rms: 0) == 0)
        #expect(Voice.barHeight(rms: 0.2) == 1)
        #expect(Voice.barHeight(rms: 0.03) > Voice.barHeight(rms: 0.012))
    }

    @Test func dictationAppendsToWhatIsTyped() {
        #expect(Voice.appending("two", to: "") == "two")
        #expect(Voice.appending("two", to: "one \n") == "one two")
    }

    @Test func everyModelNamesAWhisperKitVariantAndRomanianIsOffered() {
        #expect(Set(VoiceModel.allCases.map(\.variant)).count == VoiceModel.allCases.count)
        #expect(VoiceModel.allCases.allSatisfy { $0.variant.hasPrefix("openai_whisper-") })
        #expect(VoiceModel.languages.map(\.code).contains("ro"))
    }

    @Test func settingsRoundTripAndAnOldConfigHasNone() throws {
        let settings = VoiceSettings(enabled: true, model: .small, language: "ro")
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(VoiceSettings.self, from: data) == settings)
        var config = BtonConfig.initial
        config.voice = settings
        let encoded = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(BtonConfig.self, from: encoded).voice == settings)
        let old = try JSONEncoder().encode(BtonConfig.initial)
        #expect(try JSONDecoder().decode(BtonConfig.self, from: old).voice == nil)
    }

    @Test func compatibilityChecksSayWhatThisMacCannotDo() {
        let gig: Int64 = 1 << 30
        let roomy = Voice.checks(for: .turbo, downloaded: false, freeBytes: 50 * gig, memoryBytes: 32 << 30, appleSilicon: true)
        #expect(roomy.isEmpty)
        let full = Voice.checks(for: .turbo, downloaded: false, freeBytes: gig, memoryBytes: 32 << 30, appleSilicon: true)
        #expect(full.map(\.blocking) == [true])
        // Space only matters until the model is on disk.
        #expect(Voice.checks(for: .turbo, downloaded: true, freeBytes: 0, memoryBytes: 32 << 30, appleSilicon: true).isEmpty)
        let small = Voice.checks(for: .turbo, downloaded: true, freeBytes: nil, memoryBytes: 8 << 30, appleSilicon: false)
        #expect(small.count == 2 && small.allSatisfy { !$0.blocking })
        #expect(Voice.checks(for: .small, downloaded: true, freeBytes: nil, memoryBytes: 8 << 30, appleSilicon: true).isEmpty)
    }

    @Test func recordingIsCutAtAPauseNeverMidWord() {
        let rate = Int(Voice.sampleRate)
        let speech = tone(seconds: 7, amplitude: 0.3)
        // Too short to cut yet, even though it holds a pause.
        #expect(Voice.cutPoint(in: tone(seconds: 2, amplitude: 0.3) + [Float](repeating: 0, count: rate)) == nil)
        // Speech all the way: kept until the hard limit.
        #expect(Voice.cutPoint(in: speech) == nil)
        #expect(Voice.cutPoint(in: tone(seconds: 26, amplitude: 0.3)) == 26 * rate)
        // A pause after 7 s of speech is where it is cut, and the cut sits inside the pause.
        let paused = speech + [Float](repeating: 0, count: rate) + tone(seconds: 1, amplitude: 0.3)
        let cut = Voice.cutPoint(in: paused)
        #expect(cut != nil && cut! > 7 * rate && cut! <= 8 * rate + rate / 3)
    }
}
