import BtonCore
import SwiftUI

/// Dictation into a text box: record, stop, transcribe, and hand the words over for editing.
@MainActor @Observable final class VoiceController {
    let recorder = VoiceRecorder()
    private(set) var downloaded: Set<VoiceModel> = []
    /// 0 to 1 while a model downloads.
    private(set) var downloading: [VoiceModel: Double] = [:]
    /// Models being loaded into memory; the first load of one compiles it and takes minutes.
    private(set) var preparing: [VoiceModel: Date] = [:]
    /// Loaded in memory: recording is possible only for these.
    private(set) var ready: Set<VoiceModel> = []
    var problem: String?

    @ObservationIgnored private let home: BtonHome
    @ObservationIgnored private let engine: WhisperTranscriber
    /// Tests and demo shots swap the engine for canned text.
    @ObservationIgnored var transcriber: (any Transcriber)?

    init(home: BtonHome) {
        self.home = home
        engine = WhisperTranscriber(home: home)
        refresh()
    }

    func refresh() {
        downloaded = Set(VoiceModel.allCases.filter { WhisperTranscriber.isDownloaded($0, home: home) })
    }

    /// What this Mac says about using `model`.
    func checks(for model: VoiceModel) -> [VoiceCheck] {
        let free = try? home.url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        #if arch(arm64)
        let silicon = true
        #else
        let silicon = false
        #endif
        return Voice.checks(for: model, downloaded: downloaded.contains(model), freeBytes: free,
                            memoryBytes: ProcessInfo.processInfo.physicalMemory, appleSilicon: silicon)
    }

    /// For a model that will not load, or to free the space.
    func remove(_ model: VoiceModel) {
        ready.remove(model)
        try? FileManager.default.removeItem(at: WhisperTranscriber.folder(of: model, home: home))
        problem = nil
        refresh()
    }

    func download(_ model: VoiceModel) async {
        guard downloading[model] == nil, !checks(for: model).contains(where: \.blocking) else { return }
        downloading[model] = 0
        problem = nil
        do {
            try await WhisperTranscriber.download(model, home: home) { fraction in
                Task { @MainActor [weak self] in self?.downloading[model] = fraction }
            }
        } catch {
            problem = "The \(model.label) model did not download from huggingface.co: \(error.localizedDescription) Recording itself needs no network."
        }
        downloading[model] = nil
        refresh()
        await prepare(model)
    }

    func prepare(_ model: VoiceModel) async {
        unloadWhenIdle()
        guard downloaded.contains(model), !ready.contains(model), preparing[model] == nil else { return }
        preparing[model] = .now
        defer { preparing[model] = nil }
        do {
            try await engine.prepare(model, home: home)
            ready.insert(model)
        } catch {
            problem = "The \(model.label) model did not load: \(error.localizedDescription) Delete the download in Settings > Voice and download it again."
        }
    }

    @ObservationIgnored private var unloadTask: Task<Void, Never>?

