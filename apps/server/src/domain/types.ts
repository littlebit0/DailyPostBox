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

export interface IncomingCapabilities {
  idle: boolean;
  move: boolean;
  specialUse: boolean;
  condstore: boolean;
  /** ISO time of the login that reported these capabilities. */
  checkedAt: string;
}

export interface MailAccount {
  id: string;
  userId: string;
  providerId: ProviderId;
  emailAddress: string;
  displayName?: string;
  signature?: string;
  authMode: AuthMode;
  incomingProtocol: MailProtocol;
  encryptedSecretRef: string;
  syncStatus?: "idle" | "validating" | "syncing" | "error";
  /** Set while the background thread-metadata backfill runs; clients keep refreshing. */
  threadBackfill?: "running";
  syncError?: string;
  syncErrorCode?: "authentication";
  initialSync?: {
    includePreviousMessages: boolean;
    limit: number | "all";
  };
  lastSyncedAt?: Date;
  incomingCapabilities?: IncomingCapabilities;
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
  // undefined: not checked yet (synced before this field existed); null: no header.
  unsubscribe?: ListUnsubscribe | null;
  category?: "person" | "notification" | "newsletter";
  messageId?: string;
  inReplyTo?: string;
  references?: string[];
  gmailThreadId?: string;
  seen?: boolean;
  flagged?: boolean;
}

export interface ListUnsubscribe {
  url?: string;
  mailto?: { address: string; subject?: string; body?: string };
  // RFC 8058 one-click is only recorded here; handling it is a later stage.
  oneClick: boolean;
}

export interface MessageFlagChange {
  seen?: boolean;
  flagged?: boolean;
}

export type AuthenticationFailure = "dmarc" | "spf" | "dkim";

export interface IncomingMessageContent {
  text: string;
  truncated: boolean;
  links: IncomingMessageLink[];
  security: MessageSecurity;
  invite?: CalendarInvite;
  authenticationFailures?: AuthenticationFailure[];
  unsubscribe?: ListUnsubscribe | null;
  /** Raw HTML alternative. Must go through sanitizeHtml before leaving the server. */
  html?: string;
  attachments: IncomingMessageAttachment[];
  // Read from the server on each body fetch, so messages saved before reply
  // support still get a Message-ID without a stored-data migration.
  thread?: MessageThreadHeaders;
}

export interface MessageSecurity {
  signed: "smime" | "openpgp" | null;
  encrypted: "smime" | "openpgp" | null;
  verified: boolean;
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

export interface CalendarInvite {
  method: string | null;
  summary: string;
  /** ISO 8601: UTC "Z", date only for all-day, or wall-clock without offset when the zone is unknown. */
  start: string;
  end: string | null;
  allDay: boolean;
  location: string | null;
  organizer: string | null;
  recurring: boolean;
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
  // Original attachments to forward; the server fetches them from IMAP at send time.
  forwardOf?: {
    messageId: string;
    parts: string[];
    /** Filled by the server from the original message, for the failed-send draft. */
    attachments?: IncomingMessageAttachment[];
  };
  /** Bytes resolved from forwardOf right before sending; never kept in the queue. */
  forwardedAttachments?: Array<{
    filename: string;
    contentType: string;
    content: Buffer;
  }>;
  attachments?: Array<{
    filename: string;
    contentType: string;
    storageKey: string;
  }>;
}
