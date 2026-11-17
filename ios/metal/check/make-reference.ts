/**
 * The CPU side of the Metal check: builds the scan inputs of gpu/check.ts with gpu/inputs.ts (the 16,384 test
 * vectors, and the 70,000-entry Preprod-sized set with every edge case), runs the CPU kernel on them (`ScanPool`, the
 * WASM kernel across worker threads, as gpu/cpu-reference.ts does), and writes the inputs, the expected outputs and the
 * CPU timings to a folder that the Swift check (`swift run -c release pss-metal-check --ref DIR`) reads.
 *
 *     node make-reference.ts [--out DIR] [--threads N] [--cpu-million]
 *
 * `--out`: the folder (default: a new temporary one, printed). `--threads`: CPU worker threads (default 8, as
 * gpu/README.md's numbers). `--cpu-million`: also time `ScanPool.scanValues` once over 1,000,000 entries (the 70,000
 * set repeated), about 70 s with 8 threads.
 *
 * Files: `<set>.entries.bin` (36-byte entries), `<set>.secret.bin` (32 bytes), `<set>.values.bin` (32 bytes per entry,
 * `ScanPool.scanValues`), `<set>.hits.json` (`ScanPool.scan`), `pads.bin` and `mine.bin` (the ledger's values and hits
 * of the vectors, test/fixtures), `manifest.json` (sets, composition, CPU timings).
 */

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { availableParallelism, loadavg, tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { type Fixtures, preprodSet, type ScanSet, vectorSet } from "../../../gpu/inputs.ts";
import { compileKernel, Kernel } from "../../../kernel/kernel.ts";
import { ScanPool } from "../../../kernel/scan-pool.ts";

const ENTRY_BYTES = 36;
const here = (p: string): string => fileURLToPath(new URL(p, import.meta.url));
const args = process.argv.slice(2);
const option = (name: string): string | undefined => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const threads = Math.min(Number(option("--threads") ?? 8), availableParallelism());
const out = option("--out") ?? mkdtempSync(join(tmpdir(), "pss-metal-ref-"));
mkdirSync(out, { recursive: true });

const fixture = (name: string): Uint8Array => new Uint8Array(readFileSync(here(`../../../test/fixtures/${name}`)));
const fixtures: Fixtures = {
  entries: fixture("entries.bin"),
  pads: fixture("pads.bin"),
  mine: fixture("mine.bin"),
  scalar: fixture("scalar.bin"),
};
const module = compileKernel();
const kernel = new Kernel(module);
const pool = new ScanPool({ threads, module });
const loadBefore = loadavg();

let t = performance.now();
const sets: ScanSet[] = [vectorSet(fixtures), preprodSet(fixtures, kernel, 70_000)];
console.log(`sets built in ${((performance.now() - t) / 1000).toFixed(1)} s; CPU threads ${threads}; folder ${out}`);

const write = (name: string, bytes: Uint8Array): string => {
  writeFileSync(join(out, name), bytes);
  return name;
};

interface SetEntry {
  name: string;
  count: number;
  entries: string;
  secret: string;
  values: string;
  hits: string;
  composition: Record<string, number>;
  cpu: { threads: number; poolValuesMs: number[]; poolScanMs: number[]; singleThreadSample: number; singleThreadMs: number };
}
const manifest: {
  node: string;
  cpus: number;
  threads: number;
  loadBefore: number[];
  loadAfter?: number[];
  sets: SetEntry[];
  pads: string;
  mine: string;
  million?: { entries: number; threads: number; poolValuesMs: number };
} = { node: process.version, cpus: availableParallelism(), threads, loadBefore, sets: [], pads: write("pads.bin", fixtures.pads), mine: write("mine.bin", fixtures.mine) };

// Warm-up: every worker compiles its instance on its first task.
await pool.scanValues(sets[0]!.entries.subarray(0, threads * 16 * ENTRY_BYTES), sets[0]!.secret);
for (const s of sets) {
  const count = s.entries.length / ENTRY_BYTES;
  const poolValuesMs: number[] = [];
  const poolScanMs: number[] = [];
  let values: Uint8Array = new Uint8Array(0);
  let hits: number[] = [];
  for (let r = 0; r < 3; r++) {
    t = performance.now();
    values = await pool.scanValues(s.entries, s.secret);
    poolValuesMs.push(performance.now() - t);
    t = performance.now();
    hits = await pool.scan(s.entries, s.secret);
    poolScanMs.push(performance.now() - t);
  }
  const sample = Math.min(count, 512);
  kernel.scanValues(s.entries.subarray(0, 16 * ENTRY_BYTES), s.secret);
  t = performance.now();
  kernel.scanValues(s.entries.subarray(0, sample * ENTRY_BYTES), s.secret);
  const singleThreadMs = performance.now() - t;
  manifest.sets.push({
    name: s.name,
    count,
    entries: write(`${s.name}.entries.bin`, s.entries),
    secret: write(`${s.name}.secret.bin`, s.secret),
    values: write(`${s.name}.values.bin`, values),
    hits: (writeFileSync(join(out, `${s.name}.hits.json`), JSON.stringify(hits)), `${s.name}.hits.json`),
    composition: s.composition,
    cpu: { threads, poolValuesMs, poolScanMs, singleThreadSample: sample, singleThreadMs },
  });
  console.log(
    `  cpu ${s.name} (${count}): scanValues best ${Math.min(...poolValuesMs).toFixed(0)} ms, scan best ${Math.min(...poolScanMs).toFixed(0)} ms, ` +
      `one thread ${((singleThreadMs * 1000) / sample).toFixed(0)} µs/entry, ${hits.length} hits`,
  );
}

if (args.includes("--cpu-million")) {
  const base = sets[1]!;
  const n = 1_000_000;
  const entries = new Uint8Array(n * ENTRY_BYTES);
  for (let off = 0; off < entries.length; off += base.entries.length) entries.set(base.entries.subarray(0, Math.min(base.entries.length, entries.length - off)), off);
  t = performance.now();
  await pool.scanValues(entries, base.secret);
  const poolValuesMs = performance.now() - t;
  manifest.million = { entries: n, threads, poolValuesMs };
  console.log(`  cpu 1,000,000: scanValues ${(poolValuesMs / 1000).toFixed(1)} s (${((poolValuesMs * 1000) / n).toFixed(1)} µs/entry)`);
}

await pool.close();
manifest.loadAfter = loadavg();
writeFileSync(join(out, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`reference written: ${out}`);
