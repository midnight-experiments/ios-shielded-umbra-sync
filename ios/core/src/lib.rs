//! Native core of the private shielded sync client, for the iOS app: a C API (`include/pss_core.h`, module `PssCore`)
//! over the scan kernel (`pss-kernel`, the same crate the web and Node clients run as WebAssembly) and the wallet's
//! shielded key derivation.
//!
//! The keys are derived as the TypeScript client derives them (`client/sdk/seeds.ts`, `client/keys.ts`,
//! `web/worker.ts` `deriveKeys`):
//!
//! 1. the BIP-39 seed of the mnemonic, empty passphrase (`@scure/bip39` `mnemonicToSeedSync`);
//! 2. BIP-32 over secp256k1 at `m/44'/2400'/0'/3/0` (the wallet SDK's `HDWallet`, `@scure/bip32`); the derived private
//!    key is the 32-byte Zswap seed;
//! 3. the ledger's `ZswapSecretKeys.fromSeed`: `Seed::derive_coin_secret_key` and `Seed::derive_encryption_secret_key`
//!    of `midnight-zswap` 9.0.1 (`src/keys.rs`), ported below because that crate pulls in the on-chain runtime.
//!
//! Byte layouts, as the TypeScript client holds them: the coin public key is the 32 bytes of the ledger package's
//! `coinPublicKey` hex; the encryption public key the 32 bytes of its `encryptionPublicKey` hex (the compressed
//! point); the scan secret the encryption secret key's scalar, 32 bytes little-endian (`kernel/secret-key.ts`); the
//! coin secret key the 32 bytes that follow the tag `midnight:zswap-coin-secret-key[v1]:` in
//! `CoinSecretKey.yesIKnowTheSecurityImplicationsOfThis_serialize()`, the key `coinNullifier` takes.
//!
//! Status codes follow the kernel's: 1 success, 0 a rejected input (an invalid mnemonic, a point the ledger would not
//! accept, a non-canonical field element, a failed decryption), -1 an invalid secret. This crate adds -2 for a null
//! pointer or an out-of-range count. Every function is reentrant and may run on any thread.

use base_crypto::hash::{HashOutput, PERSISTENT_HASH_BYTES, PersistentHashWriter};
use base_crypto::repr::MemWrite;
use bip32::{ChildNumber, XPrv};
use bip39::{Language, Mnemonic};
use coin_structure::coin::{self, Info, Nonce, ShieldedTokenType};
use coin_structure::transfer::SenderEvidence;
use pss_kernel::{CIPHERTEXT_BYTES, COIN_BYTES, decrypt_coin_of, write_coin};
use std::borrow::Cow;
use transient_crypto::encryption;
use zeroize::{Zeroize, Zeroizing};

#[cfg(test)]
mod tests;

pub const OK: i32 = 1;
pub const REJECTED: i32 = 0;
pub const BAD_SECRET: i32 = -1;
pub const BAD_ARGUMENT: i32 = -2;

/// A wallet's shielded keys. `scan_secret` and `coin_secret_key` are secret.
#[repr(C)]
#[derive(Clone, Default, PartialEq, Eq)]
pub struct PssKeys {
    pub coin_public_key: [u8; 32],
    pub encryption_public_key: [u8; 32],
    pub scan_secret: [u8; 32],
    pub coin_secret_key: [u8; 32],
}

/// Shows the public keys only, as the ledger's key types do.
impl std::fmt::Debug for PssKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let hex = |b: &[u8; 32]| b.iter().map(|x| format!("{x:02x}")).collect::<String>();
        f.debug_struct("PssKeys")
            .field("coin_public_key", &hex(&self.coin_public_key))
            .field("encryption_public_key", &hex(&self.encryption_public_key))
            .finish_non_exhaustive()
    }
}

// ---- Key derivation ----

/// The BIP-32 path of the Zswap seed: `m/44'/2400'/0'/3/0` (purpose 44, coin type 2400, account 0, role 3 = Zswap,
/// index 0), as the wallet SDK's `WalletSeeds.fromMasterSeed(…).shielded` derives it.
const ZSWAP_PATH: [ChildNumber; 5] = [
    ChildNumber(44 | ChildNumber::HARDENED_FLAG),
    ChildNumber(2400 | ChildNumber::HARDENED_FLAG),
    ChildNumber(ChildNumber::HARDENED_FLAG),
    ChildNumber(3),
    ChildNumber(0),
];

