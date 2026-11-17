// The Zswap commitment tree's helpers (client/tree.ts), with the ledger's Poseidon from the Rust core; and shielded
// addresses (client/address.ts, bech32m).

import Foundation

enum Tree {
    static let depth = 32
    static let zero = Data(count: 32)

    /// The levels over `leaves` (later positions empty) up `depth` levels; the last level holds the root.
    static func levels(_ leaves: [Data], depth: Int) -> [[Data]] {
        var levels = [leaves]
        for h in 0..<depth {
            let below = levels[h]
            levels.append((0..<((below.count + 1) / 2)).map { j in Core.hash2(below[2 * j], 2 * j + 1 < below.count ? below[2 * j + 1] : zero) })
        }
        return levels
    }

    /// The root over the blocks' roots (the tree above the cut at k).
    static func rootOverBlocks(_ blockRoots: Data, k: Int) throws -> Data {
        guard blockRoots.count % 32 == 0 else { throw ClientError.invalid("block roots are not whole hashes") }
        let roots = stride(from: 0, to: blockRoots.count, by: 32).map { blockRoots.sub($0, 32) }
        return levels(roots, depth: depth - k).last!.first ?? zero
    }

    /// The root from a leaf, its index and its siblings (bottom up).
    static func rootFromPath(_ leaf: Data, index: Int, siblings: [Data]) -> Data {
        var node = leaf
        for (h, s) in siblings.enumerated() { node = (index >> h) & 1 == 0 ? Core.hash2(node, s) : Core.hash2(s, node) }
        return node
    }
}

enum Bech32m {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let const: UInt32 = 0x2bc830a3

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> i) & 1 == 1 { chk ^= gen[i] }
        }
        return chk
    }

    static func encode(hrp: String, data: Data) -> String {
        var words: [UInt8] = []
        var acc = 0, bits = 0
        for b in data {
            acc = acc << 8 | Int(b)
            bits += 8
            while bits >= 5 { bits -= 5; words.append(UInt8((acc >> bits) & 31)) }
        }
        if bits > 0 { words.append(UInt8((acc << (5 - bits)) & 31)) }
        let h = Array(hrp.utf8)
        let expanded = h.map { $0 >> 5 } + [0] + h.map { $0 & 31 }
        let mod = polymod(expanded + words + [0, 0, 0, 0, 0, 0]) ^ const
        let checksum = (0..<6).map { UInt8((mod >> (5 * (5 - $0))) & 31) }
        return hrp + "1" + String((words + checksum).map { charset[Int($0)] })
    }

    static func shieldedAddress(_ coinPublicKey: Data, _ encryptionPublicKey: Data, network: String) -> String {
        encode(hrp: network == "mainnet" ? "mn_shield-addr" : "mn_shield-addr_\(network)", data: coinPublicKey + encryptionPublicKey)
    }
}
