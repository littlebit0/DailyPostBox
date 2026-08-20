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
    console.info("push:new-message", {
      targets: targets.length,
      accountId: message.accountId,
      subject: message.subject
    });
  }
}