#[derive(Debug, PartialEq, Eq)]
pub enum MnemonicError {
    /// Not a valid BIP-39 English phrase (word count, unknown word, checksum).
    Invalid,
    /// BIP-32 gives no key at the path for this seed (a derived scalar out of range; probability about 2^-127).
    NoKey,
}

/// The Zswap seed of a BIP-39 English mnemonic. Words may be separated by any run of whitespace, with any leading or
/// trailing whitespace, as the TypeScript client accepts them (`trim().split(/\s+/).join(" ")`); the phrase is NFKD
/// normalized as `@scure/bip39` normalizes it.
pub fn zswap_seed_from_mnemonic(phrase: &str) -> Result<Zeroizing<[u8; 32]>, MnemonicError> {
    let mnemonic = Mnemonic::parse_in(Language::English, phrase).map_err(|_| MnemonicError::Invalid)?;
    // `Mnemonic` is zeroized on drop (feature `zeroize`).
    let master = Zeroizing::new(mnemonic.to_seed(""));
    drop(mnemonic);
    // Each intermediate `XPrv`'s private key is zeroized on drop (k256's `SigningKey`).
    let mut key = XPrv::new(&master[..]).map_err(|_| MnemonicError::NoKey)?;
    for child in ZSWAP_PATH {
        key = key.derive_child(child).map_err(|_| MnemonicError::NoKey)?;
    }
    Ok(Zeroizing::new(key.to_bytes()))
}

/// `Seed::sample_bytes` of `midnight-zswap` 9.0.1: round `r` contributes
/// `H(domain ‖ H(r as u64 little-endian ‖ seed))`, truncated to the bytes still needed; `H` is the ledger's persistent
/// hash (SHA-256).
pub fn sample_bytes(seed: &[u8; 32], no_of_bytes: usize, domain_separator: &[u8]) -> Zeroizing<Vec<u8>> {
    let rounds = no_of_bytes.div_ceil(PERSISTENT_HASH_BYTES);
    // The exact capacity up front, so no reallocation leaves sampled bytes behind.
    let mut res = Zeroizing::new(Vec::with_capacity(no_of_bytes));
    for round in 0..rounds {
        let mut outer_writer = PersistentHashWriter::new();
        MemWrite::write(&mut outer_writer, domain_separator);
        let mut inner_hash = {
            let mut inner_writer = PersistentHashWriter::new();
            MemWrite::write(&mut inner_writer, &(round as u64).to_le_bytes());
            MemWrite::write(&mut inner_writer, seed);
            inner_writer.finalize().0
        };
        MemWrite::write(&mut outer_writer, &inner_hash);
        inner_hash.zeroize();
        let mut round_hash = outer_writer.finalize();
        let bytes_to_add = PERSISTENT_HASH_BYTES.min(no_of_bytes - round * PERSISTENT_HASH_BYTES);
        res.extend_from_slice(&round_hash.0[..bytes_to_add]);
        round_hash.zeroize();
    }
    res
}

/// `Seed::derive_coin_secret_key` of `midnight-zswap` 9.0.1: `H("midnight:csk" ‖ seed)`.
pub fn derive_coin_secret_key(seed: &[u8; 32]) -> coin::SecretKey {
    let mut hash_writer = PersistentHashWriter::new();
    MemWrite::write(&mut hash_writer, b"midnight:csk");
    MemWrite::write(&mut hash_writer, seed);
    coin::SecretKey(hash_writer.finalize())
}

/// `Seed::derive_encryption_secret_key` of `midnight-zswap` 9.0.1: 64 sampled bytes under `"midnight:esk"`, reduced
/// modulo the Jubjub scalar field's order (`SecretKey::from_uniform_bytes`).
pub fn derive_encryption_secret_key(seed: &[u8; 32]) -> encryption::SecretKey {
    let raw_bytes = sample_bytes(seed, 64, b"midnight:esk");
    let mut raw_bytes_arr: [u8; 64] = raw_bytes[..].try_into().expect("64 sampled bytes");
    drop(raw_bytes);
    let res = encryption::SecretKey::from_uniform_bytes(&raw_bytes_arr);
    raw_bytes_arr.zeroize();
    res
}

