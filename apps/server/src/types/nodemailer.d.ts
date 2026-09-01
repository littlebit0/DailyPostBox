declare module "nodemailer" {
  export interface SendMailResult {
    messageId?: string;
    accepted: unknown[];
    rejected: unknown[];
  }

  export interface Transporter {
    verify(): Promise<boolean>;
    sendMail(message: Record<string, unknown>): Promise<SendMailResult>;
  }

  export interface TransportOptions {
    host: string;
    port: number;
    secure: boolean;
    requireTLS?: boolean;
    auth: {
      user: string;
      pass: string;
    };
  }

  const nodemailer: {
    createTransport(options: TransportOptions): Transporter;
  };

  export default nodemailer;
}
