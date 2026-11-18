import { z } from "zod";

// Local development uses this file so OAuth credentials do not need to be
// placed in a shell command every time the mail server starts.
try {
  process.loadEnvFile(".env");
} catch {
  // A .env file is optional; deployment environments provide real variables.
}

const envSchema = z.object({
  PORT: z.coerce.number().default(4000),
  HOST: z.string().default("0.0.0.0"),
  DATABASE_URL: z.string().optional(),
  DATA_FILE_PATH: z.string().optional(),
  ENCRYPTION_MASTER_KEY: z.string().optional(),
  PUSH_PROVIDER: z.enum(["fcm", "apns", "web-push", "noop"]).default("noop"),
  APNS_KEY_PATH: z.string().optional(),
  APNS_KEY_ID: z.string().optional(),
  APNS_TEAM_ID: z.string().optional(),
  APNS_TOPIC: z.string().default("com.dailypostbox.app"),
  APNS_PRODUCTION: z.enum(["true", "false"]).default("false"),
  OAUTH_REDIRECT_BASE_URL: z.string().url().default("https://api.dailypostbox.com"),
  GOOGLE_OAUTH_CLIENT_ID: z.string().optional(),
  GOOGLE_OAUTH_CLIENT_SECRET: z.string().optional(),
  OUTLOOK_OAUTH_CLIENT_ID: z.string().optional(),
  OUTLOOK_OAUTH_CLIENT_SECRET: z.string().optional()
});

export const env = envSchema.parse(process.env);
