import Foundation

/// Voice input for a new issue (Settings > Voice). Off until switched on.
public struct VoiceSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// nil: `VoiceModel.defaultModel`.
    public var model: VoiceModel?
    /// An ISO 639-1 code such as "ro"; nil: detected per recording.
    public var language: String?

    public init(enabled: Bool, model: VoiceModel? = nil, language: String? = nil) {
        self.enabled = enabled
        self.model = model
        self.language = language
    }
}

/// The Whisper models Bton offers, as WhisperKit names them in `argmaxinc/whisperkit-coreml`.
public enum VoiceModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case turbo, small

    public var id: Self { self }
    public static let defaultModel = VoiceModel.turbo

    public var label: String {
        switch self {
        case .turbo: "Large v3 turbo"
        case .small: "Small"
        }
    }

    public var detail: String {
        switch self {
        case .turbo: "Most accurate, about 0.6 GB download"
        case .small: "Lighter and faster, about 0.5 GB download"
        }
    }

    /// What the download takes on disk.
    public var downloadBytes: Int64 {
        switch self {
        case .turbo: 650_000_000
        case .small: 520_000_000
        }
    }

    /// Memory below which loading it is likely to swap.
    public var comfortableMemoryBytes: UInt64 {
        switch self {
        case .turbo: 16 << 30
        case .small: 8 << 30
        }
    }

    public var variant: String {
        switch self {
        case .turbo: "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .small: "openai_whisper-small"
        }
    }

    /// Both are multilingual: Romanian and English are among the languages they cover.
    public static let languages: [(code: String, name: String)] = [("ro", "Romanian"), ("en", "English")]
}

/// Speech to text. The recorder and the engine sit behind it so the New issue view is tested with canned text.
public protocol Transcriber: Sendable {
    /// `samples` are 16 kHz mono floats; the audio is never written to disk.
    func transcribe(_ samples: [Float], language: String?) async throws -> String
}

public enum VoiceError: Error, LocalizedError, Equatable {
    case nothingHeard
    case microphoneDenied
    case modelMissing
    case noMicrophone

    public var errorDescription: String? {
        switch self {
        case .nothingHeard: "No speech was heard."
        case .microphoneDenied: "Bton cannot use the microphone. Allow it in System Settings > Privacy & Security > Microphone."
        case .modelMissing: "The voice model is not downloaded yet: Settings > Voice."
        case .noMicrophone: "No microphone was found. Connect one, or pick an input in System Settings > Sound."
        }
    }
}

/// Something about this Mac that matters to voice input: a `blocking` one stops the action, a warning only says.
public struct VoiceCheck: Hashable, Sendable {
    public let blocking: Bool
    public let message: String
}

public enum Voice {
    /// What to tell before a model is downloaded or used on this Mac. Disk only matters until it is downloaded.
    public static func checks(for model: VoiceModel, downloaded: Bool, freeBytes: Int64?, memoryBytes: UInt64,
                              appleSilicon: Bool) -> [VoiceCheck] {
        var found: [VoiceCheck] = []
        if !downloaded, let freeBytes, freeBytes < model.downloadBytes * 2 {
            let need = ByteCountFormatter.string(fromByteCount: model.downloadBytes * 2, countStyle: .file)
            found.append(VoiceCheck(blocking: true, message: "\(model.label) needs about \(need) free to download; this Mac has less."))
        }
        if memoryBytes < model.comfortableMemoryBytes {
            let want = ByteCountFormatter.string(fromByteCount: Int64(model.comfortableMemoryBytes), countStyle: .memory)
            let other = model == .turbo ? " The Small model is lighter." : ""
            found.append(VoiceCheck(blocking: false, message: "\(model.label) is comfortable from \(want) of memory; this Mac may slow down while it loads.\(other)"))
        }
        if !appleSilicon {
            found.append(VoiceCheck(blocking: false, message: "This Mac is not Apple silicon: transcribing will be slow. The Small model is the one to use."))
        }
        return found
    }

    public static let sampleRate = 16_000.0
    /// A loaded model is let go after this long unused: Large v3 turbo holds about 3 GB, and loading it again takes about 6 s.
    public static let idleUnloadSeconds = 300.0
    /// A recording ends by itself after this long.
    public static let maxSeconds = 300.0
    /// Silence this long ends a recording that was left on; what was said is kept.
    public static let silenceEndSeconds = 120.0
    /// RMS below this is silence; speech at a normal distance is far above it.
    public static let silenceRMS: Float = 0.01

    public static func rms(_ samples: some Sequence<Float>) -> Float {
        var sum: Float = 0
        var count = 0
        for sample in samples { sum += sample * sample; count += 1 }
        return count == 0 ? 0 : (sum / Float(count)).squareRoot()
    }

    /// Whether a recording holds any speech at all: the engine is never asked to transcribe silence,
    /// which Whisper fills with invented words.
    public static func hasSpeech(_ samples: [Float]) -> Bool {
        let window = Int(sampleRate / 10)
        return stride(from: 0, to: samples.count, by: window).contains { start in
            rms(samples[start ..< min(start + window, samples.count)]) >= silenceRMS
        }
    }

    /// A bar height between 0 and 1 for a buffer's RMS: speech reaches the top, silence sits near zero.
    public static func barHeight(rms: Float) -> Double {
        guard rms > silenceRMS / 2 else { return 0 }
        return min(1, Double(rms / 0.15).squareRoot())
    }

    /// Where to cut the audio that is not transcribed yet, while the recording goes on: after at least
    /// `chunkMinSeconds`, at the latest pause, so no word is split; after `chunkMaxSeconds` at any point.
    /// nil: keep recording. What is cut is transcribed in the background, so Stop only waits for the rest.
    public static func cutPoint(in pending: [Float]) -> Int? {
        let minimum = Int(chunkMinSeconds * sampleRate)
        let window = Int(0.3 * sampleRate)
        guard pending.count >= minimum + window else { return nil }
        var start = pending.count - window
        while start >= minimum {
            if rms(pending[start ..< start + window]) < silenceRMS { return start + window }
            start -= window / 3
        }
        return pending.count >= Int(chunkMaxSeconds * sampleRate) ? pending.count : nil
    }

    public static let chunkMinSeconds = 4.0
    public static let chunkMaxSeconds = 25.0

    /// The text of a recording, trimmed; `nothingHeard` for silence or an empty result.
    public static func text(of samples: [Float], language: String?, using transcriber: any Transcriber) async throws -> String {
        guard hasSpeech(samples) else { throw VoiceError.nothingHeard }
        let text = try await transcriber.transcribe(samples, language: language)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceError.nothingHeard }
        return text
    }

    /// `text` appended to what is already in the box, on its own space.
    public static func appending(_ text: String, to draft: String) -> String {
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? text : existing + " " + text
    }

    public static func modelsFolder(home: BtonHome) -> URL {
        home.url.appendingPathComponent("models", isDirectory: true)
    }
}