/// `coin::SecretKey::public_key`, `H("midnight:zswap-pk[v1]" ‖ secret key)`, through the hash writer (zeroized on
/// drop) instead of the ledger's unzeroized buffer. The tests check it against the ledger's function.
pub fn coin_public_key_of(secret: &coin::SecretKey) -> [u8; 32] {
    let mut hash_writer = PersistentHashWriter::new();
    MemWrite::write(&mut hash_writer, b"midnight:zswap-pk[v1]");
    MemWrite::write(&mut hash_writer, &secret.0.0);
    hash_writer.finalize().0
}

/// The keys of a 32-byte Zswap seed, as `ZswapSecretKeys.fromSeed` gives them.
pub fn keys_from_zswap_seed(seed: &[u8; 32]) -> PssKeys {
    let mut keys = PssKeys::default();
    // `coin::SecretKey` is zeroized on drop; `encryption::SecretKey` is `Copy` and zeroized here.
    let coin_secret_key = derive_coin_secret_key(seed);
    let mut encryption_secret_key = derive_encryption_secret_key(seed);
    keys.coin_secret_key = coin_secret_key.0.0;
    keys.coin_public_key = coin_public_key_of(&coin_secret_key);
    keys.scan_secret = encryption_secret_key.repr();
    let mut public = Vec::with_capacity(32);
    serialize::Serializable::serialize(&encryption_secret_key.public_key(), &mut public).expect("writing to a vector");
    keys.encryption_public_key.copy_from_slice(&public);
    encryption_secret_key.zeroize();
    keys
}

/// A coin in the kernel's 80-byte layout: value (16, little-endian), token type (32), nonce (32).
pub fn coin_info(coin: &[u8; COIN_BYTES]) -> Info {
    let mut value = [0u8; 16];
    value.copy_from_slice(&coin[..16]);
    let mut type_ = [0u8; 32];
    type_.copy_from_slice(&coin[16..48]);
    let mut nonce = [0u8; 32];
    nonce.copy_from_slice(&coin[48..80]);
    Info { value: u128::from_le_bytes(value), type_: ShieldedTokenType(HashOutput(type_)), nonce: Nonce(HashOutput(nonce)) }
}

/// `coinNullifier(coin, coinSecretKey)`: the ledger's `Info::nullifier` with the user's coin secret key.
pub fn nullifier_of(coin: &[u8; COIN_BYTES], coin_secret_key: &[u8; 32]) -> [u8; 32] {
    // Zeroized on drop.
    let secret = coin::SecretKey(HashOutput(*coin_secret_key));
    coin_info(coin).nullifier(&SenderEvidence::User(Cow::Borrowed(&secret))).0.0
}

// ---- C API ----

/// `N` bytes at `p`, or `None` if `p` is null.
///
/// # Safety
/// A non-null `p` must address `N` readable bytes that stay valid and unchanged for `'a`.
unsafe fn array<'a, const N: usize>(p: *const u8) -> Option<&'a [u8; N]> {
    if p.is_null() { None } else { Some(unsafe { &*(p as *const [u8; N]) }) }
}

/// `N` writable bytes at `p`, or `None` if `p` is null.
///
/// # Safety
/// A non-null `p` must address `N` writable bytes, not aliased for `'a`.
unsafe fn array_mut<'a, const N: usize>(p: *mut u8) -> Option<&'a mut [u8; N]> {
    if p.is_null() { None } else { Some(unsafe { &mut *(p as *mut [u8; N]) }) }
}

/// The entry count the scan functions accept: their status is an `i32`.
fn count_ok(count: u32) -> bool {
    count <= i32::MAX as u32
}

