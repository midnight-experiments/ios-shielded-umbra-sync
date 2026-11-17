// The app's state for the screen: the inputs of each step, its last result, and which step runs. Steps run one at a
// time on a background thread; the GPU background test runs when the app leaves the foreground.

import Foundation
import Metal
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum StepId: String, CaseIterable, Identifiable {
    case device, keys, files, scan, read, nullifiers, paths, tail, summary, benchScan, benchPir, background
    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: "0. This device"
        case .keys: "1. Wallet keys"
        case .files: "2. Get the files"
        case .scan: "3. Find my outputs (scan)"
        case .read: "4. Read my records (PIR)"
        case .nullifiers: "5. Are they spent? (PIR)"
        case .paths: "6. Paths to spend (PIR)"
        case .tail: "7. The tail"
        case .summary: "8. Summary"
        case .benchScan: "Limits: scan at larger sizes"
        case .benchPir: "Limits: PIR at larger sizes"
        case .background: "Limits: GPU in the background"
        }
    }

    var blurb: String {
        switch self {
        case .device: "What the GPU and the system allow this app."
        case .keys: "Mnemonic or Zswap seed → the wallet's keys, in this process only."
        case .files: "Manifest, scan file, block roots and the read and nullifier setup data; every digest checked."
        case .scan: "The ownership test over every 36-byte entry: point × secret, two Poseidon hashes, 4-byte tag."
        case .read: "One padded call of 32 vectors reads the matched positions' 98-byte records; then decrypt and check."
        case .nullifiers: "One padded call looks up the coins' nullifiers in their buckets."
        case .paths: "Only to spend: downloads the path setup and reads the coins' lower Merkle paths."
        case .tail: "Outputs and nullifiers since the snapshot, in full; scanned on the CPU."
        case .summary: "The coins found and the unspent balance."
        case .benchScan: "Scan throughput for 100k to 2M entries on the GPU (and the CPU)."
        case .benchPir: "The client's PIR multiplications for read tables of 1M to 100M outputs."
        case .background: "Leave the app with this on: it submits GPU work in the background and records what iOS does."
        }
    }
}

enum AppTab: Hashable { case wallet, details }

@MainActor
final class AppModel: ObservableObject {
    @Published var tab: AppTab = .wallet
    @Published var server: String
    @Published var mnemonic = ""
    @Published var seedHex = ""
    @Published var scanEngine: ScanEngine = .gpu32
    @Published var pirEngine: Engine = .gpu
    @Published var decodePadding = false
    @Published var readPositions = ""
    @Published var manualNullifiers = ""
    @Published var pathPositions = ""
    @Published var benchCpuToo = false
    @Published var benchSizes = "100k, 1M, 2M"
    @Published var pirSizes = "1M, 10M, 100M"
    @Published var backgroundTest = false
    @Published var backgroundLog: [String] = []
    @Published var results: [StepId: StepResult] = [:]
    @Published var running: StepId? = nil
    @Published var progress = ""

    // The wallet tab.
    @Published private(set) var hasWallet = false
    @Published private(set) var syncing = false
    @Published private(set) var syncWaiting = false
    @Published private(set) var stages: [SyncStage] = []
    @Published private(set) var wallet: WalletSummary? = nil
    @Published private(set) var syncError: String? = nil
    @Published private(set) var lastSync: Date? = nil
    @Published private(set) var lastSyncMs = 0.0
    @Published private(set) var serverSaw = ServerView()
    private var walletKey: WalletKey? = nil
    private var syncedSnapshot: Data? = nil

    private(set) var state: ClientState
    private static let serverKey = "pss.server"

    init() {
        let env = ProcessInfo.processInfo.environment
        // The last server used is kept, so a launch from the home screen reaches the one a launcher passed before.
        let s = env["PSS_SERVER"] ?? UserDefaults.standard.string(forKey: Self.serverKey) ?? "http://127.0.0.1:10480"
        if env["PSS_SERVER"] != nil { UserDefaults.standard.set(s, forKey: Self.serverKey) }
        server = s
        state = ClientState(server: URL(string: s)!)
        // For automated runs in the Simulator only: the launcher passes these; nothing is stored.
        mnemonic = env["PSS_MNEMONIC"] ?? ""
        seedHex = env["PSS_ZSWAP_SEED"] ?? ""
    }

