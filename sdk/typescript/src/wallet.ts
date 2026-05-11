// AgentWallet — Key management + zkLogin authentication
import type { Address, KeyPair, TxReceipt } from './types';

export class AgentWallet {
  private address: string;
  private ephemeralKey: KeyPair | null = null;
  private oauthProvider: string | null = null;
  private oauthSubject: string | null = null;

  private constructor(address: string) {
    this.address = address;
  }

  /** Create wallet from OAuth credentials (zkLogin). */
  static async fromOAuth(
    provider: 'google' | 'apple' | 'github',
    jwt: string,
  ): Promise<AgentWallet> {
    const issuer = {
      google: 'https://accounts.google.com',
      apple: 'https://appleid.apple.com',
      github: 'https://github.com/login/oauth',
    }[provider];

    // Parse JWT subject (simplified — production uses full JWT verification)
    const payload = JSON.parse(atob(jwt.split('.')[1]));
    const subject = payload.sub;

    const wallet = new AgentWallet('');
    wallet.oauthProvider = issuer;
    wallet.oauthSubject = subject;
    wallet.ephemeralKey = await AgentWallet.generateEphemeralKey();
    wallet.address = AgentWallet.deriveAddress(issuer, subject, wallet.ephemeralKey.publicKey);
    return wallet;
  }

  /** Generate ephemeral Ed25519 keypair for transaction signing. */
  static async generateEphemeralKey(): Promise<KeyPair> {
    const keyPair = await crypto.subtle.generateKey(
      { name: 'Ed25519' } as any,
      true,
      ['sign', 'verify'],
    );
    const publicKey = await crypto.subtle.exportKey('raw', keyPair.publicKey);
    const secretKey = await crypto.subtle.exportKey('raw', keyPair.privateKey);
    return {
      publicKey: new Uint8Array(publicKey),
      secretKey: new Uint8Array(secretKey),
    };
  }

  /** Derive on-chain address from OAuth identity + ephemeral key. */
  static deriveAddress(issuer: string, subject: string, ephemeralPubkey: Uint8Array): string {
    const input = new TextEncoder().encode(`${issuer}:${subject}:${hexEncode(ephemeralPubkey)}`);
    return blake3Hash(input).slice(0, 64); // first 32 bytes as hex
  }

  /** Sign and submit a transaction to the node. */
  async signAndSubmit(tx: any, nodeUrl: string = 'http://localhost:9003'): Promise<TxReceipt> {
    if (!this.ephemeralKey) throw new Error('No ephemeral key. Call fromOAuth() first.');

    const digest = computeTxDigest(tx);
    const signature = await crypto.subtle.sign(
      'Ed25519' as any,
      this.ephemeralKey.secretKey as any,
      hexToBytes(digest),
    );

    const body = JSON.stringify({
      jsonrpc: '2.0',
      method: 'knot3_submitTransaction',
      params: [{ ...tx, signature: hexEncode(new Uint8Array(signature)) }],
      id: 1,
    });

    const response = await fetch(`${nodeUrl}/rpc`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    });
    return response.json();
  }

  getAddress(): string { return this.address; }
  getOAuthProvider(): string | null { return this.oauthProvider; }
  getOAuthSubject(): string | null { return this.oauthSubject; }
}

// Placeholder helpers
function hexEncode(buf: Uint8Array): string {
  return Array.from(buf).map(b => b.toString(16).padStart(2, '0')).join('');
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.slice(i, i + 2), 16);
  return bytes;
}

function computeTxDigest(_tx: any): string {
  return '0'.repeat(64); // placeholder — real impl uses Blake3
}

function blake3Hash(_data: Uint8Array): string {
  return '0'.repeat(64); // placeholder — real impl uses blake3 npm package
}
