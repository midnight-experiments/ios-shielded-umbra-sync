// The wallet tab's pieces: the key kept in the Keychain, the key as typed, the Preprod test tokens' names, and what
// the wallet screen shows after a sync (built from the steps' shared state when no step runs).

import Foundation
import Security

/// The wallet's key in this device's Keychain: readable only while the phone is unlocked, never synced or backed up.
enum KeyStore {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.umbradb.pss-sync",
        kSecAttrAccount as String: "wallet-key",
    ]

    static func save(_ key: String) throws {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClientError.invalid("the Keychain refused the key (status \(status))") }
    }

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}

/// A key as the user enters it: a BIP-39 mnemonic, or a 32-byte Zswap seed in hex. Parsing derives the keys, so a
/// mistyped word is refused before anything is stored.
struct WalletKey {
    let mnemonic: String
    let seedHex: String
    let encryptionPublicKey: Data

    init(_ text: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = t.lowercased().hasPrefix("0x") ? String(t.dropFirst(2)) : t
        if hex.count == 64, hex.allSatisfy(\.isHexDigit) {
            encryptionPublicKey = try Core.keys(zswapSeed: Data(hex: hex, length: 32)).encryptionPublicKey
            mnemonic = ""
            seedHex = hex.lowercased()
        } else {
            let words = t.lowercased().split(whereSeparator: \.isWhitespace)
            guard [12, 15, 18, 21, 24].contains(words.count) else {
                throw ClientError.invalid("enter the 12 to 24 words of the mnemonic, or a Zswap seed of 64 hex characters")
            }
            mnemonic = words.joined(separator: " ")
            encryptionPublicKey = try Core.keys(mnemonic: mnemonic).encryptionPublicKey
            seedHex = ""
        }
    }

    var stored: String { mnemonic.isEmpty ? seedHex : mnemonic }
}

/// The shielded test tokens wallet A holds on Preprod (effectstream/mint-test-tokens' registry and the POC's pssUSD);
/// any other token type is shown by its first bytes, in base units.
struct Token {
    let symbol: String
    let decimals: Int

    static let known: [String: Token] = [
        "087d1d5d35316e7e25a1b069ac302742547d784f46410deb4d20266fd3ea9f1f": Token(symbol: "twETH", decimals: 18),
        "a5c902be8fff1a0c3f10a926b24c3eaa8a93215535915b5af47d2c6a59febab5": Token(symbol: "twUSDC", decimals: 6),
        "ccfdc19774aea0e419bc53a6e65e0d13792e858dde64c7383ca4586aebb96975": Token(symbol: "pssUSD", decimals: 6),
    ]

    static func of(_ type: Data) -> Token { known[type.hex] ?? Token(symbol: "\(type.prefix(4).hex)…", decimals: 0) }

    func format(_ v: UInt128Compat) -> String {
        var digits = v.description
        guard decimals > 0 else { return Self.group(digits) }
        if digits.count <= decimals { digits = String(repeating: "0", count: decimals - digits.count + 1) + digits }
        var frac = String(digits.suffix(decimals))
        while frac.hasSuffix("0") { frac.removeLast() }
        return Self.group(String(digits.dropLast(decimals))) + (frac.isEmpty ? "" : "." + frac)
    }

    static func group(_ s: String) -> String {
        var out = ""
        for (i, c) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return out
    }

    static func group(_ n: Int) -> String { group(String(n)) }
}

/// One line of the wallet's sync: a step of the Details tab, said as what it does for the wallet.
struct SyncStage: Identifiable {
    enum State { case waiting, running, done, skipped, failed }
    let id: StepId
    var state: State = .waiting
    var note: String
    var ms = 0.0

    init(_ id: StepId) {
        self.id = id
        note = Self.what(id)
    }

    var title: String {
        switch id {
        case .keys: "Derive your keys"
        case .files: "Download the public snapshot"
        case .scan: "Find your outputs"
        case .read: "Read your coins"
        case .nullifiers: "Check which are spent"
        case .tail: "Catch up with the chain"
        default: id.title
        }
    }

    static func what(_ id: StepId) -> String {
        switch id {
        case .keys: "on this device, from the key"
        case .files: "the same files for every wallet"
        case .scan: "on this device's GPU"
        case .read: "by private retrieval: the server cannot tell which records"
        case .nullifiers: "by private retrieval"
        case .tail: "every output and spend since the snapshot"
        default: ""
        }
    }
}

/// What the server received during one sync, summed over its requests.
struct ServerView {
    var requests = 0
    var pirCalls = 0
    var bytesUp = 0
    var bytesDown = 0

    mutating func add(_ exchanges: [Exchange]) {
        for e in exchanges {
            requests += 1
            if e.path.contains("/query/") { pirCalls += 1 }
            bytesUp += e.requestBytes
            bytesDown += e.responseBytes
        }
    }
}

/// The wallet screen's content after a sync.
struct WalletSummary {
    struct Balance: Identifiable {
        let id: String
        let symbol: String
        let amount: String
        let coins: Int
    }

    struct CoinLine: Identifiable {
        let id: Int
        let amount: String
        let symbol: String
        let source: String
        let spent: String?
    }

    let address: String
    let network: String
    let snapshotHeight: Int
    let height: Int
    let balances: [Balance]
    let coins: [CoinLine]

    init?(_ s: ClientState) {
        guard let k = s.keys, let m = s.manifest else { return nil }
        network = m.network
        address = Bech32m.shieldedAddress(k.coinPublicKey, k.encryptionPublicKey, network: m.network)
        snapshotHeight = m.height
        height = s.tailHeight ?? m.height
        var sums: [Data: (UInt128Compat, Int)] = [:]
        for c in s.coins.values where c.spent == nil {
            let (v, n) = sums[c.tokenType] ?? (.zero, 0)
            sums[c.tokenType] = (v + c.value, n + 1)
        }
        balances = sums.map { type, sum in
            let t = Token.of(type)
            return Balance(id: type.hex, symbol: t.symbol, amount: t.format(sum.0), coins: sum.1)
        }.sorted { $0.symbol < $1.symbol }
        coins = s.coins.values.sorted { ($0.spent == nil ? 0 : 1, -$0.position) < ($1.spent == nil ? 0 : 1, -$1.position) }.map { c in
            let t = Token.of(c.tokenType)
            let source = c.source == "tail" ? "received after the snapshot" : "in the snapshot"
            return CoinLine(id: c.position, amount: t.format(c.value), symbol: t.symbol,
                            source: "output \(Token.group(c.position)), \(source)",
                            spent: c.spent == nil ? nil : c.spentHeight.map { "spent at height \(Token.group($0))" } ?? "spent")
        }
    }
}

func formatMs(_ ms: Double) -> String { ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000) }