    func applyServer() {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url != state.http.origin else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: Self.serverKey)
        state.http = PssHttp(origin: url)
        state.resetSnapshot()
        state.manifest = nil
        state.snapshotId = nil
        syncedSnapshot = nil
    }

    var busy: Bool { running != nil || syncing }

    /// Runs one step from the Details tab.
    func run(_ step: StepId) {
        guard !busy else { return }
        running = step
        Task { await execute(step) }
    }

    /// Runs one step off the main thread and records its result. `forWallet` takes the matches and the coins'
    /// nullifiers rather than positions or nullifiers typed in the Details tab.
    @discardableResult
    private func execute(_ step: StepId, forWallet: Bool = false) async -> StepResult {
        running = step
        applyServer()
        progress = ""
        let s = state
        let before = s.http.lastId
        let inputs = (mnemonic, seedHex, scanEngine, pirEngine, decodePadding, forWallet ? "" : readPositions,
                      forWallet ? "" : manualNullifiers, pathPositions, benchCpuToo, benchSizes, pirSizes)
        let report: @Sendable (String) -> Void = { text in Task { @MainActor in self.progress = text } }
        let t = nowMs()
        var result = await Task.detached(priority: .userInitiated) { () -> StepResult in
            var result: StepResult
            do {
                switch step {
                case .device: result = Steps.device(s)
                case .keys: result = try Steps.keys(s, mnemonic: inputs.0, seedHex: inputs.1)
                case .files: result = try await Steps.files(s)
                case .scan: result = try Steps.scan(s, engine: inputs.2, progress: report)
                case .read: result = try await Steps.read(s, positionsText: inputs.5, engine: inputs.3, decodePadding: inputs.4)
                case .nullifiers: result = try await Steps.nullifiers(s, manual: inputs.6, engine: inputs.3, decodePadding: inputs.4)
                case .paths: result = try await Steps.paths(s, positionsText: inputs.7, engine: inputs.3, decodePadding: inputs.4)
                case .tail: result = try await Steps.tail(s)
                case .summary: result = Steps.summary(s)
                case .benchScan: result = try Bench.scan(s, sizes: Self.sizes(inputs.9), cpuToo: inputs.8, progress: report)
                case .benchPir: result = try Bench.pir(s, sizes: Self.sizes(inputs.10), engines: [.gpu, .cpu], progress: report)
                case .background: result = StepResult()
                }
            } catch {
                result = StepResult(ok: false, error: String(describing: error))
            }
            result.exchanges = s.http.takeExchanges(since: before)
            return result
        }.value
        let total = nowMs() - t
        if result.ms == 0 { result.ms = total }
        results[step] = result
        running = nil
        if forgetWhenIdle { forgetKeys() }
        progress = String(format: "done in %.1f ms", total)
        logForAutomation(step, result)
        return result
    }

    // ── the wallet ───────────────────────────────────────────────────────────────────────────────────────────────

    /// Adds the key typed in the wallet tab, keeps it in the Keychain and syncs.
    func addKey(_ text: String) throws {
        let key = try WalletKey(text)
        try KeyStore.save(key.stored)
        use(key)
        syncWallet()
    }

    /// The key kept from an earlier launch, if any: opens the wallet and syncs.
    func openSavedWallet() {
        guard walletKey == nil, let saved = KeyStore.load(), let key = try? WalletKey(saved) else { return }
        use(key)
        syncWallet()
    }

    private func use(_ key: WalletKey) {
        walletKey = key
        mnemonic = key.mnemonic
        seedHex = key.seedHex
        hasWallet = true
        wallet = nil; stages = []; syncError = nil; lastSync = nil; syncedSnapshot = nil
    }

    /// Removes the key at once, even during a sync: the Keychain item and the screen go now; the keys and coins in
    /// the steps' state go as soon as the step in progress ends (a running step holds that state), and a sync stops
    /// there.
    func removeKey() {
        KeyStore.delete()
        walletKey = nil
        mnemonic = ""; seedHex = ""
        hasWallet = false
        wallet = nil; stages = []; syncError = nil; lastSync = nil; syncedSnapshot = nil
        if running == nil { forgetKeys() } else { forgetWhenIdle = true }
    }

    private var forgetWhenIdle = false

    private func forgetKeys() {
        forgetWhenIdle = false
        state.keys = nil; state.coins = [:]; state.matches = []; state.commitments = [:]
        for step in [StepId.keys, .scan, .read, .nullifiers, .paths, .tail, .summary] { results[step] = nil }
    }

    func syncWallet() {
        Task { await syncNow() }
    }

    /// Syncs when the app comes back to the screen, if the last sync is a minute old.
    func becameActive() {
        guard hasWallet, let last = lastSync, Date().timeIntervalSince(last) > 60 else { return }
        syncWallet()
    }

    /// One sync: the Details tab's steps in order. A later sync of the same snapshot runs only the tail; the files
    /// step still checks the manifest, and downloads only what changed.
    func syncNow() async {
        guard walletKey != nil, !syncing else { return }
        syncing = true
        defer { syncing = false }
        // A step started from the Details tab finishes first; no other step starts while `syncing` is set.
        syncWaiting = running != nil
        while running != nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        syncWaiting = false
        guard let key = walletKey else { return }
        syncError = nil
        serverSaw = ServerView()
        let t = nowMs()
        stages = [StepId.keys, .files, .scan, .read, .nullifiers, .tail].map { SyncStage($0) }
        let needKeys = state.keys?.encryptionPublicKey != key.encryptionPublicKey
        if needKeys {
            guard await syncStep(.keys) else { return }
        } else {
            setStage(.keys, .skipped, "already derived on this device")
        }
        guard await syncStep(.files) else { return }
        let changed = needKeys || state.snapshotId != syncedSnapshot
        for step in [StepId.scan, .read, .nullifiers] {
            if changed {
                guard await syncStep(step) else { return }
            } else {
                setStage(step, .skipped, "same snapshot as the last sync")
            }
        }
        guard await syncStep(.tail) else { return }
        guard hasWallet else { return }
        await execute(.summary)
        guard hasWallet else { return }
        syncedSnapshot = state.snapshotId
        wallet = WalletSummary(state)
        lastSyncMs = nowMs() - t
        lastSync = Date()
    }

    private func syncStep(_ step: StepId) async -> Bool {
        guard hasWallet else { return false }   // the key was removed during the sync
        setStage(step, .running, SyncStage.what(step))
        let r = await execute(step, forWallet: true)
        serverSaw.add(r.exchanges)
        if r.ok {
            setStage(step, .done, stageNote(step, r), r.ms)
        } else {
            setStage(step, .failed, r.error ?? "failed", r.ms)
            syncError = r.error ?? "failed"
        }
        return r.ok
    }

    private func setStage(_ step: StepId, _ s: SyncStage.State, _ note: String, _ ms: Double = 0) {
        guard let i = stages.firstIndex(where: { $0.id == step }) else { return }
        stages[i].state = s
        stages[i].note = note
        stages[i].ms = ms
    }

    /// What one step did for the wallet, read from the shared state once the step is done.
    private func stageNote(_ step: StepId, _ r: StepResult) -> String {
        let s = state
        let calls = r.exchanges.filter { $0.path.contains("/query/") }.count
        let callText = "\(calls) call\(calls == 1 ? "" : "s") of \(s.manifest?.queriesPerCall ?? 32) vectors"
        switch step {
        case .keys:
            return "on this device; the key never leaves it"
        case .files:
            guard let m = s.manifest else { return "" }
            let down = r.exchanges.filter { $0.path.contains("/blob/") }.reduce(0) { $0 + $1.responseBytes }
            return "snapshot at height \(Token.group(m.height)); " + (down > 0 ? "\(formatBytes(down)) downloaded" : "already on this device")
        case .scan:
            let n = s.manifest?.slotCount ?? 0
            let on = scanEngine == .gpu32 || scanEngine == .gpu13 ? "GPU" : "CPU"
            return "\(s.matches.count) of \(Token.group(n)) outputs are yours (\(on))"
        case .read:
            let coins = s.coins.values.filter { $0.source == "snapshot" }.count
            return "\(coins) coin\(coins == 1 ? "" : "s") decrypted; \(callText)"
        case .nullifiers:
            let spent = s.coins.values.filter { $0.spent != nil }.count
            return "\(spent) spent; \(callText)"
        case .tail:
            let fresh = s.coins.values.filter { $0.source == "tail" }.count
            return "now at height \(Token.group(s.tailHeight ?? 0)); \(fresh) coin\(fresh == 1 ? "" : "s") received since the snapshot"
        default:
            return ""
        }
    }

    nonisolated static func sizes(_ text: String) -> [Int] {
        text.split(separator: ",").compactMap { p in
            let t = p.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasSuffix("m"), let v = Double(t.dropLast()) { return Int(v * 1_000_000) }
            if t.hasSuffix("k"), let v = Double(t.dropLast()) { return Int(v * 1000) }
            return Int(t)
        }
    }

    /// Each result also goes to the log, so a run in the Simulator can be read from the command line.
    private func logForAutomation(_ step: StepId, _ r: StepResult) {
        var lines = ["[pss] \(step.rawValue) \(r.ok ? "ok" : "FAILED") \(String(format: "%.1f", r.ms)) ms"]
        if let e = r.error { lines.append("[pss]   error: \(e)") }
        for row in r.rows { lines.append("[pss]   \(row.key): \(row.value)") }
        for s in r.sections {
            lines.append("[pss]   == \(s.title)")
            for row in s.rows { lines.append("[pss]     \(row.key): \(row.value)") }
        }
        for e in r.exchanges { lines.append("[pss]   \(e.method) \(e.path) \(e.status) up \(e.requestBytes) down \(e.responseBytes) \(String(format: "%.1f", e.ms)) ms") }
        NSLog("%@", lines.joined(separator: "\n"))
    }

    /// Runs the given steps one after another (PSS_AUTORUN=keys,files,scan,… in the Simulator); "wallet" syncs the
    /// wallet tab with the launch environment's key, without keeping it.
    func autorun(_ items: [String]) {
        if !items.contains("wallet") { tab = .details }
        Task { @MainActor in
            for item in items {
                while busy { try? await Task.sleep(nanoseconds: 50_000_000) }
                if item == "wallet" {
                    await autorunWallet()
                } else if let step = StepId(rawValue: item) {
                    running = step
                    await execute(step)
                }
            }
            NSLog("[pss] autorun finished")
        }
    }

    private func autorunWallet() async {
        do {
            use(try WalletKey(mnemonic.isEmpty ? seedHex : mnemonic))
        } catch {
            NSLog("[pss] wallet FAILED: %@", String(describing: error))
            return
        }
        await syncNow()
        var lines = ["[pss] wallet \(syncError == nil ? "ok" : "FAILED") \(String(format: "%.1f", lastSyncMs)) ms"]
        for st in stages { lines.append("[pss]   \(st.title): \(st.state) \(String(format: "%.1f", st.ms)) ms; \(st.note)") }
        if let w = wallet {
            lines.append("[pss]   height \(w.height), \(w.coins.count) coins")
            for b in w.balances { lines.append("[pss]   balance \(b.amount) \(b.symbol) (\(b.coins) coins)") }
        }
        lines.append("[pss]   server saw \(serverSaw.requests) requests, \(serverSaw.pirCalls) PIR calls, \(serverSaw.bytesUp) B up, \(serverSaw.bytesDown) B down")
        NSLog("%@", lines.joined(separator: "\n"))
    }

    // ── the background test ──────────────────────────────────────────────────────────────────────────────────────

    func enteredBackground() {
        guard backgroundTest else { return }
        let s = state
        let secret = s.keys?.scanSecret ?? Data(repeating: 7, count: 32)
        let entries: Data = {
            if let m = s.manifest, let f = s.files[m.artifacts.scan.digest] { return f.prefix(36 * 50_000) }
            return Data(count: 36 * 1000)
        }()
        #if canImport(UIKit)
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "pss-gpu-test") { UIApplication.shared.endBackgroundTask(task) }
        #endif
        let stamp = Date()
        Task.detached {
            var lines: [String] = []
            for i in 0..<3 {
                let t = nowMs()
                do {
                    guard let scanner = s.metalScanner else { throw ClientError.invalid("no scanner") }
                    let r = try scanner.scan(entries: entries, secret: [UInt8](secret))
                    lines.append(String(format: "background GPU scan %d of %d entries: OK in %.0f ms (%@)", i + 1, entries.count / 36, nowMs() - t, r.timings.description))
                } catch {
                    lines.append(String(format: "background GPU scan %d: FAILED after %.0f ms: %@", i + 1, nowMs() - t, String(describing: error)))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let t = nowMs()
            do {
                var times = BuildTimes()
                if let m = s.manifest, let mul = s.metalMultiplier {
                    _ = try Pir.buildQueries(table: m.artifacts.readTable, columns: Array(repeating: 0, count: 32), multiplier: mul, times: &times)
                    lines.append(String(format: "background GPU multiply (A·s for one read call): OK in %.0f ms", nowMs() - t))
                }
            } catch {
                lines.append(String(format: "background GPU multiply: FAILED after %.0f ms: %@", nowMs() - t, String(describing: error)))
            }
            let header = "\(stamp.formatted(date: .omitted, time: .standard)) entered the background"
            let text = ([header] + lines).joined(separator: "\n")
            await MainActor.run {
                self.backgroundLog.insert(text, at: 0)
                NSLog("%@", text.split(separator: "\n").map { "[pss] background: \($0)" }.joined(separator: "\n"))
                #if canImport(UIKit)
                UIApplication.shared.endBackgroundTask(task)
                #endif
            }
        }
    }
}
