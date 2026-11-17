// Swift face of the Rust core (ios/core, PssCore.xcframework): the scan kernel's ownership test, decryption,
// commitments, Merkle hashes, and the wallet's keys and nullifiers, all from the Midnight ledger's own crates.

import Foundation
import PssCore

struct WalletKeys {
    let coinPublicKey: Data
    let encryptionPublicKey: Data
    /// The encryption secret key's scalar: only the scan takes it. Never shown or sent.
    let scanSecret: Data
    /// For nullifiers. Never shown or sent.
    let coinSecretKey: Data
}

struct DecryptedCoin {
    let value: UInt128Compat
    let tokenType: Data
    let nonce: Data
    /// The kernel's layout: value (16 LE), token type (32), nonce (32).
    let raw: Data
}

/// A 128-bit value as two words (iOS 17 has no UInt128), shown in decimal.
struct UInt128Compat: CustomStringConvertible, Comparable {
    let lo: UInt64
    let hi: UInt64
    var description: String {
        if hi == 0 { return String(lo) }
        var (h, l) = (hi, lo)
        var digits: [Character] = []
        while h != 0 || l != 0 {
            let (qh, rh) = h.quotientAndRemainder(dividingBy: 10)
            let (ql, rl) = UInt64(10).dividingFullWidth((high: rh, low: l))
            h = qh
            l = ql
            digits.append(Character(String(rl)))
        }
        return String(digits.reversed())
    }
    static func < (a: UInt128Compat, b: UInt128Compat) -> Bool { a.hi != b.hi ? a.hi < b.hi : a.lo < b.lo }
    static func + (a: UInt128Compat, b: UInt128Compat) -> UInt128Compat {
        let (l, o) = a.lo.addingReportingOverflow(b.lo)
        return UInt128Compat(lo: l, hi: a.hi &+ b.hi &+ (o ? 1 : 0))
    }
    static let zero = UInt128Compat(lo: 0, hi: 0)
}

enum Core {
    private static func out(_ n: Int, _ body: (UnsafeMutablePointer<UInt8>) -> Int32) -> (Data, Int32) {
        var d = Data(count: n)
        let r = d.withUnsafeMutableBytes { body($0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
        return (d, r)
    }

    private static func ptr<R>(_ d: Data, _ body: (UnsafePointer<UInt8>) -> R) -> R {
        d.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
    }

    private static func keys(_ k: PssKeys) -> WalletKeys {
        var k = k
        return WalletKeys(coinPublicKey: withUnsafeBytes(of: &k.coin_public_key) { Data($0) },
                          encryptionPublicKey: withUnsafeBytes(of: &k.encryption_public_key) { Data($0) },
                          scanSecret: withUnsafeBytes(of: &k.scan_secret) { Data($0) },
                          coinSecretKey: withUnsafeBytes(of: &k.coin_secret_key) { Data($0) })
    }

    static func keys(mnemonic: String) throws -> WalletKeys {
        let words = Data(mnemonic.split(whereSeparator: \.isWhitespace).joined(separator: " ").utf8)
        var k = PssKeys()
        let r = ptr(words) { pss_keys_from_mnemonic($0, UInt32(words.count), &k) }
        defer { withUnsafeMutableBytes(of: &k) { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard r == 1 else { throw ClientError.invalid("not a valid BIP-39 English mnemonic") }
        return keys(k)
    }

    static func keys(zswapSeed: Data) throws -> WalletKeys {
        guard zswapSeed.count == 32 else { throw ClientError.invalid("a Zswap seed is 32 bytes") }
        var k = PssKeys()
        let r = ptr(zswapSeed) { pss_keys_from_zswap_seed($0, &k) }
        defer { withUnsafeMutableBytes(of: &k) { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard r == 1 else { throw ClientError.invalid("the seed gives no keys") }
        return keys(k)
    }

    /// Indices (in this slice) of the entries that pass the ownership test, on this thread.
    static func scan(_ entries: UnsafeRawBufferPointer, secret: Data) throws -> [Int] {
        let count = entries.count / 36
        guard count > 0 else { return [] }
        var hits = [UInt32](repeating: 0, count: count)
        let n = ptr(secret) { s in hits.withUnsafeMutableBufferPointer { pss_scan(entries.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(count), s, $0.baseAddress!) } }
        guard n >= 0 else { throw ClientError.invalid("the scan secret is not a valid scalar") }
        return hits.prefix(Int(n)).map(Int.init)
    }

    /// The scan over all cores: slices of the entries on concurrent threads.
    static func scanParallel(_ file: Data, secret: Data, threads: Int, progress: ((Int) -> Void)? = nil) throws -> [Int] {
        let count = file.count / 36
        let slices = max(1, min(count / 256, threads * 8))
        var results = [[Int]](repeating: [], count: slices)
        var failed = false
        let lock = NSLock()
        var done = 0
        file.withUnsafeBytes { raw in
            let run = { (i: Int) in
                let a = count * i / slices, b = count * (i + 1) / slices
                let r = (try? scan(UnsafeRawBufferPointer(rebasing: raw[(36 * a)..<(36 * b)]), secret: secret)) ?? nil
                lock.withLock {
                    if let r { results[i] = r.map { $0 + a } } else { failed = true }
                    done += b - a
                    progress?(done)
                }
            }
            if threads == 1 { for i in 0..<slices { run(i) } } else { DispatchQueue.concurrentPerform(iterations: slices, execute: run) }
        }
        if failed { throw ClientError.invalid("the scan secret is not a valid scalar") }
        return results.flatMap { $0 }
    }

    static func pads(point: Data, secret: Data) -> Data? {
        let (d, r) = out(192) { o in ptr(point) { p in ptr(secret) { s in pss_pads(p, s, o) } } }
        return r == 1 ? d : nil
    }

    static func decryptCoin(ciphertext: Data, secret: Data) -> DecryptedCoin? {
        let (d, r) = out(80) { o in ptr(ciphertext) { c in ptr(secret) { s in pss_decrypt_coin(c, s, o) } } }
        guard r == 1 else { return nil }
        return DecryptedCoin(value: UInt128Compat(lo: d.u64(0), hi: d.u64(8)), tokenType: d.sub(16, 32), nonce: d.sub(48, 32), raw: d)
    }

    static func commitment(coin: DecryptedCoin, coinPublicKey: Data) -> Data {
        out(32) { o in ptr(coin.raw) { c in ptr(coinPublicKey) { k in pss_commitment(c, k, o) } } }.0
    }

    static func nullifier(coin: DecryptedCoin, coinSecretKey: Data) -> Data {
        out(32) { o in ptr(coin.raw) { c in ptr(coinSecretKey) { k in pss_nullifier(c, k, o) } } }.0
    }

    static func leaf(_ commitment: Data) -> Data { out(32) { o in ptr(commitment) { pss_leaf($0, o) } }.0 }

    static func hash2(_ a: Data, _ b: Data) -> Data { out(32) { o in ptr(a) { x in ptr(b) { y in pss_hash2(x, y, o) } } }.0 }

    static func publicKey(secret: Data) -> Data? {
        let (d, r) = out(32) { o in ptr(secret) { pss_public_key($0, o) } }
        return r == 1 ? d : nil
    }
}
