import BtonCore
import Foundation
import WhisperKit

/// Whisper on the GPU through WhisperKit. The model is downloaded once, from Hugging Face
/// over HTTPS, into `~/.bton/models`; transcribing never touches the network.
actor WhisperTranscriber: Transcriber {
    private let base: URL
    private var loaded: (model: VoiceModel, kit: WhisperKit)?

    init(home: BtonHome) {
        base = Voice.modelsFolder(home: home)
    }

    static func folder(of model: VoiceModel, home: BtonHome) -> URL {
        Voice.modelsFolder(home: home).appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.variant)", isDirectory: true)
    }

    /// Written after a download returned, so a download cut short is never mistaken for a model.
    private static func marker(_ model: VoiceModel, home: BtonHome) -> URL {
        folder(of: model, home: home).appendingPathComponent(".bton-complete")
    }

    static func isDownloaded(_ model: VoiceModel, home: BtonHome) -> Bool {
        FileManager.default.fileExists(atPath: marker(model, home: home).path)
    }

    static func download(_ model: VoiceModel, home: BtonHome, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: model.variant, downloadBase: Voice.modelsFolder(home: home)) {
            progress($0.fractionCompleted)
        }
        guard FileManager.default.createFile(atPath: marker(model, home: home).path, contents: Data()) else {
            throw VoiceError.modelMissing
        }
    }

    /// Loads the model so the first recording does not wait for it.
    func prepare(_ model: VoiceModel, home: BtonHome) async throws {
        self.home = home
        chosen = model
        let kit = try await pipeline(for: model)
        // The first transcription after a load pays for the GPU's own set-up (about 3 s for turbo): pay it now, on silence.
        // Two seconds of it: WhisperKit skips a clip of a second or less without touching the GPU.
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 32_000), decodeOptions: Self.options(language: "en"))
    }

    /// Frees the loaded model; the next transcription loads it again.
    func unload() {
        loaded = nil
    }

    private static func options(language: String?) -> DecodingOptions {
        DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 0, detectLanguage: language == nil,
                        skipSpecialTokens: true, withoutTimestamps: true)
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        let model = try selectedModel()
        let kit = try await pipeline(for: model)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: Self.options(language: language))
        return results.map(\.text).joined(separator: " ")
    }

    private var chosen = VoiceModel.defaultModel
    private var home: BtonHome?

    /// The model and home the next recording uses; set from the settings before each recording.
    func use(_ model: VoiceModel, home: BtonHome) {
        chosen = model
        self.home = home
    }

    private func selectedModel() throws -> VoiceModel {
        guard let home, Self.isDownloaded(chosen, home: home) else { throw VoiceError.modelMissing }
        return chosen
    }

    private func pipeline(for model: VoiceModel) async throws -> WhisperKit {
        if let loaded, loaded.model == model { return loaded.kit }
        guard let home else { throw VoiceError.modelMissing }
        // The GPU, not the Neural Engine: its compiler service can wedge for hours on a first load (seen here),
        // and the GPU needs no compile.
        let compute = ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
        let config = WhisperKitConfig(downloadBase: base, modelFolder: Self.folder(of: model, home: home).path, computeOptions: compute,
                                      verbose: false, prewarm: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        loaded = (model, kit)
        return kit
    }
}
