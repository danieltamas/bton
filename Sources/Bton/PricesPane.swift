import BtonCore
import SwiftUI

/// Token prices, fetched rather than typed: the feed's table refreshes itself daily, and the
/// owner prices only a model the feed lacks.
struct PricesPane: View {
    @Environment(AppStore.self) private var store
    @State private var rows: [PriceRow] = []
    @State private var filter = ""
    @State private var problem: String?
    @State private var refreshing = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .prices, title: "Prices",
                       detail: "USD per million tokens, refreshed daily from the public price list. A model without a price shows \"no price\", never a guess.")
            feedCard
            if !store.unpricedModels.isEmpty { unpriced }
            customCard
            if let problem { ProblemText(text: problem) }
        }
        .onAppear { rows = PriceRow.rows(from: store.prices.custom ?? [:]) }
        .animation(Motion.spring, value: problem)
        .animation(Motion.spring, value: saved)
    }

    // MARK: feed

    private var feedCard: some View {
        Bezel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    GlyphDisc(symbol: "arrow.down.circle", color: Theme.success, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(store.prices.models.count) models").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Group {
                            if let updated = store.prices.updatedAt {
                                Text("\(store.prices.source ?? "price list") · updated \(Text(updated, style: .relative)) ago")
                            } else {
                                Text("Not fetched yet")
                            }
                        }
                        .font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    GlassField(placeholder: "Filter", text: $filter).frame(width: 140)
                    PillButton(title: refreshing ? "Refreshing…" : "Refresh", symbol: "arrow.clockwise", prominent: false,
                               disabled: refreshing, action: refresh)
                }
                .padding(14)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                columns(first: "Model").padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(feedModels, id: \.self) { model in
                            if let price = store.prices.models[model] { feedLine(model, price) }
                        }
                    }
                }
                .frame(height: 220)
                .scrollIndicators(.never)
            }
        }
    }

    private var feedModels: [String] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return store.prices.models.keys.filter { query.isEmpty || $0.contains(query) }.sorted()
    }

    private func feedLine(_ model: String, _ price: ModelPrice) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                VendorLogo(model: model, size: 13)
                Text(model).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach([price.input, price.cacheRead, price.cacheWrite, price.output], id: \.self) { value in
                Text(value, format: .currency(code: "USD").precision(.fractionLength(2...4)).locale(Locale(identifier: "en_US")))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .frame(width: 78, alignment: .leading)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
    }

    private func columns(first: String) -> some View {
        HStack(spacing: 8) {
            Eyebrow(text: first).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(["Input", "Cache read", "Cache write", "Output"], id: \.self) { title in
                Eyebrow(text: title).frame(width: 78, alignment: .leading)
            }
        }
    }

    private func refresh() {
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                try await store.refreshPrices()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: custom

    private var unpriced: some View {
        SettingsCard(title: "Used without a price", detail: "Jobs ran these models and neither the feed nor your rows price them.") {
            HStack(spacing: 6) {
                ForEach(store.unpricedModels, id: \.self) { model in
                    Button {
                        withAnimation(Motion.spring) { rows.append(PriceRow(model: model)) }
                    } label: {
                        Chip(text: model, symbol: "plus", color: SettingsPane.prices.color, style: .dashed)
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }

    private var customCard: some View {
        SettingsCard(title: "Your prices", detail: "Only for a model the feed lacks, or to override it. A row prices every model whose name starts with it.") {
            VStack(spacing: 8) {
                if !rows.isEmpty { columns(first: "Model or prefix") }
                ForEach($rows) { $row in line($row) }
                HStack {
                    Button { withAnimation(Motion.spring) { rows.append(PriceRow()) } } label: {
                        Label("Add model", systemImage: "plus").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.mint)
                    }
                    .buttonStyle(PressStyle())
                    Spacer()
                    if saved { Chip(text: "saved", symbol: "checkmark", color: Theme.success).transition(.opacity) }
                    PillButton(title: "Save", symbol: "checkmark", action: save)
                }
            }
        }
    }

    private func line(_ row: Binding<PriceRow>) -> some View {
        HStack(spacing: 8) {
            GlassField(placeholder: "claude-sonnet", text: row.model, monospaced: true)
            GlassField(placeholder: "0", text: row.input, monospaced: true).frame(width: 78)
            GlassField(placeholder: "0", text: row.cacheRead, monospaced: true).frame(width: 78)
            GlassField(placeholder: "0", text: row.cacheWrite, monospaced: true).frame(width: 78)
            GlassField(placeholder: "0", text: row.output, monospaced: true).frame(width: 78)
            IconButton(symbol: "minus", help: "Remove", tint: Theme.danger) {
                withAnimation(Motion.spring) { rows.removeAll { $0.id == row.wrappedValue.id } }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func save() {
        var custom: [String: ModelPrice] = [:]
        for row in rows {
            let model = row.model.trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty else { problem = "Every row needs a model name."; return }
            guard custom[model] == nil else { problem = "\(model) is listed twice."; return }
            guard let price = row.price else { problem = "\(model): enter each price as a number, like 3 or 0.30."; return }
            custom[model] = price
        }
        do {
            try store.saveCustomPrices(custom)
            problem = nil
            saved = true
            Task { try? await Task.sleep(for: .seconds(1.6)); saved = false }
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct PriceRow: Identifiable {
    let id = UUID()
    var model = ""
    var input = ""
    var cacheRead = ""
    var cacheWrite = ""
    var output = ""

    /// Each field as a non-negative decimal in the POSIX spelling, whatever the Mac's locale.
    var price: ModelPrice? {
        // Decimal(string:) reads a leading number and ignores the rest, so the whole field is checked first.
        let values = [input, cacheRead, cacheWrite, output].map { field -> Decimal? in
            let text = field.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard text.wholeMatch(of: /[0-9]+(\.[0-9]+)?/) != nil else { return nil }
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return ModelPrice(input: values[0]!, cacheRead: values[1]!, cacheWrite: values[2]!, output: values[3]!)
    }

    static func rows(from custom: [String: ModelPrice]) -> [PriceRow] {
        custom.keys.sorted().map { model in
            let price = custom[model]!
            return PriceRow(model: model, input: "\(price.input)", cacheRead: "\(price.cacheRead)",
                            cacheWrite: "\(price.cacheWrite)", output: "\(price.output)")
        }
    }
}