    /// Each use pushes the unload back, so the model stays only while someone opens new issues or dictates.
    /// A stale `ready` after a race is harmless: a transcription loads the model again by itself.
    private func unloadWhenIdle() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Voice.idleUnloadSeconds))
            guard !Task.isCancelled, let self else { return }
            guard recorder.phase == .idle, !recorder.starting, preparing.isEmpty else { return unloadWhenIdle() }
            ready.removeAll()
            await engine.unload()
        }
    }

    /// The new issue whose recording is under way: its Stop is the only one that can end it.
    private(set) var owner: String?
    @ObservationIgnored private var delivery: ((String) -> Void)?
    /// Bumped by every start and by Esc, so a transcription that was cancelled never lands in a box.
    @ObservationIgnored private var generation = 0
    /// While recording, audio that ended at a pause is transcribed at once, in order: `cursor` is how
    /// many samples are already sent, `pieces` their texts. Stop then waits only for the rest.
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var pieces: [Task<String?, Never>] = []
    /// The words transcribed so far in this recording, shown in the strip while the rest is spoken.
    private(set) var heard = ""
    /// Pieces of the current recording that failed to transcribe (silence is not a failure).
    private var failedPieces = 0

    /// The mic button: starts a recording, or stops it and puts the words in the owner's box.
    func toggle(settings: VoiceSettings, owner: String, deliver: @escaping (String) -> Void) async {
        unloadWhenIdle()
        switch recorder.phase {
        case .idle:
            guard !recorder.starting else { return }
            problem = nil
            let model = settings.model ?? .defaultModel
            generation += 1
            let token = generation
            // Owned before the load below, so closing this new issue while it loads cancels the recording.
            self.owner = owner
            delivery = deliver
            // Unloaded while the new issue stayed open: load it again, behind the mic's spinner.
            if transcriber == nil, !ready.contains(model) { await prepare(model) }
            guard token == generation else { return }
            guard transcriber != nil || ready.contains(model) else {
                problem = problem ?? VoiceError.modelMissing.localizedDescription
                release()
                return
            }
            cursor = 0
            pieces = []
            heard = ""
            failedPieces = 0
            await recorder.start { [weak self] in Task { await self?.toggle(settings: settings, owner: owner, deliver: deliver) } }
            problem = recorder.problem
            if recorder.phase == .idle { release() } else { stream(settings: settings, token: generation) }
        case .recording:
            let token = generation
            let tail = Array(recorder.stop().dropFirst(cursor))
            let before = pieces
            do {
                var texts: [String] = []
                for piece in before { if let text = await piece.value { texts.append(text) } }
                if let text = await transcribe(tail, settings: settings) { texts.append(text) }
                guard !texts.isEmpty else { throw VoiceError.nothingHeard }
                if token == generation {
                    delivery?(texts.joined(separator: " "))
                    if failedPieces > 0 { problem = "Part of the recording could not be transcribed. Check the text and dictate the missing words again." }
                }
            } catch {
                if token == generation { problem = error.localizedDescription }
            }
            if token == generation {
                recorder.finish()
                release()
            }
        case .transcribing:
            break
        }
    }

    /// One piece of speech as text; nil for silence or a failure (a failed piece must not lose the others).
    private func transcribe(_ samples: [Float], settings: VoiceSettings) async -> String? {
        let transcriber: any Transcriber
        if let custom = self.transcriber {
            transcriber = custom
        } else {
            await engine.use(settings.model ?? .defaultModel, home: home)
            transcriber = engine
        }
        do {
            return try await Voice.text(of: samples, language: settings.language, using: transcriber)
        } catch VoiceError.nothingHeard {
            return nil
        } catch {
            failedPieces += 1
            return nil
        }
    }

    /// Cuts the recording at its pauses and transcribes each piece while the next is spoken.
    private func stream(settings: VoiceSettings, token: Int) {
        Task {
            while recorder.phase == .recording, token == generation {
                try? await Task.sleep(for: .milliseconds(500))
                guard recorder.phase == .recording, token == generation else { return }
                let pending = recorder.samples(from: cursor)
                guard let cut = Voice.cutPoint(in: pending) else { continue }
                cursor += cut
                let chunk = Array(pending.prefix(cut))
                let previous = pieces.last
                pieces.append(Task {
                    _ = await previous?.value
                    let text = await self.transcribe(chunk, settings: settings)
                    if let text, token == self.generation { self.heard = Voice.appending(text, to: self.heard) }
                    return text
                })
            }
        }
    }

    private func release() {
        heard = ""
        owner = nil
        delivery = nil
    }

    func cancel() {
        generation += 1
        recorder.cancel()
        release()
    }
}

/// Replaces the input box while recording: live bars, the time, and Stop where the mic was.
struct VoiceStrip: View {
    let recorder: VoiceRecorder
    var heard = ""
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if recorder.phase == .transcribing {
                ProgressView().controlSize(.small)
                Text("Transcribing...").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(heard.isEmpty ? "Listening..." : heard)
                        .font(.system(size: 12)).foregroundStyle(heard.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(2).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        Text(Duration.seconds(Int(recorder.elapsed)).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 2.5) {
                            ForEach(recorder.bars.indices, id: \.self) { index in
                                Capsule().fill(Theme.mint)
                                    .frame(width: 3, height: 3 + 16 * recorder.bars[index])
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: 20)
                        .animation(.linear(duration: 0.05), value: recorder.bars)
                        PillButton(title: "Stop", symbol: "stop.fill", action: stop)
                            .keyboardShortcut(.return, modifiers: [])
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 74)
        .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel(recorder.phase == .transcribing ? "Transcribing" : "Recording")
    }
}
