import { randomUUID } from "node:crypto";
import type { MailAccount, OutgoingMessageDraft } from "../domain/types.js";
import type { MailSender, SendResult } from "./MailSender.js";

export const undoDelaySeconds = [0, 5, 10, 20, 30] as const;
export const defaultUndoDelaySeconds = 5;

export type SendStatus = "pending" | "sending" | "sent" | "failed" | "cancelled";

export interface SendStatusInfo {
  status: SendStatus;
  sendAt: string;
  error?: string;
  /** Only for failed sends, so the client can reopen the draft. */
  draft?: OutgoingMessageDraft;
}

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
  sendAt: Date;
  draft: OutgoingMessageDraft;
  error?: string;
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
    private readonly retainMs = 10 * 60_000, // >= client polling horizon (5 min)
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

  enqueue(
    account: MailAccount,
    draft: OutgoingMessageDraft,
    delaySeconds: number,
    /** Runs after a successful send; must not throw (the mail is already out). */
    onSent?: (result: SendResult) => Promise<void>,
    /** Builds the mail actually sent (e.g. fetches forwarded attachments); a throw fails the send. */
    prepare?: (draft: OutgoingMessageDraft) => Promise<OutgoingMessageDraft>
  ): { id: string; sendAt: Date } {
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
      sendAt: new Date(Date.now() + delaySeconds * 1000),
      draft,
      run: () => {
        // flush() during an in-flight send must await the same promise, never send twice.
        if (entry.sending) return entry.sending;
        if (entry.status !== "pending") return Promise.resolve();
        clearTimeout(entry.timer);
        entry.status = "sending";
        entry.sending = (async () => {
          await this.acquire();
          let result: SendResult | undefined;
          try {
            result = await this.sender.send(account, prepare ? await prepare(draft) : draft);
            entry.status = "sent";
          } catch (error) {
            entry.status = "failed";
            entry.error = error instanceof Error ? error.message : String(error);
            this.onError(error);
          } finally {
            this.release();
          }
          entry.settled = true;
          this.expire(id);
          if (result) await onSent?.(result);
        })();
        return entry.sending;
      }
    };
    entry.timer = setTimeout(() => void entry.run(), delaySeconds * 1000);
    this.entries.set(id, entry);
    return { id, sendAt: entry.sendAt };
  }

  /** Result of a queued send; failed entries keep their draft until retention ends. */
  status(id: string): SendStatusInfo | undefined {
    const entry = this.entries.get(id);
    if (!entry) return undefined;
    const info: SendStatusInfo = { status: entry.status, sendAt: entry.sendAt.toISOString() };
    if (entry.status === "failed") {
      info.error = entry.error;
      info.draft = entry.draft;
    }
    return info;
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
