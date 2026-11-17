//! The C API against the TypeScript reference (`vectors/vectors.json`, written by `vectors/make-vectors.mjs` with the
//! packages the client runs on), against midnight-zswap 9.0.1's own key derivation vectors
//! (`vectors/zswap-9.0.1-key-derivation-test-vectors.json`, the crate's `key-derivation-test-vectors.json`), and against
//! the scan kernel's fixtures (`../../test/fixtures`, used by `test/kernel.test.ts`).

use super::*;
use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha20Rng;
use serde_json::Value;
use std::ptr::{null, null_mut};

const ENTRY: usize = pss_kernel::ENTRY_BYTES;

fn path(relative: &str) -> String {
    format!("{}/{relative}", env!("CARGO_MANIFEST_DIR"))
}

fn json(relative: &str) -> Value {
    serde_json::from_slice(&std::fs::read(path(relative)).unwrap()).unwrap()
}

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(path(&format!("../../test/fixtures/{name}"))).unwrap()
}

fn unhex<const N: usize>(v: &Value) -> [u8; N] {
    hex::decode(v.as_str().unwrap()).unwrap().try_into().unwrap()
}

fn keys_of_mnemonic(phrase: &str) -> (i32, PssKeys) {
    let mut out = PssKeys { scan_secret: [7; 32], ..Default::default() };
    let status = unsafe { pss_keys_from_mnemonic(phrase.as_ptr(), phrase.len() as u32, &mut out) };
    (status, out)
}

fn keys_of_seed(seed: &[u8; 32]) -> PssKeys {
    let mut out = PssKeys::default();
    assert_eq!(unsafe { pss_keys_from_zswap_seed(seed.as_ptr(), &mut out) }, OK);
    out
}

fn expected_keys(k: &Value) -> PssKeys {
    PssKeys {
        coin_public_key: unhex(&k["coinPublicKey"]),
        encryption_public_key: unhex(&k["encryptionPublicKey"]),
        scan_secret: unhex(&k["scanSecret"]),
        coin_secret_key: unhex(&k["coinSecretKey"]),
    }
}

fn coin_bytes(c: &Value) -> [u8; COIN_BYTES] {
    let mut coin = [0u8; COIN_BYTES];
    coin[..16].copy_from_slice(&c["value"].as_str().unwrap().parse::<u128>().unwrap().to_le_bytes());
    coin[16..48].copy_from_slice(&unhex::<32>(&c["tokenType"]));
    coin[48..80].copy_from_slice(&unhex::<32>(&c["nonce"]));
    coin
}

// ---- The TypeScript reference ----

#[test]
fn keys_equal_the_typescript_client() {
    let v = json("vectors/vectors.json");
    let keys = v["keys"].as_array().unwrap();
    assert_eq!(keys.len(), 5);
    let mut mnemonics = 0;
    for k in keys {
        let expected = expected_keys(k);
        let seed: [u8; 32] = unhex(&k["zswapSeed"]);
        if let Some(phrase) = k["mnemonic"].as_str() {
            mnemonics += 1;
            assert_eq!(phrase.split(' ').count(), 24);
            assert_eq!(*zswap_seed_from_mnemonic(phrase).unwrap(), seed, "Zswap seed of {phrase}");
            assert_eq!(keys_of_mnemonic(phrase), (OK, expected.clone()));
        }
        assert_eq!(keys_of_seed(&seed), expected);
        // The scan secret gives the package's encryption public key, as the client checks (client/keys.ts).
        let mut public = [0u8; 32];
        assert_eq!(unsafe { pss_public_key(expected.scan_secret.as_ptr(), public.as_mut_ptr()) }, OK);
        assert_eq!(public, expected.encryption_public_key);
    }
    assert_eq!(mnemonics, 3);
}

