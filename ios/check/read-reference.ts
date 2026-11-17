// The TypeScript client's PIR reads, for the Swift check to compare with: node read-reference.ts <server> <out.json>
// Reads the read-table records of a few positions, the path records of a few positions, and whole nullifier buckets.
import { writeFileSync } from "node:fs";
import { PssHttp } from "../../client/http.ts";
import { readPaths, readPositions } from "../../client/pir-calls.ts";
import { buildQueries, columnRecords, decodeAnswers, inlineMultiplier, setupMatrix } from "../../pir/index.ts";
import { decodeAnswerBody, decodeManifest, encodeQueryBody, fromHex } from "../../shared/index.ts";
import { createHash } from "node:crypto";

const [server = "http://127.0.0.1:10480", out = "reference.json"] = process.argv.slice(2);
const http = new PssHttp(server);
const served = await http.manifest();
const m = decodeManifest(served.bytes);
const id = new Uint8Array(createHash("sha256").update(served.bytes).digest());
const blob = async (digest: string) => new Uint8Array(await (await fetch(`${server}/pss/v1/blob/${digest}`)).arrayBuffer());
const a = m.artifacts;
const positions = [0, 1, 100, 21589, 22501, 69250, m.firstFree - 1].filter((p) => p < m.firstFree);
const readSetup = setupMatrix(await blob(a.readSetup.digest), a.readTable.rows);
const read = await readPositions(http, m, id, readSetup, positions, inlineMultiplier);
let paths: Record<string, string> = {};
if (a.pathTable && a.pathSetup) {
  const pathSetup = setupMatrix(await blob(a.pathSetup.digest), a.pathTable.rows);
  const full = Math.floor(m.firstFree / 2 ** m.pathSplit) * 2 ** m.pathSplit;
  const pp = [0, 21589, 22506].filter((p) => p < full);
  const got = await readPaths(http, m, id, pathSetup, pp, inlineMultiplier);
  paths = Object.fromEntries([...got].map(([p, r]) => [String(p), Buffer.from(r).toString("hex")]));
}
const nt = a.nullifierTable;
const buckets = [0, 5, nt.cols - 1];
const nSetup = setupMatrix(await blob(a.nullifierSetup.digest), nt.rows);
const batch = await buildQueries({ ...nt, seed: fromHex(nt.seed, 32) }, [...buckets, ...Array.from({ length: m.queriesPerCall - buckets.length }, () => 7)], inlineMultiplier);
const answer = await http.query("nullifier", encodeQueryBody({ snapshotId: id, count: batch.columns.length, values: batch.queries }, nt.cols));
const values = await decodeAnswers(nSetup, batch, decodeAnswerBody(answer, nt.rows).values, inlineMultiplier);
const nullifierBuckets = Object.fromEntries(buckets.map((b, i) => [String(b), columnRecords(nt, values[i]!).map((r) => Buffer.from(r).toString("hex"))]));
writeFileSync(out, JSON.stringify({
  snapshotId: Buffer.from(id).toString("hex"),
  read: Object.fromEntries([...read].map(([p, r]) => [String(p), Buffer.from(r).toString("hex")])),
  paths,
  nullifierBuckets,
}, null, 1));
console.log(`wrote ${out}: ${read.size} read records, ${Object.keys(paths).length} paths, ${buckets.length} buckets`);
