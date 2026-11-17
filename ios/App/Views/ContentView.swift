// Two tabs: the wallet (WalletView.swift), and the details: a card per step, each with its inputs, a Run button, its
// result and the requests it made.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.tab) {
            WalletView().tabItem { Label("Wallet", systemImage: "wallet.pass") }.tag(AppTab.wallet)
            DetailsView().tabItem { Label("Details", systemImage: "list.bullet.rectangle") }.tag(AppTab.details)
        }
    }
}

struct DetailsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    serverCard
                    ForEach(StepId.allCases) { step in StepCard(step: step) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Private shielded sync")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if model.running != nil || !model.progress.isEmpty {
                    HStack {
                        if model.running != nil { ProgressView().padding(.trailing, 6) }
                        Text(model.running.map { "\($0.title): \(model.progress)" } ?? model.progress).font(.footnote).lineLimit(2)
                        Spacer()
                    }
                    .padding(10)
                    .background(.thinMaterial)
                }
            }
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server").font(.headline)
            TextField("http://127.0.0.1:10480", text: $model.server)
                .textFieldStyle(.roundedBorder).font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
            Picker("Scan on", selection: $model.scanEngine) { ForEach(ScanEngine.allCases) { Text($0.rawValue).tag($0) } }
            Picker("PIR multiply on", selection: $model.pirEngine) { ForEach(Engine.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Decode the padding vectors too", isOn: $model.decodePadding).font(.footnote)
            Text("The server sees the same calls either way: decoding happens on this device.").font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }
}

struct StepCard: View {
    @EnvironmentObject var model: AppModel
    let step: StepId
    @State private var showRequests = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title).font(.headline)
                Spacer()
                if step != .background {
                    Button(model.running == step ? "Running…" : "Run") { model.run(step) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(model.busy)
                }
            }
            Text(step.blurb).font(.caption).foregroundStyle(.secondary)
            inputs
            if let r = model.results[step] { ResultView(result: r) }
            if step == .background { backgroundLog }
        }
        .card()
    }

    @ViewBuilder private var inputs: some View {
        switch step {
        case .keys:
            SecureField("24-word mnemonic", text: $model.mnemonic).textFieldStyle(.roundedBorder).font(.footnote)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            SecureField("or a 32-byte Zswap seed (hex)", text: $model.seedHex).textFieldStyle(.roundedBorder)
                .font(.system(.footnote, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
        case .read:
            TextField("positions, e.g. 0, 17, 100-104 (default: the scan's matches)", text: $model.readPositions)
                .textFieldStyle(.roundedBorder).font(.footnote).keyboardType(.numbersAndPunctuation)
        case .nullifiers:
            TextField("extra nullifiers (hex), besides the coins'", text: $model.manualNullifiers)
                .textFieldStyle(.roundedBorder).font(.system(.footnote, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
        case .paths:
            TextField("positions (default: the wallet's snapshot coins)", text: $model.pathPositions)
                .textFieldStyle(.roundedBorder).font(.footnote).keyboardType(.numbersAndPunctuation)
        case .benchScan:
            TextField("sizes", text: $model.benchSizes).textFieldStyle(.roundedBorder).font(.footnote)
            Toggle("CPU too (slow above 100k)", isOn: $model.benchCpuToo).font(.footnote)
        case .benchPir:
            TextField("sizes", text: $model.pirSizes).textFieldStyle(.roundedBorder).font(.footnote)
        case .background:
            Toggle("Submit GPU work when the app leaves the foreground", isOn: $model.backgroundTest).font(.footnote)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var backgroundLog: some View {
        ForEach(Array(model.backgroundLog.enumerated()), id: \.offset) { _, entry in
            Text(entry).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ResultView: View {
    let result: StepResult
    @State private var selected: Exchange?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.ok ? String(format: "done in %.2f ms", result.ms) : "failed")
                .font(.caption.bold()).foregroundStyle(result.ok ? Color.green : Color.red)
            if let e = result.error { Text(e).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
            RowsView(rows: result.rows)
            ForEach(Array(result.sections.enumerated()), id: \.offset) { _, s in
                DisclosureGroup(s.title) { RowsView(rows: s.rows) }.font(.footnote)
            }
            if !result.exchanges.isEmpty {
                DisclosureGroup("What the server saw (\(result.exchanges.count) requests)") {
                    ForEach(result.exchanges) { e in
                        Button { selected = e } label: {
                            HStack {
                                Text("\(e.method) \(e.path.replacingOccurrences(of: "/pss/v1", with: ""))").lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(e.status) · \(formatBytes(e.requestBytes))↑ \(formatBytes(e.responseBytes))↓ · \(Int(e.ms)) ms").foregroundStyle(.secondary)
                            }
                            .font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
                .font(.footnote)
            }
        }
        .sheet(item: $selected) { ExchangeView(exchange: $0) }
    }
}

struct RowsView: View {
    let rows: [Row]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.key).font(.caption2).foregroundStyle(.secondary)
                    Text(r.value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }
}

struct ExchangeView: View {
    let exchange: Exchange
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    RowsView(rows: [
                        Row(key: "request", value: "\(exchange.method) \(exchange.path)"),
                        Row(key: "status", value: "\(exchange.status)"),
                        Row(key: "time", value: String(format: "%.2f ms", exchange.ms)),
                        Row(key: "request body", value: "\(exchange.requestBytes) bytes"),
                        Row(key: "response body", value: "\(exchange.responseBytes) bytes"),
                    ])
                    if let h = Self.callHeader(exchange.requestHead) { section("Request header", h) }
                    if let h = Self.callHeader(exchange.responseHead) { section("Response header", h) }
                    section("Response headers", exchange.responseHeaders.sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) })
                    if !exchange.requestHead.isEmpty { dump("Request body, first bytes", exchange.requestHead) }
                    dump("Response body, first bytes", exchange.responseHead)
                }
                .padding(16)
            }
            .navigationTitle("Request").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func section(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.bold()); RowsView(rows: rows) }
    }

    private func dump(_ title: String, _ d: Data) -> some View {
        let shown = d.prefix(512)
        let lines = stride(from: 0, to: shown.count, by: 16).map { off in
            String(format: "%04x  ", off) + shown.sub(off, min(16, shown.count - off)).map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(lines.joined(separator: "\n") + (d.count > 512 ? "\n…" : "")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
        }
    }

    /// The fields of a query or answer header (magic, version, snapshot, vector count).
    static func callHeader(_ d: Data) -> [Row]? {
        guard d.count >= Wire.callHeaderBytes else { return nil }
        let magic = d.u32(0)
        let name = magic == Wire.queryMagic ? "PSSQ (query)" : magic == Wire.answerMagic ? "PSSA (answer)" : nil
        guard let name else { return nil }
        return [Row(key: "magic", value: name), Row(key: "format version", value: "\(d.u16(4))"),
                Row(key: "snapshot", value: d.sub(6, 32).hex), Row(key: "vectors", value: "\(d.u16(38))")]
    }
}

extension View {
    func card() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