#[test]
fn nullifiers_commitments_and_leaves_equal_the_ledger_package() {
    let v = json("vectors/vectors.json");
    let keys: Vec<PssKeys> = v["keys"].as_array().unwrap().iter().map(expected_keys).collect();
    let coins = v["coins"].as_array().unwrap();
    assert_eq!(coins.len(), 15);
    for c in coins {
        let k = &keys[c["key"].as_u64().unwrap() as usize];
        let coin = coin_bytes(c);
        let mut out = [0u8; 32];
        assert_eq!(unsafe { pss_nullifier(coin.as_ptr(), k.coin_secret_key.as_ptr(), out.as_mut_ptr()) }, OK);
        assert_eq!(out, unhex::<32>(&c["nullifier"]), "nullifier");
        assert_eq!(unsafe { pss_commitment(coin.as_ptr(), k.coin_public_key.as_ptr(), out.as_mut_ptr()) }, OK);
        assert_eq!(out, unhex::<32>(&c["commitment"]), "commitment");
        let commitment = out;
        assert_eq!(unsafe { pss_leaf(commitment.as_ptr(), out.as_mut_ptr()) }, OK);
        assert_eq!(out, unhex::<32>(&c["leaf"]), "leaf");
    }
}

#[test]
fn hash2_equals_the_ledger_package_transient_hash() {
    let v = json("vectors/vectors.json");
    let hashes = v["hash2"].as_array().unwrap();
    assert_eq!(hashes.len(), 8);
    for h in hashes {
        let (a, b): ([u8; 32], [u8; 32]) = (unhex(&h["a"]), unhex(&h["b"]));
        let mut out = [0u8; 32];
        assert_eq!(unsafe { pss_hash2(a.as_ptr(), b.as_ptr(), out.as_mut_ptr()) }, OK);
        assert_eq!(out, unhex::<32>(&h["out"]));
    }
}

// ---- midnight-zswap 9.0.1's own vectors ----

#[test]
fn keys_equal_midnight_zswap_vectors() {
    let v = json("vectors/zswap-9.0.1-key-derivation-test-vectors.json");
    let entries = v.as_array().unwrap();
    assert_eq!(entries.len(), 19);
    for e in entries {
        let seed: [u8; 32] = unhex(&e["seed"]);
        let keys = keys_of_seed(&seed);
        assert_eq!(keys.scan_secret, unhex::<32>(&e["encryption"]["secretKeyRepr"]));
        assert_eq!(keys.coin_secret_key, unhex::<32>(&e["coin"]["secretKey"]));
        assert_eq!(keys.coin_public_key, unhex::<32>(&e["coin"]["publicKey"]));
        assert_eq!(sample_bytes(&seed, 64, b"midnight:esk")[..], unhex::<64>(&e["encryption"]["secretKeyIntermediateBytes"]));
    }
}

