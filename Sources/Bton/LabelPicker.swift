import BtonCore
import SwiftUI

/// An issue's labels under its title in the Triage tab, each one a chip that sets itself: the
/// priority and the stage first (dashed while the issue has none), then the rest, then a `+`.
/// A click on a family label (`stage:spec`) offers the family's other labels in their hues and
/// Remove last, so the issue never holds two stages; a click on a plain label asks to remove
/// it; the `+` offers the repo's other labels with a search. Every edit is one GitHub call: the
/// chip spins until GitHub answers, then the row shows what GitHub holds.
struct IssueLabelRow: View {
    @Environment(AppStore.self) private var store
    let issue: TriageIssue
    /// Where a failed edit is told.
    let report: (String?) -> Void
    /// The issue is mine: setting it to `stage:ready` also unassigns me, so a free Bton can take it.
    var givesBackOnReady = false
    @State private var repoLabels: [RepoLabel]?
    @State private var labelsProblem: String?
    /// The chip whose popover is open: a label's name, or `IssueLabelRow.plus`.
    @State private var open: String?

    /// The edit on its way to GitHub, held by the store: the chips it touches spin, the others wait.
    private var posting: AppStore.PendingLabels? { store.labelEdits[issue.id] }

    private static let plus = "+"

    private struct Slot: Identifiable {
        let id: String
        /// nil for a family the issue has no label of yet.
        let label: String?
        let family: String
        let placeholder: String
    }

    /// The priority and stage slots, then every other label the issue holds. While an edit posts, the
    /// row shows its outcome: a swap shows the new label in the old one's place, an add the new label,
    /// a removal the label on its way out; each spins, and a refused edit puts the row back.
    private var slots: [Slot] {
        var labels = issue.labels
        if let posting, !posting.add.isEmpty {
            labels = RepoLabels.apply((add: posting.add, remove: posting.remove), to: labels)
        }
        var slots: [Slot] = []
        for (family, placeholder) in [(IssueTriage.priorityPrefix, "no priority"), (IssueTriage.stagePrefix, "no stage")] {
            let held = labels.first { RepoLabels.family(of: $0) == family }
            slots.append(Slot(id: family, label: held, family: family, placeholder: placeholder))
            labels.removeAll { $0 == held }
        }
        return slots + labels.map { Slot(id: $0, label: $0, family: RepoLabels.family(of: $0) ?? "", placeholder: "") }
    }

    var body: some View {
        WrapLayout(spacing: 5) {
            ForEach(slots) { slot in chip(slot) }
            plusChip
        }
        .task(id: issue.repo) { await readLabels() }
    }

    private func chip(_ slot: Slot) -> some View {
        let name = slot.label
        let spinning = posting.map { posting in
            (name.map { held in posting.remove.contains { $0.caseInsensitiveCompare(held) == .orderedSame } } ?? false)
                || (name.map { held in posting.add.contains { $0.caseInsensitiveCompare(held) == .orderedSame } } ?? false)
        } ?? false
        let hex = name.flatMap { held in repoLabels?.first { $0.name.caseInsensitiveCompare(held) == .orderedSame }?.color } ?? ""
        let color = name.map { Theme.color(forLabel: $0, hex: hex) } ?? Theme.neutral
        return Button { open = open == slot.id ? nil : slot.id } label: {
            Chip(text: name ?? slot.placeholder, color: color, style: name == nil ? .dashed : .outline, loading: spinning)
        }
        .buttonStyle(PressStyle())
        .disabled(posting != nil)
        .help(name.map { "\($0): change or remove it" } ?? "Set the \(slot.family.dropLast())")
        .popover(isPresented: popoverBinding(slot.id), arrowEdge: .bottom) {
            familyPopover(slot)
        }
    }

