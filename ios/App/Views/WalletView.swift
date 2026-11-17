// The wallet tab: one button to add a key; once added, the wallet syncs (the Details tab's steps, in order) and shows
// the balance, the coins, the address and what the server received. Pull down to sync again.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct WalletView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            Group {
                if model.hasWallet { wallet } else { empty }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.hasWallet {
                    Menu {
                        Button { model.syncWallet() } label: { Label("Sync now", systemImage: "arrow.clockwise") }
                            .disabled(model.busy)
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Remove key", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Steps started from the Details tab (or a launch with PSS_AUTORUN) keep running after a sync ends.
                if let step = model.running, !model.syncing || model.syncWaiting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.syncWaiting ? "Sync waits for “\(step.title)”" : "Details is running “\(step.title)”")
                            .font(.footnote).lineLimit(1)
                        Spacer()
                        Button("Show") { model.tab = .details }.font(.footnote)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial)
                }
            }
            .sheet(isPresented: $adding) { AddKeySheet() }
            .confirmationDialog("Remove the key from this device?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove key", role: .destructive) { model.removeKey() }
            } message: {
                Text(model.busy ? "The coins stay on the chain; adding the key again finds them. A sync in progress stops after its current step."
                     : "The coins stay on the chain; adding the key again finds them.")
            }
        }
    }

    // ── no wallet yet ────────────────────────────────────────────────────────────────────────────────────────────

    private var empty: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 60)).foregroundStyle(.tint)
            Text("No wallet on this device").font(.title3.bold())
            Text("Add your key and the app finds your shielded coins. It downloads the same files as every other wallet and asks for its records by private retrieval, so the server cannot tell which coins are yours.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { adding = true } label: {
                Label("Add key", systemImage: "key.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    // ── the wallet ───────────────────────────────────────────────────────────────────────────────────────────────

    private var wallet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                balanceCard
                syncCard
                if let w = model.wallet {
                    coinsCard(w)
                    addressCard(w)
                    serverCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable { await model.syncNow() }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shielded balance").font(.subheadline).foregroundStyle(.secondary)
            if let w = model.wallet {
                if w.balances.isEmpty {
                    Text("0").font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text("No unspent coins yet.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(w.balances) { b in
                        HStack(alignment: .firstTextBaseline) {
                            Text(b.amount).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.5)
                            Text(b.symbol).font(.title3.weight(.medium)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(b.coins) coin\(b.coins == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(syncLine(w)).font(.caption).foregroundStyle(.secondary)
            } else if model.syncError != nil {
                Text("Not synced").font(.title2.weight(.semibold))
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Syncing…").font(.title2.weight(.semibold))
                }
            }
        }
        .card()
    }

    private func syncLine(_ w: WalletSummary) -> String {
        var parts = ["\(w.network.capitalized), height \(Token.group(w.height))"]
        if let d = model.lastSync { parts.append("synced \(d.formatted(date: .omitted, time: .shortened)) in \(formatMs(model.lastSyncMs))") }
        if model.syncing { parts.append("syncing…") }
        return parts.joined(separator: " · ")
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sync").font(.headline)
                Spacer()
                Button("Details") { model.tab = .details }.font(.footnote)
            }
            ForEach(model.stages) { st in StageRow(stage: st) }
            if let e = model.syncError {
                Text(e).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                Button("Try again") { model.syncWallet() }.buttonStyle(.bordered).controlSize(.small).disabled(model.busy)
            }
        }
        .card()
    }

    private func coinsCard(_ w: WalletSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coins").font(.headline)
            if w.coins.isEmpty {
                Text("None found.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(w.coins) { c in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.spent == nil ? "circle.fill" : "circle.slash")
                        .font(.caption).foregroundStyle(c.spent == nil ? Color.green : Color.secondary).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(c.amount) \(c.symbol)").font(.body.weight(.medium)).monospacedDigit()
                            .foregroundStyle(c.spent == nil ? Color.primary : Color.secondary)
                            .strikethrough(c.spent != nil)
                        Text(c.spent.map { "\(c.source); \($0)" } ?? c.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }

    private func addressCard(_ w: WalletSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your shielded address").font(.headline)
            Text(w.address).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = w.address
                #endif
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .card()
    }

    private var serverCard: some View {
        let v = model.serverSaw
        return VStack(alignment: .leading, spacing: 6) {
            Text("What the server received").font(.headline)
            Text("\(v.requests) requests in the last sync: \(formatBytes(v.bytesUp)) up, \(formatBytes(v.bytesDown)) down, of which \(v.pirCalls) private-retrieval call\(v.pirCalls == 1 ? "" : "s").")
                .font(.footnote)
            Text("The files are the same for every wallet. Each call carries encrypted vectors the server cannot read, with random ones added to fill it, so it cannot tell which records it returned. It never receives the key, the address or which outputs are yours.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }
}

struct StageRow: View {
    let stage: SyncStage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title).font(.subheadline.weight(stage.state == .running ? .semibold : .regular))
                    .foregroundStyle(stage.state == .waiting || stage.state == .skipped ? Color.secondary : Color.primary)
                Text(stage.note).font(.caption).foregroundStyle(stage.state == .failed ? Color.red : Color.secondary)
            }
            Spacer()
            if stage.state == .done { Text(formatMs(stage.ms)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch stage.state {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct AddKeySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var reveal = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Hidden while typed, so the words stay out of screen recordings; the eye shows them.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Group {
                            if reveal {
                                TextField("24 words, or a Zswap seed in hex", text: $text, axis: .vertical)
                                    .lineLimit(3...8)
                            } else {
                                SecureField("24 words, or a Zswap seed in hex", text: $text)
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .privacySensitive()
                        .focused($focused)
                        Button {
                            reveal.toggle()
                            focused = true
                        } label: {
                            Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(reveal ? "Hide the key" : "Show the key")
                    }
                    if !text.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary) }
                    PasteButton(payloadType: String.self) { items in
                        if let first = items.first { Task { @MainActor in text = first } }
                    }
                } footer: {
                    Text("Hidden while you type; the eye shows it. Pasting puts it in without showing it. The key stays on this device, in its Keychain; the server never receives it.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// What the hidden field holds, without showing it.
    private var summary: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = t.lowercased().hasPrefix("0x") ? String(t.dropFirst(2)) : t
        if !hex.isEmpty, hex.allSatisfy(\.isHexDigit) { return "\(hex.count) hex characters" }
        let n = t.split(whereSeparator: \.isWhitespace).count
        return "\(n) word\(n == 1 ? "" : "s")"
    }

    private func add() {
        do {
            try model.addKey(text)
            text = ""
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