#[test]
fn coin_public_key_equals_the_ledger_function() {
    let mut rng = ChaCha20Rng::seed_from_u64(5);
    for _ in 0..200 {
        let secret = coin::SecretKey(HashOutput(rng.r#gen()));
        assert_eq!(coin_public_key_of(&secret), secret.public_key().0.0);
    }
}

// ---- Mnemonic input ----

#[test]
fn mnemonic_whitespace_is_normalized_as_the_client_does() {
    let v = json("vectors/vectors.json");
    let k = &v["keys"][0];
    let phrase = k["mnemonic"].as_str().unwrap();
    let expected = expected_keys(k);
    let spaced = format!("  \n{}\t ", phrase.split(' ').collect::<Vec<_>>().join(" \t\n  "));
    assert_eq!(keys_of_mnemonic(&spaced), (OK, expected));
}

#[test]
fn invalid_mnemonics_are_rejected_and_leave_zero_keys() {
    let v = json("vectors/vectors.json");
    let phrase = v["keys"][0]["mnemonic"].as_str().unwrap();
    let words: Vec<&str> = phrase.split(' ').collect();
    let zero = PssKeys::default();
    // Checksum: the last word replaced by another valid word that breaks it.
    let wrong_checksum = (0..2048)
        .map(|i| bip39::Language::English.word_list()[i])
        .map(|w| format!("{} {w}", words[..23].join(" ")))
        .find(|p| bip39::Mnemonic::parse_in(Language::English, p.as_str()).is_err())
        .unwrap();
    let cases = [
        wrong_checksum,
        format!("{} notaword", words[..23].join(" ")),
        words[..23].join(" "),
        format!("{phrase} {}", words[0]),
        phrase.to_uppercase(),
        String::new(),
        "   ".to_string(),
    ];
    for case in &cases {
        assert_eq!(keys_of_mnemonic(case), (REJECTED, zero.clone()), "{case:?}");
    }
    // Not UTF-8.
    let mut out = PssKeys { coin_secret_key: [9; 32], ..Default::default() };
    let bytes = [0xffu8, 0xfe, 0x20, 0x61];
    assert_eq!(unsafe { pss_keys_from_mnemonic(bytes.as_ptr(), 4, &mut out) }, REJECTED);
    assert_eq!(out, zero);
    // A 12-word mnemonic is valid BIP-39, as `@scure/bip39` accepts it.
    let twelve = bip39::Mnemonic::from_entropy(&[3u8; 16]).unwrap().to_string();
    assert_eq!(keys_of_mnemonic(&twelve).0, OK);
}

// ---- The kernel's fixtures ----

#[test]
fn scan_finds_exactly_the_fixture_entries_for_the_test_key() {
    let entries = fixture("entries.bin");
    let mine = fixture("mine.bin");
    let scalar = fixture("scalar.bin");
    let count = entries.len() / ENTRY;
    assert_eq!(count, 16_384);
    let expected: Vec<u32> = mine.iter().enumerate().filter(|(_, m)| **m == 1).map(|(i, _)| i as u32).collect();
    assert!(!expected.is_empty());
    let mut out = vec![0u32; count];
    let hits = unsafe { pss_scan(entries.as_ptr(), count as u32, scalar.as_ptr(), out.as_mut_ptr()) };
    assert_eq!(&out[..hits as usize], &expected[..]);
    // Slices give positions relative to themselves.
    let (start, len) = (1000usize, 777usize);
    let slice = &entries[start * ENTRY..(start + len) * ENTRY];
    let hits = unsafe { pss_scan(slice.as_ptr(), len as u32, scalar.as_ptr(), out.as_mut_ptr()) };
    let relative: Vec<u32> = expected.iter().filter(|i| (start..start + len).contains(&(**i as usize))).map(|i| i - start as u32).collect();
    assert_eq!(&out[..hits as usize], &relative[..]);
}

#[test]
fn scan_values_equal_the_fixture_pads() {
    let entries = fixture("entries.bin");
    let pads = fixture("pads.bin");
    let scalar = fixture("scalar.bin");
    let count = entries.len() / ENTRY;
    let mut out = vec![0u8; count * 32];
    assert_eq!(unsafe { pss_scan_values(entries.as_ptr(), count as u32, scalar.as_ptr(), out.as_mut_ptr()) }, count as i32);
    assert!(out == pads);
}

#[test]
fn pads_equal_the_fixture_pad_zero_for_every_entry() {
    let entries = fixture("entries.bin");
    let pads = fixture("pads.bin");
    let scalar = fixture("scalar.bin");
    let mut six = [0u8; 192];
    for (i, entry) in entries.as_chunks::<ENTRY>().0.iter().enumerate() {
        assert_eq!(unsafe { pss_pads(entry.as_ptr(), scalar.as_ptr(), six.as_mut_ptr()) }, OK, "entry {i}");
        assert_eq!(&six[..32], &pads[32 * i..32 * i + 32], "entry {i}");
    }
}

#[test]
fn worked_samples_key_and_pads() {
    let scalar = fixture("scalar.bin");
    let text = std::fs::read_to_string(path("../../test/fixtures/sample.txt")).unwrap();
    // Blocks of `name hex` lines, each starting with `entry`.
    let mut blocks: Vec<std::collections::HashMap<String, Vec<u8>>> = Vec::new();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let (name, value) = line.split_once(' ').unwrap();
        if name == "entry" {
            blocks.push(Default::default());
        }
        blocks.last_mut().unwrap().insert(name.to_string(), hex::decode(value.trim()).unwrap());
    }
    let mut samples = 0;
    for block in &blocks {
        let field = |name: &str| block[name].clone();
        let entry = field("entry");
        let (sx, sy, key, pad) = (field("sx"), field("sy"), field("key"), field("pad"));
        let mut out = [0u8; 32];
        assert_eq!(unsafe { pss_hash2(sx.as_ptr(), sy.as_ptr(), out.as_mut_ptr()) }, OK);
        assert_eq!(out.to_vec(), key);
        let zero = [0u8; 32];
        assert_eq!(unsafe { pss_hash2(key.as_ptr(), zero.as_ptr(), out.as_mut_ptr()) }, OK);
        assert_eq!(out.to_vec(), pad);
        let mut six = [0u8; 192];
        assert_eq!(unsafe { pss_pads(entry.as_ptr(), scalar.as_ptr(), six.as_mut_ptr()) }, OK);
        for i in 0..6u8 {
            let mut index = [0u8; 32];
            index[0] = i;
            assert_eq!(unsafe { pss_hash2(key.as_ptr(), index.as_ptr(), out.as_mut_ptr()) }, OK);
            assert_eq!(&six[32 * i as usize..32 * i as usize + 32], &out);
        }
        samples += 1;
    }
    assert_eq!(samples, 4);
}

const RECORD: usize = CIPHERTEXT_BYTES + 1 + COIN_BYTES + 32;

#[test]
fn decrypt_coin_and_commitment_equal_the_fixture_coins() {
    let records = fixture("coins.bin");
    let secret = fixture("coin-secret.bin");
    let cpk = fixture("coin-public-key.bin");
    assert_eq!(records.len() / RECORD, 48);
    let (mut mine, mut others) = (0, 0);
    for r in records.as_chunks::<RECORD>().0 {
        let ciphertext = &r[..CIPHERTEXT_BYTES];
        let coin = &r[CIPHERTEXT_BYTES + 1..CIPHERTEXT_BYTES + 1 + COIN_BYTES];
        let commitment = &r[CIPHERTEXT_BYTES + 1 + COIN_BYTES..];
        let mut out = [0xaau8; COIN_BYTES];
        let status = unsafe { pss_decrypt_coin(ciphertext.as_ptr(), secret.as_ptr(), out.as_mut_ptr()) };
        if r[CIPHERTEXT_BYTES] == 1 {
            mine += 1;
            assert_eq!(status, OK);
            assert_eq!(&out[..], coin);
            // Changing element 0 makes it fail.
            let mut bad = ciphertext.to_vec();
            bad[32] ^= 1;
            assert_eq!(unsafe { pss_decrypt_coin(bad.as_ptr(), secret.as_ptr(), out.as_mut_ptr()) }, REJECTED);
            assert_eq!(out, [0u8; COIN_BYTES]);
        } else {
            others += 1;
            assert_eq!(status, REJECTED);
            assert_eq!(out, [0u8; COIN_BYTES]);
        }
        let mut com = [0u8; 32];
        assert_eq!(unsafe { pss_commitment(coin.as_ptr(), cpk.as_ptr(), com.as_mut_ptr()) }, OK);
        assert_eq!(&com[..], commitment);
    }
    assert!(mine > 0 && others > 0);
}

// ---- Rejections and arguments ----

#[test]
fn invalid_secrets_inputs_and_pointers() {
    let entries = fixture("entries.bin");
    let records = fixture("coins.bin");
    let bad = [0xffu8; 32];
    let mut out = [0u8; 192];
    let mut indices = [0u32; 4];
    let p = entries.as_ptr();
    unsafe {
        assert_eq!(pss_scan(p, 4, bad.as_ptr(), indices.as_mut_ptr()), BAD_SECRET);
        assert_eq!(pss_scan_values(p, 4, bad.as_ptr(), out.as_mut_ptr()), BAD_SECRET);
        assert_eq!(pss_pads(p, bad.as_ptr(), out.as_mut_ptr()), BAD_SECRET);
        assert_eq!(pss_decrypt_coin(records.as_ptr(), bad.as_ptr(), out.as_mut_ptr()), BAD_SECRET);
        assert_eq!(pss_public_key(bad.as_ptr(), out.as_mut_ptr()), BAD_SECRET);
        // Non-canonical field elements.
        let zero = [0u8; 32];
        assert_eq!(pss_hash2(bad.as_ptr(), zero.as_ptr(), out.as_mut_ptr()), REJECTED);
        assert_eq!(pss_hash2(zero.as_ptr(), bad.as_ptr(), out.as_mut_ptr()), REJECTED);
        // An all-zero entry never matches and has value zero; zero bytes are no point the ledger accepts.
        let scalar = fixture("scalar.bin");
        let empty_entry = [0u8; ENTRY];
        out.fill(1);
        assert_eq!(pss_scan(empty_entry.as_ptr(), 1, scalar.as_ptr(), indices.as_mut_ptr()), 0);
        assert_eq!(pss_scan_values(empty_entry.as_ptr(), 1, scalar.as_ptr(), out.as_mut_ptr()), 1);
        assert_eq!(out[..32], [0u8; 32]);
        assert_eq!(pss_pads(empty_entry.as_ptr(), scalar.as_ptr(), out.as_mut_ptr()), REJECTED);
        // A count of zero needs no buffers; the secret is still checked.
        assert_eq!(pss_scan(null(), 0, scalar.as_ptr(), null_mut()), 0);
        assert_eq!(pss_scan(null(), 0, bad.as_ptr(), null_mut()), BAD_SECRET);
        assert_eq!(pss_scan_values(null(), 0, scalar.as_ptr(), null_mut()), 0);
        // Null pointers and counts beyond an i32.
        assert_eq!(pss_scan(null(), 1, scalar.as_ptr(), indices.as_mut_ptr()), BAD_ARGUMENT);
        assert_eq!(pss_scan(p, 1, null(), indices.as_mut_ptr()), BAD_ARGUMENT);
        assert_eq!(pss_scan(p, 1, scalar.as_ptr(), null_mut()), BAD_ARGUMENT);
        assert_eq!(pss_scan(p, u32::MAX, scalar.as_ptr(), indices.as_mut_ptr()), BAD_ARGUMENT);
        assert_eq!(pss_scan_values(p, 1 << 31, scalar.as_ptr(), out.as_mut_ptr()), BAD_ARGUMENT);
        assert_eq!(pss_pads(null(), scalar.as_ptr(), out.as_mut_ptr()), BAD_ARGUMENT);
        assert_eq!(pss_decrypt_coin(records.as_ptr(), scalar.as_ptr(), null_mut()), BAD_ARGUMENT);
        assert_eq!(pss_commitment(null(), scalar.as_ptr(), out.as_mut_ptr()), BAD_ARGUMENT);
        assert_eq!(pss_nullifier(out.as_ptr(), null(), out.as_mut_ptr()), BAD_ARGUMENT);
        assert_eq!(pss_leaf(null(), out.as_mut_ptr()), BAD_ARGUMENT);
        assert_eq!(pss_hash2(zero.as_ptr(), zero.as_ptr(), null_mut()), BAD_ARGUMENT);
        assert_eq!(pss_public_key(null(), out.as_mut_ptr()), BAD_ARGUMENT);
        assert_eq!(pss_keys_from_zswap_seed(null(), &mut PssKeys::default()), BAD_ARGUMENT);
        assert_eq!(pss_keys_from_zswap_seed(zero.as_ptr(), null_mut()), BAD_ARGUMENT);
        assert_eq!(pss_keys_from_mnemonic(null(), 5, &mut PssKeys::default()), BAD_ARGUMENT);
        assert_eq!(pss_keys_from_mnemonic(null(), 0, &mut PssKeys::default()), REJECTED);
        assert_eq!(pss_keys_from_mnemonic(zero.as_ptr(), 32, null_mut()), BAD_ARGUMENT);
    }
}

#[test]
fn keys_struct_layout_is_the_header_layout() {
    assert_eq!(std::mem::size_of::<PssKeys>(), 128);
    assert_eq!(std::mem::align_of::<PssKeys>(), 1);
    assert_eq!(std::mem::offset_of!(PssKeys, coin_public_key), 0);
    assert_eq!(std::mem::offset_of!(PssKeys, encryption_public_key), 32);
    assert_eq!(std::mem::offset_of!(PssKeys, scan_secret), 64);
    assert_eq!(std::mem::offset_of!(PssKeys, coin_secret_key), 96);
}
