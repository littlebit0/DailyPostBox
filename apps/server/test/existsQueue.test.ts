import assert from "node:assert/strict";
import test from "node:test";
import { createExistsQueue } from "../src/mail/existsQueue.js";

test("fetches every message of a multi-message EXISTS jump", async () => {
  const requested: number[] = [];
  const saved: string[] = [];
  const handle = createExistsQueue({
    fetchNewest: async (count) => {
      requested.push(count);
      return ["a", "b", "c"].slice(-count);
    },
    onMessage: async (message) => {
      saved.push(message);
    },
    onError: () => assert.fail("unexpected error"),
    isStopped: () => false
  });

  await handle({ count: 13, prevCount: 10 });

  assert.deepEqual(requested, [3]);
  assert.deepEqual(saved, ["a", "b", "c"]);
});

test("queues EXISTS notifications that arrive during a fetch", async () => {
  const requested: number[] = [];
  let release!: () => void;
  const firstFetch = new Promise<void>((resolve) => {
    release = resolve;
  });
  const handle = createExistsQueue({
    fetchNewest: async (count) => {
      requested.push(count);
      if (requested.length === 1) await firstFetch;
      return [];
    },
    onMessage: async () => undefined,
    onError: () => assert.fail("unexpected error"),
    isStopped: () => false
  });

  const first = handle({ count: 1, prevCount: 0 });
  const second = handle({ count: 2, prevCount: 1 });
  const third = handle({ count: 4, prevCount: 2 });
  release();
  await Promise.all([first, second, third]);

  // The two queued notifications are fetched together once the first ends.
  assert.deepEqual(requested, [1, 3]);
});

test("reports fetch errors and stops after the watcher is stopped", async () => {
  let stopped = false;
  const errors: unknown[] = [];
  let fetches = 0;
  const handle = createExistsQueue({
    fetchNewest: async () => {
      fetches += 1;
      throw new Error("socket closed");
    },
    onMessage: async () => undefined,
    onError: (error) => errors.push(error),
    isStopped: () => stopped
  });

  await handle({ count: 1, prevCount: 0 });
  assert.equal(errors.length, 1);

  stopped = true;
  await handle({ count: 2, prevCount: 1 });
  assert.equal(fetches, 1);
});
