import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { SnoozeStore, type SnoozeClock, type SnoozeEntry } from "../src/workers/SnoozeStore.js";

class FakeClock implements SnoozeClock {
  time = Date.parse("2026-01-01T00:00:00Z");
  private timers = new Map<number, { at: number; callback: () => void }>();
  private next = 1;
  now() { return this.time; }
  setTimer(callback: () => void, ms: number) {
    const id = this.next++;
    this.timers.set(id, { at: this.time + ms, callback });
    return id;
  }
  clearTimer(handle: unknown) { this.timers.delete(handle as number); }
  async advance(ms: number) {
    this.time += ms;
    for (const [id, timer] of [...this.timers]) {
      if (timer.at <= this.time) {
        this.timers.delete(id);
        timer.callback();
      }
    }
    // wake persists to disk before notifying
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

const hour = 3_600_000;

test("hides until wakeAt, then wakes once and sorts to top", async () => {
  const clock = new FakeClock();
  const woken: SnoozeEntry[] = [];
  const store = new SnoozeStore(undefined, (entry) => void woken.push(entry), clock);
  await store.snooze("a", "m1", new Date(clock.time + hour));

  assert.equal(store.isHidden("a", "m1"), true);
  assert.equal(store.isHidden("a", "other"), false);
  await clock.advance(hour - 1);
  assert.equal(woken.length, 0);

  await clock.advance(1);
  assert.equal(woken.length, 1);
  assert.equal(store.isHidden("a", "m1"), false);
  const received = new Date(clock.time - 10 * hour);
  assert.equal(store.sortTime("a", "m1", received), clock.time);
  assert.equal(store.sortTime("a", "other", received), received.getTime());
});

test("cancel and removeAccount stop the wake", async () => {
  const clock = new FakeClock();
  const woken: SnoozeEntry[] = [];
  const store = new SnoozeStore(undefined, (entry) => void woken.push(entry), clock);
  await store.snooze("a", "m1", new Date(clock.time + hour));
  await store.snooze("b", "m2", new Date(clock.time + hour));
  assert.equal(await store.cancel("a", "m1"), true);
  await store.removeAccount("b");
  await clock.advance(2 * hour);
  assert.equal(woken.length, 0);
  assert.equal(store.list().length, 0);
});

test("survives restart and wakes overdue entries immediately", async () => {
  const dir = await mkdtemp(join(tmpdir(), "snooze-"));
  const file = join(dir, "snoozes.json");
  const clock = new FakeClock();
  const first = new SnoozeStore(file, () => undefined, clock);
  await first.snooze("a", "m1", new Date(clock.time + hour));
  await first.snooze("a", "m2", new Date(clock.time + 5 * hour));
  first.stop();
  assert.equal(JSON.parse(await readFile(file, "utf8")).length, 2);

  clock.time += 2 * hour; // server was down past m1's wake time
  const woken: SnoozeEntry[] = [];
  const second = new SnoozeStore(file, (entry) => void woken.push(entry), clock);
  await second.load();
  await clock.advance(0);
  assert.deepEqual(woken.map((entry) => entry.messageKey), ["m1"]);
  assert.equal(second.isHidden("a", "m2"), true);
  await clock.advance(3 * hour);
  assert.deepEqual(woken.map((entry) => entry.messageKey), ["m1", "m2"]);
});

test("snoozes longer than the timer limit are re-armed", async () => {
  const clock = new FakeClock();
  const woken: SnoozeEntry[] = [];
  const store = new SnoozeStore(undefined, (entry) => void woken.push(entry), clock);
  const days = 40 * 24 * hour;
  await store.snooze("a", "m1", new Date(clock.time + days));
  await clock.advance(2 ** 31 - 1);
  assert.equal(woken.length, 0);
  await clock.advance(days - (2 ** 31 - 1));
  assert.equal(woken.length, 1);
});

test("a failed write does not block later writes", async () => {
  const dir = await mkdtemp(join(tmpdir(), "snooze-"));
  const blocker = join(dir, "sub");
  await writeFile(blocker, "x"); // mkdir of the data folder fails while this file exists
  const clock = new FakeClock();
  const store = new SnoozeStore(join(blocker, "snoozes.json"), () => undefined, clock);
  await assert.rejects(store.snooze("a", "m1", new Date(clock.time + hour)));
  await rm(blocker);
  await store.snooze("a", "m2", new Date(clock.time + hour));
  assert.equal(JSON.parse(await readFile(join(blocker, "snoozes.json"), "utf8")).length, 2);
  store.stop();
});
