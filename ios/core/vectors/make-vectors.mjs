// Writes vectors.json: the TypeScript client's key derivation, nullifiers, commitments, leaves and Poseidon, computed
// with the packages the client runs on, for the native core's tests (`cargo test`, src/tests.rs).
//
//   node make-vectors.mjs <client node_modules>
//
// <client node_modules> is an install of examples/private-shielded-sync/client (`npm ci --ignore-scripts --prefix
// examples/private-shielded-sync/client`); by default the one beside this worktree's client. Every key is a fresh test
// key: three new 24-word mnemonics and two random 32-byte Zswap seeds. No real wallet enters this file.
//
// Each key is derived the client's way (client/sdk/seeds.ts, client/keys.ts, web/worker.ts deriveKeys): the BIP-39
// seed with an empty passphrase, the wallet SDK's `WalletSeeds.fromMasterSeed(…).shielded` (m/44'/2400'/0'/3/0), then
// `ZswapSecretKeys.fromSeed`. The scan secret is `encryptionSecretKeyScalar` of the encryption secret key's
// serialization (kernel/secret-key.ts, imported as is). The coin secret key is the 32 bytes that
// `CoinSecretKey.yesIKnowTheSecurityImplicationsOfThis_serialize()` writes after its tag
// `midnight:zswap-coin-secret-key[v1]:` (the package has no `CoinSecretKey.deserialize`, so `coinNullifier` is called
// with the key object, as the client calls it; the native tests feed the 32 bytes to `pss_nullifier`).

import { randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const nodeModules = resolve(process.argv[2] ?? join(here, "../../../client/node_modules"));
const load = (file) => import(pathToFileURL(join(nodeModules, file)).href);
const version = (pkg) => JSON.parse(readFileSync(join(nodeModules, pkg, "package.json"), "utf8")).version;

const ledger = await load("@midnightntwrk/ledger-v9/midnight_ledger_wasm_v9_fs.js");
const { generateMnemonic, mnemonicToSeedSync, validateMnemonic } = await load("@scure/bip39/index.js");
const { wordlist } = await load("@scure/bip39/wordlists/english.js");
const { HDWallet, Roles, WalletSeeds } = await load("@midnightntwrk/wallet-sdk-hd/dist/index.js");
const { encryptionSecretKeyScalar } = await import(pathToFileURL(join(here, "../../../kernel/secret-key.ts")).href);

const hex = (b) => Buffer.from(b).toString("hex");
const unhex = (h) => new Uint8Array(Buffer.from(h, "hex"));
const check = (ok, what) => {
  if (!ok) throw new Error(what);
};

/** The client's Zswap seed of a mnemonic (web/worker.ts deriveKeys, client/sdk/seeds.ts). */
function zswapSeedOf(mnemonic) {
  const words = mnemonic.trim().split(/\s+/).join(" ");
  check(validateMnemonic(words, wordlist), "generated mnemonic is not valid");
  const master = mnemonicToSeedSync(words);
  const seed = WalletSeeds.fromMasterSeed(master).shielded;
  // The same key through HDWallet directly: account 0, role Zswap (3), index 0.
  const opened = HDWallet.fromSeed(master);
  const direct = opened.hdWallet.selectAccount(0).selectRole(Roles.Zswap).deriveKeyAt(0);
  check(direct.type === "keyDerived" && hex(direct.key) === hex(seed), "WalletSeeds and HDWallet disagree");
  master.fill(0);
  return seed;
}

const COIN_SECRET_KEY_TAG = "midnight:zswap-coin-secret-key[v1]:";

/** The client's keys of a Zswap seed (client/keys.ts walletKeys). */
function keysOf(seed) {
  const zswap = ledger.ZswapSecretKeys.fromSeed(seed);
  const scanSecret = encryptionSecretKeyScalar(zswap.encryptionSecretKey.yesIKnowTheSecurityImplicationsOfThis_serialize());
  const serialized = zswap.coinSecretKey.yesIKnowTheSecurityImplicationsOfThis_serialize();
  const tag = new TextEncoder().encode(COIN_SECRET_KEY_TAG);
  check(serialized.length === tag.length + 32 && tag.every((b, i) => serialized[i] === b), "unexpected coin secret key serialization");
  const coinSecretKey = serialized.slice(tag.length);
  serialized.fill(0);
  return { zswap, scanSecret, coinSecretKey };
}

const BIG = (1n << 128n) - 1n;
const randomValue = () => BigInt(`0x${hex(randomBytes(16))}`);
const values = [0n, 1n, 1_000_000n, BIG, randomValue(), randomValue()];

const keys = [];
const coins = [];
const sources = [
  ...[0, 1, 2].map(() => ({ mnemonic: generateMnemonic(wordlist, 256) })),
  ...[0, 1].map(() => ({ seed: new Uint8Array(randomBytes(32)) })),
];
for (const [k, source] of sources.entries()) {
  const seed = source.mnemonic === undefined ? source.seed : zswapSeedOf(source.mnemonic);
  if (source.mnemonic !== undefined) check(source.mnemonic.split(" ").length === 24, "not 24 words");
  const { zswap, scanSecret, coinSecretKey } = keysOf(seed);
  keys.push({
    mnemonic: source.mnemonic ?? null,
    zswapSeed: hex(seed),
    coinPublicKey: zswap.coinPublicKey,
    encryptionPublicKey: zswap.encryptionPublicKey,
    scanSecret: hex(scanSecret),
    coinSecretKey: hex(coinSecretKey),
  });
  // Three coins per key, cycling through the edge values and random ones.
  for (let i = 0; i < 3; i++) {
    const value = values[(3 * k + i) % values.length];
    const info = { type: hex(randomBytes(32)), nonce: hex(randomBytes(32)), value };
    const nullifier = ledger.coinNullifier(info, zswap.coinSecretKey);
    const commitment = ledger.coinCommitment(info, zswap.coinPublicKey);
    const [leaf] = ledger.degradeToTransient([unhex(commitment)]);
    const paddedLeaf = new Uint8Array(32);
    paddedLeaf.set(leaf);
    coins.push({ key: k, tokenType: info.type, nonce: info.nonce, value: value.toString(), commitment, leaf: hex(paddedLeaf), nullifier });
  }
  zswap.clear();
}

// Poseidon of two field elements, the ledger's `transientHash` over two field atoms (values trimmed of trailing zero
// bytes, as the ledger encodes field atoms), against the kernel's `hash2`.
const FIELD_ORDER = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001n;
const toLe = (v) => {
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++, v >>= 8n) out[i] = Number(v & 0xffn);
  return out;
};
const trim = (b) => {
  let n = b.length;
  while (n > 0 && b[n - 1] === 0) n--;
  return b.slice(0, n);
};
const fieldAtom = { tag: "atom", value: { tag: "field" } };
const hash2 = [];
const operands = [
  [0n, 0n],
  [1n, 2n],
  [FIELD_ORDER - 1n, 0n],
  ...[0, 1, 2, 3, 4].map(() => [BigInt(`0x${hex(randomBytes(32))}`) % FIELD_ORDER, BigInt(`0x${hex(randomBytes(32))}`) % FIELD_ORDER]),
];
for (const [a, b] of operands) {
  const [out] = ledger.transientHash([fieldAtom, fieldAtom], [trim(toLe(a)), trim(toLe(b))]);
  const padded = new Uint8Array(32);
  padded.set(out);
  hash2.push({ a: hex(toLe(a)), b: hex(toLe(b)), out: hex(padded) });
}

const vectors = {
  description:
    "Test vectors of the private shielded sync client's key derivation (BIP-39 seed, empty passphrase; BIP-32 m/44'/2400'/0'/3/0; ZswapSecretKeys.fromSeed), coinNullifier, coinCommitment, degradeToTransient and transientHash of two fields, from the TypeScript packages below. coinSecretKey is the 32 bytes after the tag 'midnight:zswap-coin-secret-key[v1]:' of CoinSecretKey's serialization; scanSecret is kernel/secret-key.ts encryptionSecretKeyScalar of EncryptionSecretKey's serialization. Test keys only: fresh mnemonics and random seeds. Bytes are hex; field elements little-endian; values decimal.",
  generator: "ios/core/vectors/make-vectors.mjs",
  packages: Object.fromEntries(
    ["@midnightntwrk/ledger-v9", "@midnightntwrk/wallet-sdk-hd", "@scure/bip39", "@scure/bip32"].map((p) => [p, version(p)]),
  ),
  path: "m/44'/2400'/0'/3/0",
  keys,
  coins,
  hash2,
};
const out = join(here, "vectors.json");
writeFileSync(out, `${JSON.stringify(vectors, null, 2)}\n`);
console.log(`wrote ${keys.length} keys, ${coins.length} coins, ${hash2.length} hashes to ${out}`);
