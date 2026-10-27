import BtonCore
import SwiftUI

/// Settings > Voice: dictate into New issue. Off until switched on; the audio never leaves this Mac.
struct VoicePane: View {
    @Environment(AppStore.self) private var store
    @State private var problem: String?

    var body: some View {
        let settings = store.voiceSettings ?? VoiceSettings(enabled: false)
        let model = settings.model ?? .defaultModel
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .voice, title: "Voice",
                       detail: "Speak a new issue instead of typing it. The words land in the box for you to edit before you send.")
            SettingsCard(title: "Voice input",
                         detail: "A microphone button beside Send. Recording stays on this Mac and is never saved; the agent only gets the text.") {
                Toggle("Dictate in New issue", isOn: Binding(get: { settings.enabled },
                                                              set: { on in save { try store.setVoice { $0.enabled = on } } }))
                    .toggleStyle(.switch).tint(Theme.mint)
                    .pointingHandCursor()
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            SettingsCard(title: "Model", detail: "Whisper, run on this Mac. Downloaded once into ~/.bton/models; recording needs no network.") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(VoiceModel.allCases) { choice in
                            SegmentChip(title: choice.label, selected: model == choice) {
                                save { try store.setVoice { $0.model = choice == .defaultModel ? nil : choice } }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Text(model.detail).font(.meta).foregroundStyle(Theme.textTertiary)
                        if store.voice.ready.contains(model) {
                            Label("ready", systemImage: "checkmark").font(.meta.weight(.semibold)).foregroundStyle(Theme.success)
                        }
                    }
                    ForEach(store.voice.checks(for: model), id: \.self) { check in
                        Label(check.message, systemImage: check.blocking ? "exclamationmark.octagon" : "exclamationmark.triangle")
                            .font(.meta).foregroundStyle(check.blocking ? Theme.danger : Theme.textSecondary)
                    }
                    download(model)
                }
            }
            SettingsCard(title: "Language", detail: "Detected for each recording, or pinned when it is always the same.") {
                HStack(spacing: 6) {
                    SegmentChip(title: "Detect", selected: settings.language == nil) { save { try store.setVoice { $0.language = nil } } }
                    ForEach(VoiceModel.languages, id: \.code) { language in
                        SegmentChip(title: language.name, selected: settings.language == language.code) {
                            save { try store.setVoice { $0.language = language.code } }
                        }
                    }
                }
            }
            if let problem = problem ?? store.voice.problem { ProblemText(text: problem) }
        }
        .task { if settings.enabled { await store.voice.prepare(model) } }
    }

    @ViewBuilder private func download(_ model: VoiceModel) -> some View {
        if let fraction = store.voice.downloading[model] {
            HStack(spacing: 10) {
                ProgressView(value: fraction).tint(Theme.mint).frame(width: 160)
                Text("Downloading \(Int(fraction * 100))%").font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
        } else if let since = store.voice.preparing[model] {
            // Core ML reports no progress while it loads, so the bar is honest about it: it only moves.
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().progressViewStyle(.linear).tint(Theme.mint).frame(width: 220)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Loading the model. \(Duration.seconds(Int(context.date.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond)))")
                        .font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
            }
        } else if store.voice.downloaded.contains(model) {
            HStack(spacing: 8) {
                if !store.voice.ready.contains(model) {
                    PillButton(title: "Prepare \(model.label)", symbol: "bolt", prominent: false) { Task { await store.voice.prepare(model) } }
                }
                PillButton(title: "Delete download", symbol: "trash", prominent: false) { store.voice.remove(model) }
            }
        } else {
            PillButton(title: "Download \(model.label)", symbol: "arrow.down.circle", prominent: false,
                       disabled: store.voice.checks(for: model).contains(where: \.blocking)) {
                Task { await store.voice.download(model) }
            }
        }
    }

    private func save(_ change: () throws -> Void) {
        do {
            try withAnimation(Motion.spring) { try change() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

extension AppStore {
    func setVoice(_ change: (inout VoiceSettings) -> Void) throws {
        try update { config in
            var settings = config.voice ?? VoiceSettings(enabled: false)
            change(&settings)
            config.voice = settings
        }
    }
}
