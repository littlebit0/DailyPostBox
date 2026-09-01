declare module "mailparser" {
  export interface ParsedMail {
    text?: string;
  }

  export interface SimpleParserOptions {
    keepCidLinks?: boolean;
    maxHtmlLengthToParse?: number;
  }

  export function simpleParser(
    source: Buffer | string | NodeJS.ReadableStream,
    options?: SimpleParserOptions
  ): Promise<ParsedMail>;
}