    private var plusChip: some View {
        Button { open = open == Self.plus ? nil : Self.plus } label: {
            // The chips' height and stroke, with the plus alone in it.
            Image(systemName: "plus").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.textTertiary)
                .frame(height: 13)
                .padding(.horizontal, 9).padding(.vertical, 3.5)
                .background(Capsule().strokeBorder(Theme.textTertiary.opacity(0.7), style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2])))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(posting != nil)
        .help("Add a label")
        .popover(isPresented: popoverBinding(Self.plus), arrowEdge: .bottom) {
            LabelPicker(labels: repoLabels.map { RepoLabels.available(in: $0, on: issue.labels) }, problem: labelsProblem,
                        pick: { post(RepoLabels.edit(adding: $0.name, to: issue.labels)) })
        }
    }

    /// A family label's choices: the family's other labels, then Remove; a plain label's: Remove alone.
    @ViewBuilder
    private func familyPopover(_ slot: Slot) -> some View {
        let others = repoLabels.map { labels -> [RepoLabel] in
            slot.label.map { RepoLabels.alternatives(to: $0, in: labels) }
                ?? labels.filter { $0.family == slot.family }
        }
        VStack(alignment: .leading, spacing: 2) {
            if let name = slot.label {
                Text(name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            if !slot.family.isEmpty {
                if let others {
                    if others.isEmpty && slot.label == nil {
                        Text("The repo has no \(slot.family) labels").font(.meta).foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    ForEach(others, id: \.name) { label in
                        LabelChoice(label: label, note: givesBack(adding: label.name) ? "and gives the issue back: a free Bton takes it" : nil) {
                            post(RepoLabels.edit(adding: label.name, to: issue.labels))
                        }
                    }
                } else if let labelsProblem {
                    ProblemText(text: labelsProblem).padding(.horizontal, 8).padding(.vertical, 4)
                } else {
                    Text("Reading the repo's labels...").font(.meta).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
            if let name = slot.label {
                if !slot.family.isEmpty { Divider().padding(.vertical, 3) }
                Button { post((add: [], remove: [name])) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "minus.circle").font(.system(size: 11, weight: .medium))
                        Text("Remove \(name)").font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98))
            }
        }
        .padding(6)
        .frame(width: 240)
    }

    private func givesBack(adding label: String) -> Bool {
        givesBackOnReady && label.caseInsensitiveCompare(FeatureStatuses.readyLabel) == .orderedSame
    }

    private func popoverBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { open == id }, set: { open = $0 ? id : nil })
    }

    private func readLabels() async {
        labelsProblem = nil
        do {
            repoLabels = try await store.repoLabels(issue.repo)
        } catch {
            labelsProblem = "Labels not read: \(error.localizedDescription)"
        }
    }

    private func post(_ edit: (add: [String], remove: [String])) {
        open = nil
        guard !edit.add.isEmpty || !edit.remove.isEmpty, posting == nil else { return }
        // `gh` splits a label list on commas: a name it cannot take alone is not sent.
        if let odd = (edit.add + edit.remove).first(where: { !WatchedRepo.isLabelName($0) }) {
            report("gh cannot set \"\(odd)\" by name: edit it on GitHub")
            return
        }
        report(nil)
        let giveBack = edit.add.contains(where: givesBack(adding:))
        Task {
            do {
                try await store.editLabels(edit, on: issue, giveBack: giveBack)
            } catch {
                report("Label not set: \(error.localizedDescription)")
            }
        }
    }
}

/// One label to pick: its hue as a dot, its name, what it is for.
private struct LabelChoice: View {
    let label: RepoLabel
    /// What picking it does beyond the label, under the description.
    var note: String? = nil
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Theme.color(forLabel: label.name, hex: label.color)).frame(width: 8, height: 8).padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.name).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                    if !label.description.isEmpty {
                        Text(label.description).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note {
                        Text(note).font(.meta).foregroundStyle(Theme.mint).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }
}

/// The `+` popover: the repo's labels the issue does not hold, narrowed by the search as it is typed.
private struct LabelPicker: View {
    /// nil while the labels are being read.
    let labels: [RepoLabel]?
    let problem: String?
    let pick: (RepoLabel) -> Void
    @State private var search = ""
    @FocusState private var focused: Bool

    private var shown: [RepoLabel] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard let labels, !needle.isEmpty else { return labels ?? [] }
        return labels.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.description.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(focused ? Theme.mint : Theme.textTertiary)
                TextField("Search labels", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onExitCommand { search = "" }
            }
            .fieldCapsule(active: focused)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let labels {
                        if labels.isEmpty {
                            Text("The issue holds every label the repo has").font(.meta).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        } else if shown.isEmpty {
                            Text("No label matches").font(.meta).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        ForEach(shown, id: \.name) { label in LabelChoice(label: label) { pick(label) } }
                    } else if let problem {
                        ProblemText(text: problem).padding(.horizontal, 8).padding(.vertical, 4)
                    } else {
                        Text("Reading the repo's labels...").font(.meta).foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(8)
        .frame(width: 280)
        .onAppear { focused = true }
    }
}
