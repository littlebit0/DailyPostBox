export interface SecretResolver {
  resolve(encryptedSecretRef: string): Promise<string>;
}

export class DevelopmentSecretResolver implements SecretResolver {
  async resolve(encryptedSecretRef: string): Promise<string> {
    return encryptedSecretRef;
  }
}
