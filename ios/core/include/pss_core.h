/*
 * PssCore: the native core of the private shielded sync client (Rust, ios/core/src/lib.rs).
 *
 * The scan kernel (the same Rust crate the web and Node clients run as WebAssembly) and the wallet's shielded key
 * derivation, as the TypeScript client derives it: BIP-39 seed (empty passphrase) -> BIP-32 m/44'/2400'/0'/3/0 ->
 * 32-byte Zswap seed -> the ledger's ZswapSecretKeys.fromSeed.
 *
 * Bytes: a curve point is its 32-byte compressed encoding; a field element 32 bytes little-endian; a coin 80 bytes
 * (value 16 little-endian, token type 32, nonce 32); a scan entry 36 bytes (point, first 4 bytes of element 0); a
 * ciphertext 224 bytes (point, elements 0-5).
 *
 * Status: PSS_OK (1) success; PSS_REJECTED (0) a rejected input (an invalid mnemonic, a point the ledger would not
 * accept, a non-canonical field element, a failed decryption); PSS_BAD_SECRET (-1) an invalid secret;
 * PSS_BAD_ARGUMENT (-2) a null pointer or a count above INT32_MAX. Every function is reentrant and may run on any
 * thread. Buffers may not overlap.
 */

#ifndef PSS_CORE_H
#define PSS_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef __clang__
#define _Nullable
#endif

#pragma clang assume_nonnull begin

#define PSS_OK 1
#define PSS_REJECTED 0
#define PSS_BAD_SECRET (-1)
#define PSS_BAD_ARGUMENT (-2)

#define PSS_ENTRY_BYTES 36
#define PSS_CIPHERTEXT_BYTES 224
#define PSS_COIN_BYTES 80
#define PSS_PADS_BYTES 192

/*
 * A wallet's shielded keys.
 * coin_public_key:       the ledger package's coinPublicKey (hex) as bytes.
 * encryption_public_key: the ledger package's encryptionPublicKey (hex) as bytes, the compressed point.
 * scan_secret:           the encryption secret key's scalar, 32 bytes little-endian (kernel/secret-key.ts). Secret.
 * coin_secret_key:       the 32 bytes after the tag "midnight:zswap-coin-secret-key[v1]:" of the package's
 *                        CoinSecretKey serialization, the key coinNullifier takes. Secret.
 */
typedef struct {
    uint8_t coin_public_key[32];
    uint8_t encryption_public_key[32];
    uint8_t scan_secret[32];
    uint8_t coin_secret_key[32];
} PssKeys;

/* Keys of a BIP-39 English mnemonic, `len` bytes of UTF-8 (any whitespace between words; NFKD normalized).
 * 1 ok; 0 not a valid mnemonic or not UTF-8; -1 BIP-32 gives no key at the path (probability about 2^-127);
 * -2 `out` null, or `utf8` null with `len` > 0. `out` is all zero on any status but 1. */
int32_t pss_keys_from_mnemonic(const uint8_t *_Nullable utf8, uint32_t len, PssKeys *out);

/* Keys of a 32-byte Zswap seed (ZswapSecretKeys.fromSeed). 1 ok; -2 null pointer. */
int32_t pss_keys_from_zswap_seed(const uint8_t *seed /* 32 */, PssKeys *out);

/* The kernel's scan: tests `count` 36-byte entries and writes the matching positions (relative to `entries`) to
 * `out_indices`, which must hold `count` values. Returns the number of matches; -1 bad secret; -2 null pointer or
 * count > INT32_MAX. `entries` and `out_indices` may be null when `count` is 0. */
int32_t pss_scan(const uint8_t *_Nullable entries, uint32_t count, const uint8_t *secret /* 32 */,
                 uint32_t *_Nullable out_indices);

/* The kernel's scan_values: per entry, the 32-byte value the ownership test compares (Poseidon(k, 0)); zero for an
 * all-zero entry or bytes that are not a curve point. Returns `count`; -1 bad secret; -2 null pointer or
 * count > INT32_MAX. `out_values` holds count x 32 bytes. */
int32_t pss_scan_values(const uint8_t *_Nullable entries, uint32_t count, const uint8_t *secret /* 32 */,
                        uint8_t *_Nullable out_values);

/* The six pads Poseidon(k, i), i = 0..5, of a ciphertext's point. 1 ok; 0 the ledger would not accept the point;
 * -1 bad secret; -2 null pointer. */
int32_t pss_pads(const uint8_t *point /* 32 */, const uint8_t *secret /* 32 */, uint8_t *out /* 192 */);

/* The ledger's decryption of a ciphertext into a coin. 1 ok; 0 not for this secret (`out_coin` zero); -1 bad secret;
 * -2 null pointer. */
int32_t pss_decrypt_coin(const uint8_t *ciphertext /* 224 */, const uint8_t *secret /* 32 */,
                         uint8_t *out_coin /* 80 */);

/* coinCommitment(coin, coinPublicKey). 1 ok; -2 null pointer. */
int32_t pss_commitment(const uint8_t *coin /* 80 */, const uint8_t *coin_public_key /* 32 */, uint8_t *out /* 32 */);

/* coinNullifier(coin, coinSecretKey). 1 ok; -2 null pointer. */
int32_t pss_nullifier(const uint8_t *coin /* 80 */, const uint8_t *coin_secret_key /* 32 */, uint8_t *out /* 32 */);

/* A commitment's tree leaf, degrade_to_transient(commitment), as a field element. 1 ok; -2 null pointer. */
int32_t pss_leaf(const uint8_t *commitment /* 32 */, uint8_t *out /* 32 */);

/* Poseidon(a, b) of two field elements. 1 ok; 0 either is not canonical; -2 null pointer. */
int32_t pss_hash2(const uint8_t *a /* 32 */, const uint8_t *b /* 32 */, uint8_t *out /* 32 */);

/* The encryption public key G x secret, compressed. 1 ok; -1 bad secret; -2 null pointer. */
int32_t pss_public_key(const uint8_t *secret /* 32 */, uint8_t *out /* 32 */);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* PSS_CORE_H */