/// Derives the keys of a BIP-39 English mnemonic (UTF-8, `len` bytes): returns 1, 0 if it is not a valid mnemonic
/// (or not UTF-8), -1 if BIP-32 gives no key at the path (probability about 2^-127), -2 if `out` is null. `out` is
/// zero on any status but 1.
///
/// # Safety
/// `utf8` must address `len` readable bytes (it may be null when `len` is 0); `out` must address a `PssKeys`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_keys_from_mnemonic(utf8: *const u8, len: u32, out: *mut PssKeys) -> i32 {
    if out.is_null() {
        return BAD_ARGUMENT;
    }
    // Written without reading or dropping what was there: the caller's struct may be uninitialized.
    unsafe { out.write(PssKeys::default()) };
    if len == 0 {
        return REJECTED;
    }
    if utf8.is_null() {
        return BAD_ARGUMENT;
    }
    let bytes = unsafe { std::slice::from_raw_parts(utf8, len as usize) };
    let Ok(phrase) = std::str::from_utf8(bytes) else { return REJECTED };
    match zswap_seed_from_mnemonic(phrase) {
        Ok(seed) => {
            unsafe { out.write(keys_from_zswap_seed(&seed)) };
            OK
        }
        Err(MnemonicError::Invalid) => REJECTED,
        Err(MnemonicError::NoKey) => BAD_SECRET,
    }
}

/// Derives the keys of a 32-byte Zswap seed (`ZswapSecretKeys.fromSeed`): returns 1, or -2 if a pointer is null.
///
/// # Safety
/// `seed` must address 32 readable bytes; `out` must address a `PssKeys`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_keys_from_zswap_seed(seed: *const u8, out: *mut PssKeys) -> i32 {
    let (Some(seed), false) = (unsafe { array::<32>(seed) }, out.is_null()) else { return BAD_ARGUMENT };
    let seed = Zeroizing::new(*seed);
    unsafe { out.write(keys_from_zswap_seed(&seed)) };
    OK
}

/// The kernel's `scan`: tests `count` 36-byte entries and writes the matching positions (relative to `entries`) to
/// `out_indices`, which must hold `count` of them. Returns the number of matches, -1 for an invalid secret, -2 for a
/// null pointer or a count above `INT32_MAX`.
///
/// # Safety
/// `entries` must address `count × 36` readable bytes, `secret` 32, `out_indices` `count` writable, 4-byte aligned
/// `uint32_t`; `entries` and `out_indices` may be null when `count` is 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_scan(entries: *const u8, count: u32, secret: *const u8, out_indices: *mut u32) -> i32 {
    if secret.is_null() || !count_ok(count) {
        return BAD_ARGUMENT;
    }
    if count == 0 {
        let empty = [0u8; 0];
        let mut none = [0u32; 0];
        return unsafe { pss_kernel::scan(empty.as_ptr(), 0, secret, none.as_mut_ptr()) };
    }
    if entries.is_null() || out_indices.is_null() {
        return BAD_ARGUMENT;
    }
    unsafe { pss_kernel::scan(entries, count, secret, out_indices) }
}

/// The kernel's `scan_values`: for each of `count` entries, the 32-byte value the ownership test compares
/// (`Poseidon(k, 0)`), 32 zero bytes for an all-zero entry or bytes that are not a curve point. Returns `count`, -1 for
/// an invalid secret, -2 for a null pointer or a count above `INT32_MAX`.
///
/// # Safety
/// `entries` must address `count × 36` readable bytes, `secret` 32, `out_values` `count × 32` writable; `entries` and
/// `out_values` may be null when `count` is 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_scan_values(entries: *const u8, count: u32, secret: *const u8, out_values: *mut u8) -> i32 {
    if secret.is_null() || !count_ok(count) {
        return BAD_ARGUMENT;
    }
    if count == 0 {
        let empty = [0u8; 0];
        let mut none = [0u8; 0];
        return unsafe { pss_kernel::scan_values(empty.as_ptr(), 0, secret, none.as_mut_ptr()) };
    }
    if entries.is_null() || out_values.is_null() {
        return BAD_ARGUMENT;
    }
    unsafe { pss_kernel::scan_values(entries, count, secret, out_values) }
}

/// The kernel's `pads`: the six pads `Poseidon(k, i)`, `i = 0 … 5`, of a ciphertext's point (6 × 32 bytes). Returns 1,
/// 0 if the ledger would not accept the point, -1 for an invalid secret, -2 for a null pointer.
///
/// # Safety
/// `point` and `secret` must address 32 readable bytes, `out` 192 writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_pads(point: *const u8, secret: *const u8, out: *mut u8) -> i32 {
    if point.is_null() || secret.is_null() || out.is_null() {
        return BAD_ARGUMENT;
    }
    unsafe { pss_kernel::pads(point, secret, out) }
}

