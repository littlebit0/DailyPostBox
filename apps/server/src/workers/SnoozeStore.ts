import { dirname } from "node:path";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";

export interface SnoozeEntry {
  accountId: string;
  messageKey: string;
  wakeAt: string;
  /** Set when the timer fired; the message then sorts by this time. */
  wokeAt?: string;
}

export interface SnoozeClock {
  now(): number;
  setTimer(callback: () => void, ms: number): unknown;
  clearTimer(handle: unknown): void;
}

const realClock: SnoozeClock = {
  now: () => Date.now(),
  setTimer: (callback, ms) => {
    const handle = setTimeout(callback, ms);
    handle.unref();
    return handle;
  },
  clearTimer: (handle) => clearTimeout(handle as NodeJS.Timeout)
};

// setTimeout overflows above 2^31-1 ms, so long snoozes are re-armed in steps.
const maxTimerMs = 2 ** 31 - 1;
const wokenRetentionMs = 7 * 24 * 60 * 60_000;

/**
 * Server-side snooze list. Snoozed messages stay on the mail server; they are
 * only hidden from DailyPostBox lists until wakeAt. Entries survive restarts.
 */
export class SnoozeStore {
  private readonly entries = new Map<string, SnoozeEntry>();
  private readonly timers = new Map<string, unknown>();
  private writeChain: Promise<void> = Promise.resolve();

  constructor(
    private readonly filePath: string | undefined,
    private readonly onWake: (entry: SnoozeEntry) => Promise<void> | void,
    private readonly clock: SnoozeClock = realClock
  ) {}

  /** Loads saved entries and arms timers; overdue ones wake immediately. */
  async load(): Promise<void> {
    if (this.filePath) {
      try {
        const saved = JSON.parse(await readFile(this.filePath, "utf8")) as SnoozeEntry[];
        for (const entry of saved) this.entries.set(keyOf(entry.accountId, entry.messageKey), entry);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
    for (const entry of [...this.entries.values()]) {
      if (entry.wokeAt) {
        if (this.clock.now() - Date.parse(entry.wokeAt) > wokenRetentionMs) {
          this.entries.delete(keyOf(entry.accountId, entry.messageKey));
        }
      } else {
        this.arm(entry);
      }
    }
  }

  async snooze(accountId: string, messageKey: string, wakeAt: Date): Promise<SnoozeEntry> {
    const entry: SnoozeEntry = { accountId, messageKey, wakeAt: wakeAt.toISOString() };
    this.clearTimer(keyOf(accountId, messageKey));
    this.entries.set(keyOf(accountId, messageKey), entry);
    this.arm(entry);
    await this.persist();
    return entry;
  }

  async cancel(accountId: string, messageKey: string): Promise<boolean> {
    const key = keyOf(accountId, messageKey);
    this.clearTimer(key);
    const existed = this.entries.delete(key);
    if (existed) await this.persist();
    return existed;
  }

  async removeAccount(accountId: string): Promise<void> {
    for (const [key, entry] of this.entries) {
      if (entry.accountId !== accountId) continue;
      this.clearTimer(key);
      this.entries.delete(key);
    }
    await this.persist();
  }

  /** True while the message is snoozed and not yet due. */
  isHidden(accountId: string, messageKey: string): boolean {
    const entry = this.entries.get(keyOf(accountId, messageKey));
    return Boolean(entry && !entry.wokeAt);
  }

  /** Time used to order the list: a woken message returns to the top. */
  sortTime(accountId: string, messageKey: string, receivedAt: Date): number {
    const entry = this.entries.get(keyOf(accountId, messageKey));
    const woke = entry?.wokeAt ? Date.parse(entry.wokeAt) : 0;
    return Math.max(receivedAt.getTime(), woke);
  }

  list(): SnoozeEntry[] {
    return [...this.entries.values()];
  }

  stop(): void {
    for (const handle of this.timers.values()) this.clock.clearTimer(handle);
    this.timers.clear();
  }

  private arm(entry: SnoozeEntry): void {
    const key = keyOf(entry.accountId, entry.messageKey);
    const remaining = Date.parse(entry.wakeAt) - this.clock.now();
    this.timers.set(
      key,
      this.clock.setTimer(() => void this.fire(key), Math.min(Math.max(remaining, 0), maxTimerMs))
    );
  }

  private async fire(key: string): Promise<void> {
    this.timers.delete(key);
    const entry = this.entries.get(key);
    if (!entry || entry.wokeAt) return;
    if (Date.parse(entry.wakeAt) > this.clock.now()) {
      this.arm(entry);
      return;
    }
    entry.wokeAt = new Date(this.clock.now()).toISOString();
    await this.persist().catch(() => undefined);
    try {
      await this.onWake(entry);
    } catch (error) {
      console.warn("snooze:wake-failed", error instanceof Error ? error.message : error);
    }
  }

  private clearTimer(key: string): void {
    const handle = this.timers.get(key);
    if (handle === undefined) return;
    this.clock.clearTimer(handle);
    this.timers.delete(key);
  }

  private persist(): Promise<void> {
    const filePath = this.filePath;
    if (!filePath) return Promise.resolve();
    // Recover a previously rejected chain so one failed write does not block later ones.
    this.writeChain = this.writeChain.catch(() => undefined).then(async () => {
      await mkdir(dirname(filePath), { recursive: true, mode: 0o700 });
      const temporaryPath = `${filePath}.tmp`;
      await writeFile(temporaryPath, JSON.stringify([...this.entries.values()]), { mode: 0o600 });
      await rename(temporaryPath, filePath);
    });
    return this.writeChain;
  }
}

function keyOf(accountId: string, messageKey: string): string {
  return `${accountId}:${messageKey}`;
}
