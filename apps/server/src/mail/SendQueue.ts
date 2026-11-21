import { randomUUID } from "node:crypto";
import type { MailAccount, OutgoingMessageDraft } from "../domain/types.js";
import type { MailSender } from "./MailSender.js";

export const undoDelaySeconds = [0, 5, 10, 20, 30] as const;
export const defaultUndoDelaySeconds = 5;

export type SendStatus = "pending" | "sent" | "failed" | "cancelled";

interface Entry {
  status: SendStatus;
  timer?: NodeJS.Timeout;
  sending?: Promise<void>;
  run: () => Promise<void>;
}

// shortcut: queue lives in memory; pending mail is flushed on shutdown, but a crash loses it. Persist with scheduled send (issue #34 stage 2).
export class SendQueue {
  private readonly entries = new Map<string, Entry>();

  constructor(
    private readonly sender: MailSender,
    private readonly onError: (error: unknown) => void = () => undefined,
    private readonly retainMs = 60_000
  ) {}

  enqueue(account: MailAccount, draft: OutgoingMessageDraft, delaySeconds: number): string {
    const id = randomUUID();
    const entry: Entry = {
      status: "pending",
      run: () => {
        // flush() during an in-flight send must await the same promise, never send twice.
        if (entry.sending) return entry.sending;
        if (entry.status !== "pending") return Promise.resolve();
        clearTimeout(entry.timer);
        entry.status = "sent";
        entry.sending = (async () => {
          try {
            await this.sender.send(account, draft);
          } catch (error) {
            entry.status = "failed";
            this.onError(error);
          }
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
      this.expire(id);
    }
    return entry.status;
  }

  /** Send everything still waiting (server shutdown). */
  async flush(): Promise<void> {
    await Promise.all([...this.entries.values()].map((entry) => entry.run()));
  }
}
