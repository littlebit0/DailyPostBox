import type { MailProviderConfig, ProviderId } from "../domain/types.js";

export const providerRegistry: Record<ProviderId, MailProviderConfig> = {
  gmail: {
    id: "gmail",
    displayName: "Gmail",
    authModes: ["oauth2", "app-password"],
    incoming: {
      protocol: "imap",
      host: "imap.gmail.com",
      port: 993,
      secure: true,
      supportsIdle: true
    },
    outgoing: {
      host: "smtp.gmail.com",
      port: 465,
      secure: true
    },
    oauth: {
      authorizationUrl: "https://accounts.google.com/o/oauth2/v2/auth",
      tokenUrl: "https://oauth2.googleapis.com/token",
      scopes: [
        "openid",
        "email",
        "profile",
        "https://mail.google.com/"
      ]
    }
  },
  outlook: {
    id: "outlook",
    displayName: "Outlook / Microsoft 365",
    authModes: ["oauth2"],
    incoming: {
      protocol: "imap",
      host: "outlook.office365.com",
      port: 993,
      secure: true,
      supportsIdle: true
    },
    outgoing: {
      host: "smtp.office365.com",
      port: 587,
      secure: false
    },
    oauth: {
      authorizationUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      tokenUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      scopes: [
        "openid",
        "email",
        "profile",
        "offline_access",
        "https://outlook.office.com/IMAP.AccessAsUser.All",
        "https://outlook.office.com/SMTP.Send"
      ]
    }
  },
  naver: {
    id: "naver",
    displayName: "Naver Mail",
    authModes: ["password", "app-password"],
    incoming: {
      protocol: "imap",
      host: "imap.naver.com",
      port: 993,
      secure: true,
      supportsIdle: true
    },
    outgoing: {
      host: "smtp.naver.com",
      port: 465,
      secure: true
    }
  },
  daum: {
    id: "daum",
    displayName: "Daum / Kakao Mail",
    authModes: ["password", "app-password"],
    incoming: {
      protocol: "imap",
      host: "imap.daum.net",
      port: 993,
      secure: true,
      supportsIdle: true
    },
    outgoing: {
      host: "smtp.daum.net",
      port: 465,
      secure: true
    }
  },
  custom: {
    id: "custom",
    displayName: "Custom Mail Server",
    authModes: ["password", "app-password", "oauth2"],
    incoming: {
      protocol: "imap",
      host: "",
      port: 993,
      secure: true,
      supportsIdle: false
    },
    outgoing: {
      host: "",
      port: 465,
      secure: true
    }
  }
};

export function getProvider(providerId: ProviderId): MailProviderConfig {
  return providerRegistry[providerId];
}
