import { randomUUID } from "node:crypto";
import type { MailAccount, OutgoingMessageDraft } from "../domain/types.js";
import type { MailSender } from "./MailSender.js";

export const undoDelaySeconds = [0, 5, 10, 20, 30] as const;
export const defaultUndoDelaySeconds = 5;

export type SendStatus = "pending" | "sent" | "failed" | "cancelled";

export interface SendQueueLimits {
  maxEntries: number;
  maxPendingPerAccount: number;
  maxConcurrentSends: number;
}

export const defaultSendQueueLimits: SendQueueLimits = {
  maxEntries: 200,
  maxPendingPerAccount: 20,
  maxConcurrentSends: 4
};

export class SendQueueFullError extends Error {
  constructor() {
    super("Send queue is full");
  }
}

interface Entry {
  accountId: string;
  settled: boolean;
  status: SendStatus;
  timer?: NodeJS.Timeout;
  sending?: Promise<void>;
  run: () => Promise<void>;
}

// shortcut: queue lives in memory; pending mail is flushed on shutdown, but a crash loses it. Persist with scheduled send (issue #34 stage 2).
export class SendQueue {
  private readonly entries = new Map<string, Entry>();
  private readonly limits: SendQueueLimits;
  private activeSends = 0;
  private readonly waiters: Array<() => void> = [];

  constructor(
    private readonly sender: MailSender,
    private readonly onError: (error: unknown) => void = () => undefined,
    private readonly retainMs = 60_000,
    limits: Partial<SendQueueLimits> = {}
  ) {
    this.limits = { ...defaultSendQueueLimits, ...limits };
  }

  private async acquire(): Promise<void> {
    if (this.activeSends < this.limits.maxConcurrentSends) {
      this.activeSends++;
      return;
    }
    // The releasing send hands its slot over, so activeSends stays unchanged.
    await new Promise<void>((resolve) => this.waiters.push(resolve));
  }

  private release(): void {
    const next = this.waiters.shift();
    if (next) next();
    else this.activeSends--;
  }

  enqueue(account: MailAccount, draft: OutgoingMessageDraft, delaySeconds: number): string {
    if (this.entries.size >= this.limits.maxEntries) throw new SendQueueFullError();
    let pendingForAccount = 0;
    for (const e of this.entries.values()) {
      if (e.accountId === account.id && !e.settled) pendingForAccount++;
    }
    if (pendingForAccount >= this.limits.maxPendingPerAccount) throw new SendQueueFullError();

    const id = randomUUID();
    const entry: Entry = {
      accountId: account.id,
      settled: false,
      status: "pending",
      run: () => {
        // flush() during an in-flight send must await the same promise, never send twice.
        if (entry.sending) return entry.sending;
        if (entry.status !== "pending") return Promise.resolve();
        clearTimeout(entry.timer);
        entry.status = "sent";
        entry.sending = (async () => {
          await this.acquire();
          try {
            await this.sender.send(account, draft);
          } catch (error) {
            entry.status = "failed";
            this.onError(error);
          } finally {
            this.release();
          }
          entry.settled = true;
          this.expire(id);
        })();
        return entry.sending;
      }
    };
    entry.timer = setTimeout(() => void entry.run(), delaySeconds * 1000);
    this.entries.set(id, entry);
    return id;
  }

  private expire(id: string): void {
    setTimeout(() => this.entries.delete(id), this.retainMs).unref();
  }

  /** Returns undefined for unknown id, otherwise the status after the attempt. */
  cancel(id: string): SendStatus | undefined {
    const entry = this.entries.get(id);
    if (!entry) return undefined;
    if (entry.status === "pending") {
      clearTimeout(entry.timer);
      entry.status = "cancelled";
      entry.settled = true;
      this.expire(id);
    }
    return entry.status;
  }

  /** Send everything still waiting (server shutdown). */
  async flush(): Promise<void> {
    await Promise.all([...this.entries.values()].map((entry) => entry.run()));
  }
}
