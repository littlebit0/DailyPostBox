import assert from "node:assert/strict";
import test from "node:test";
import {
  latestUidSearchQuery,
  newestFirstSequenceRanges,
  newestFirstUidBatches
} from "../src/mail/imapSequenceRanges.js";

test("loads a small newest batch before older messages", () => {
  assert.deepEqual(newestFirstSequenceRanges(4_026, "all").slice(0, 2), [
    { start: 4_002, end: 4_026 },
    { start: 3_752, end: 4_001 }
  ]);
});

test("limits finite imports and covers every requested message once", () => {
  const ranges = newestFirstSequenceRanges(1_000, 500);
  const imported = ranges.reduce(
    (count, range) => count + range.end - range.start + 1,
    0
  );

  assert.equal(imported, 500);
  assert.deepEqual(ranges.at(0), { start: 976, end: 1_000 });
  assert.deepEqual(ranges.at(-1), { start: 501, end: 725 });
});

test("handles empty and smaller mailboxes", () => {
  assert.deepEqual(newestFirstSequenceRanges(0, "all"), []);
  assert.deepEqual(newestFirstSequenceRanges(10, 100), [
    { start: 1, end: 10 }
  ]);
});

test("batches stable UIDs newest first without gaps or duplicates", () => {
  // Sparse UIDs, as left behind by expunged messages, arrive unsorted.
  const uids = [40, 2, 7, 31, 15, 3];
  assert.deepEqual(newestFirstUidBatches(uids, 5, 2, 2), [
    [31, 40],
    [7, 15],
    [3]
  ]);
  assert.deepEqual(newestFirstUidBatches([], "all"), []);
});

test("searches only the newest sequence range for finite fetches", () => {
  assert.deepEqual(latestUidSearchQuery(50_000, 1), { seq: "50000:*" });
  assert.deepEqual(latestUidSearchQuery(50_000, 25), { seq: "49976:*" });
  assert.deepEqual(latestUidSearchQuery(10, 100), { seq: "1:*" });
  assert.deepEqual(latestUidSearchQuery(10, "all"), { all: true });
  assert.equal(latestUidSearchQuery(0, "all"), null);
  assert.equal(latestUidSearchQuery(10, 0), null);
});