/// The ledger's decryption of a 224-byte ciphertext (point, elements 0–5) into a coin in the 80-byte layout (value 16
/// little-endian, token type 32, nonce 32). Returns 1, 0 if it does not decrypt for this secret (`out_coin` zero), -1
/// for an invalid secret, -2 for a null pointer. The kernel's `decrypt_coin` writes the same coin after a flag byte.
///
/// # Safety
/// `ciphertext` must address 224 readable bytes, `secret` 32, `out_coin` 80 writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_decrypt_coin(ciphertext: *const u8, secret: *const u8, out_coin: *mut u8) -> i32 {
    let (Some(ciphertext), Some(secret), Some(out)) = (unsafe {
        (array::<CIPHERTEXT_BYTES>(ciphertext), array::<32>(secret), array_mut::<COIN_BYTES>(out_coin))
    }) else {
        return BAD_ARGUMENT;
    };
    out.fill(0);
    match decrypt_coin_of(ciphertext, secret) {
        Err(()) => BAD_SECRET,
        Ok(None) => REJECTED,
        Ok(Some(info)) => {
            write_coin(&info, out);
            OK
        }
    }
}

/// The kernel's `commitment`: `coinCommitment(coin, coinPublicKey)` of a coin in the 80-byte layout. Returns 1, or -2
/// for a null pointer.
///
/// # Safety
/// `coin` must address 80 readable bytes, `coin_public_key` 32, `out` 32 writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_commitment(coin: *const u8, coin_public_key: *const u8, out: *mut u8) -> i32 {
    if coin.is_null() || coin_public_key.is_null() || out.is_null() {
        return BAD_ARGUMENT;
    }
    unsafe { pss_kernel::commitment(coin, coin_public_key, out) }
}

/// `coinNullifier(coin, coinSecretKey)` of a coin in the 80-byte layout. Returns 1, or -2 for a null pointer.
///
/// # Safety
/// `coin` must address 80 readable bytes, `coin_secret_key` 32, `out` 32 writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_nullifier(coin: *const u8, coin_secret_key: *const u8, out: *mut u8) -> i32 {
    let (Some(coin), Some(secret), Some(out)) =
        (unsafe { (array::<COIN_BYTES>(coin), array::<32>(coin_secret_key), array_mut::<32>(out)) })
    else {
        return BAD_ARGUMENT;
    };
    *out = nullifier_of(coin, secret);
    OK
}

/// The kernel's `leaf`: a commitment's tree leaf, `degrade_to_transient(commitment)`, 32 bytes little-endian. Returns
/// 1, or -2 for a null pointer.
///
/// # Safety
/// `commitment` must address 32 readable bytes, `out` 32 writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_leaf(commitment: *const u8, out: *mut u8) -> i32 {
    if commitment.is_null() || out.is_null() {
        return BAD_ARGUMENT;
    }
    unsafe { pss_kernel::leaf(commitment, out) }
}

/// The kernel's `hash2_raw`: `Poseidon(a, b)` of two field elements, 32 bytes little-endian each. Returns 1, 0 if
/// either is not canonical, -2 for a null pointer.
///
/// # Safety
/// `a` and `b` must address 32 readable bytes, `out` 32 writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_hash2(a: *const u8, b: *const u8, out: *mut u8) -> i32 {
    if a.is_null() || b.is_null() || out.is_null() {
        return BAD_ARGUMENT;
    }
    unsafe { pss_kernel::hash2_raw(a, b, out) }
}

/// The kernel's `public_key`: the encryption public key `G × secret`, 32 bytes compressed. Returns 1, -1 for an
/// invalid secret, -2 for a null pointer.
///
/// # Safety
/// `secret` must address 32 readable bytes, `out` 32 writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pss_public_key(secret: *const u8, out: *mut u8) -> i32 {
    if secret.is_null() || out.is_null() {
        return BAD_ARGUMENT;
    }
    unsafe { pss_kernel::public_key(secret, out) }
}
