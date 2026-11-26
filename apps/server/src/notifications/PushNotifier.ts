import type { IncomingMessageSummary } from "../domain/types.js";

export interface PushTarget {
  userId: string;
  deviceToken: string;
  platform: "ios" | "android" | "macos" | "windows" | "web";
}

export interface PushNotifier {
  notifyNewMessage(targets: PushTarget[], message: IncomingMessageSummary): Promise<void>;
}

export class NoopPushNotifier implements PushNotifier {
  async notifyNewMessage(targets: PushTarget[], message: IncomingMessageSummary): Promise<void> {
    // Mail content (subject, sender) never goes to logs.
    console.info("push:new-message", {
      targets: targets.length,
      accountId: message.accountId
    });
  }
}
