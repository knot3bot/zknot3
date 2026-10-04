// AgentWallet — Key management + zkLogin authentication
import type { Address, KeyPair, TxReceipt } from './types';
import { blake3 } from '@noble/hashes/blake3';

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
    const publicKey = new Uint8Array(await crypto.subtle.exportKey('raw', keyPair.publicKey));
    // Ed25519 private keys cannot be exported in raw format (WebCrypto
    // limitation); the JWK `d` field carries the 32-byte seed.
    const jwk = await crypto.subtle.exportKey('jwk', keyPair.privateKey);
    const secretKey = base64urlToBytes(jwk.d!);
    return { publicKey, secretKey };
  }

  /** Rebuild a signable CryptoKey from the stored seed bytes. */
  private static async importSignKey(kp: KeyPair): Promise<CryptoKey> {
    return crypto.subtle.importKey(
      'jwk',
      { kty: 'OKP', crv: 'Ed25519', d: bytesToBase64url(kp.secretKey), x: bytesToBase64url(kp.publicKey) },
      { name: 'Ed25519' } as any,
      false,
      ['sign'],
    );
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
    const signKey = await AgentWallet.importSignKey(this.ephemeralKey);
    const signature = new Uint8Array(await crypto.subtle.sign('Ed25519' as any, signKey, hexToBytes(digest) as any));

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

function base64urlToBytes(b64: string): Uint8Array {
  const normalized = b64.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  return new Uint8Array(Buffer.from(padded, 'base64'));
}

function bytesToBase64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.slice(i, i + 2), 16);
  return bytes;
}

/** Canonical Blake3 transaction digest.
 * Serializes the transaction with JSON keys sorted for determinism, then
 * hashes with Blake3 (matching the node's digest primitive). */
function computeTxDigest(tx: any): string {
  const canonical = JSON.stringify(tx, (_key, value) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)));
    }
    return value;
  });
  return hexEncode(blake3(new TextEncoder().encode(canonical)));
}

function blake3Hash(data: Uint8Array): string {
  return hexEncode(blake3(data));
}
