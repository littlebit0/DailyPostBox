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
  signature?: string;
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
}

export interface IncomingMessageContent {
  text: string;
  truncated: boolean;
  links: IncomingMessageLink[];
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
  attachments?: Array<{
    filename: string;
    contentType: string;
    storageKey: string;
  }>;
}
