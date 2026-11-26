export type MailProtocol = "imap" | "pop3";

export type AuthMode = "oauth2" | "password" | "app-password";

export type ProviderId =
  | "gmail"
  | "outlook"
  | "naver"
  | "daum"
  | "custom";

export interface MailProviderConfig {
  id: ProviderId;
  displayName: string;
  authModes: AuthMode[];
  incoming: {
    protocol: MailProtocol;
    host: string;
    port: number;
    secure: boolean;
    supportsIdle: boolean;
  };
  outgoing: {
    host: string;
    port: number;
    secure: boolean;
  };
  oauth?: {
    authorizationUrl: string;
    tokenUrl: string;
    scopes: string[];
  };
}

export interface MailAccount {
  id: string;
  userId: string;
  providerId: ProviderId;
  emailAddress: string;
  displayName?: string;
  authMode: AuthMode;
  incomingProtocol: MailProtocol;
  encryptedSecretRef: string;
  syncStatus?: "idle" | "validating" | "syncing" | "error";
  syncError?: string;
  syncErrorCode?: "authentication";
  initialSync?: {
    includePreviousMessages: boolean;
    limit: number | "all";
  };
  lastSyncedAt?: Date;
  // Missing means on, so accounts stored before this field keep notifying.
  notificationsEnabled?: boolean;
  // Every message up to this UID was checked by a completed sync, in the
  // mailbox numbering named by syncedUidValidity (IMAP sends a bigint).
  syncedUid?: number;
  syncedUidValidity?: string;
  // UIDVALIDITY of the synced mailbox, as a string (IMAP sends a bigint).
  uidValidity?: string;
  connectionOverride?: {
    incoming?: {
      host: string;
      port: number;
      secure: boolean;
      supportsIdle?: boolean;
    };
    outgoing?: {
      host: string;
      port: number;
      secure: boolean;
    };
  };
  createdAt: Date;
  updatedAt: Date;
}

export interface IncomingMessageSummary {
  accountId: string;
  providerMessageId: string;
  mailbox: string;
  from: string;
  subject: string;
  snippet?: string;
  receivedAt: Date;
  // When the mail server stored the message (IMAP INTERNALDATE), unlike
  // receivedAt, which is the sender-set Date header.
  arrivedAt?: Date;
  hasAttachments: boolean;
  seen?: boolean;
  flagged?: boolean;
}

export interface MessageFlagChange {
  seen?: boolean;
  flagged?: boolean;
}

export interface IncomingMessageContent {
  text: string;
  truncated: boolean;
  links: IncomingMessageLink[];
  attachments: IncomingMessageAttachment[];
  // Read from the server on each body fetch, so messages saved before reply
  // support still get a Message-ID without a stored-data migration.
  thread?: MessageThreadHeaders;
}

export interface IncomingMessageAttachment {
  part: string;
  filename: string;
  contentType: string;
  /** Encoded size reported by IMAP, so slightly larger than the file. */
  size: number;
}

export interface AttachmentDownload {
  filename: string;
  contentType: string;
  stream: NodeJS.ReadableStream;
  close: () => Promise<void>;
}

export interface MessageThreadHeaders {
  messageId?: string;
  references: string[];
  replyTo: string[];
  to: string[];
  cc: string[];
}

export interface IncomingMessageLink {
  url: string;
  label: string;
}

export interface OutgoingMessageDraft {
  accountId: string;
  to: string[];
  cc?: string[];
  bcc?: string[];
  subject: string;
  html?: string;
  text?: string;
  inReplyTo?: string;
  references?: string[];
  attachments?: Array<{
    filename: string;
    contentType: string;
    storageKey: string;
  }>;
}
