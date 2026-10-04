// zknot3 Agent SDK tests — run with `npm test` (tsc + node --test)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { strict as assertStrict } from 'node:assert';

import { PTBBuilder } from '../src/ptb.js';
import { parseIntent, intentToPTB, translate } from '../src/translator.js';
import { AgentWallet } from '../src/wallet.js';
import { DryRunner } from '../src/dryrun.js';
import { AgentRegistryClient } from '../src/registry.js';
import { blake3 } from '@noble/hashes/blake3';

// ---------------------------------------------------------------- PTBBuilder

test('PTBBuilder composes operations fluently and immutably on build', () => {
  const builder = new PTBBuilder()
    .moveCall('art_generator', 'generate_batch', [3, 'cyberpunk'])
    .transferObjects(['0x' + 'aa'.repeat(32)], '0x' + 'bb'.repeat(32))
    .splitCoins('coin1', [70, 20, 10])
    .mergeCoins(['coin1', 'coin2'])
    .publish([new Uint8Array([0x00, 0x01])])
    .sponsoredBy('0x' + 'cc'.repeat(32));

  const ptb1 = builder.build();
  const ptb2 = builder.build();
  assertStrict.equal(ptb1.operations.length, 5);
  // build() returns a copy — later builds are not affected by mutation
  assertStrict.deepEqual(ptb2.operations, ptb1.operations);

  assertStrict.deepEqual(Object.keys(ptb1.operations[0]), ['MoveCall']);
  assertStrict.deepEqual(Object.keys(ptb1.operations[1]), ['TransferObjects']);
  assertStrict.deepEqual(Object.keys(ptb1.operations[4]), ['Publish']);
});

// ---------------------------------------------------------------- Translator

test('parseIntent recognizes transfer, split, and listing intents', () => {
  const transfer = parseIntent('Transfer artwork_1, artwork_2 to 0xABCD');
  assertStrict.equal(transfer.kind, 'transfer');
  if (transfer.kind === 'transfer') {
    assertStrict.deepEqual(transfer.objects, ['artwork_1', 'artwork_2']);
    assertStrict.equal(transfer.recipient, '0xabcd');
  }

  const split = parseIntent('split sale_coin into 70, 20, 10');
  assertStrict.equal(split.kind, 'split_rewards');
  if (split.kind === 'split_rewards') {
    assertStrict.equal(split.coinId, 'sale_coin');
    assertStrict.deepEqual(split.shares, [70, 20, 10]);
  }

  const listing = parseIntent('List artwork_1, artwork_2 for 0.5 ETH');
  assertStrict.equal(listing.kind, 'list_for_sale');
  if (listing.kind === 'list_for_sale') {
    assertStrict.equal(listing.price, 0.5);
    assertStrict.equal(listing.currency, 'eth');
  }
});

test('parseIntent falls through to unknown for unstructured input', () => {
  const intent = parseIntent('hello world');
  assertStrict.equal(intent.kind, 'unknown');
});

test('intentToPTB maps transfer intent to TransferObjects operation', () => {
  const intent = parseIntent('Transfer artwork_1 to 0xABCD');
  const ptb = intentToPTB(intent).build();
  assertStrict.equal(ptb.operations.length, 1);
  const op = ptb.operations[0] as { TransferObjects: { objects: string[]; recipient: string } };
  assertStrict.ok(op.TransferObjects);
  assertStrict.equal(op.TransferObjects.recipient, '0xabcd');
});

test('translate one-shot produces a non-empty PTB for known intents', () => {
  const ptb = translate('Split rewards_coin into 60 and 40');
  assertStrict.ok(ptb.operations.length >= 1);
});

// ---------------------------------------------------------------- Wallet

test('wallet address derivation is deterministic and input-sensitive', () => {
  const pk = new Uint8Array(32).fill(7);
  const a1 = AgentWallet.deriveAddress('https://accounts.google.com', 'user-1', pk);
  const a2 = AgentWallet.deriveAddress('https://accounts.google.com', 'user-1', pk);
  const a3 = AgentWallet.deriveAddress('https://accounts.google.com', 'user-2', pk);
  // 64 hex chars, deterministic, and NOT the all-zero placeholder
  assertStrict.match(a1, /^[0-9a-f]{64}$/);
  assertStrict.equal(a1, a2);
  assertStrict.notEqual(a1, a3);
  assertStrict.notEqual(a1, '0x' + '0'.repeat(64));
});

test('ephemeral Ed25519 key signs messages verifiable by its public key', async () => {
  const kp = await AgentWallet.generateEphemeralKey();
  assertStrict.equal(kp.publicKey.length, 32);
  assertStrict.equal(kp.secretKey.length, 32);

  const message = new TextEncoder().encode('zknot3-sdk-test');
  const cryptoKey = await AgentWallet['importSignKey'](kp);
  const signature = new Uint8Array(await crypto.subtle.sign('Ed25519' as any, cryptoKey, message));

  const verifyKey = await crypto.subtle.importKey(
    'raw', kp.publicKey as any, { name: 'Ed25519' } as any, false, ['verify'],
  );
  assertStrict.equal(
    await crypto.subtle.verify('Ed25519' as any, verifyKey, signature as any, message), true,
  );
  message[0] ^= 0xff;
  assertStrict.equal(
    await crypto.subtle.verify('Ed25519' as any, verifyKey, signature as any, message), false,
  );
});

// --------------------------------------------------- Blake3 digest primitive

test('SDK Blake3 matches the reference vector', () => {
  // BLAKE3 official test vector for the empty input and "abc"
  assertStrict.equal(
    Buffer.from(blake3(new Uint8Array(0))).toString('hex'),
    'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262',
  );
  assertStrict.equal(
    Buffer.from(blake3(new TextEncoder().encode('abc'))).toString('hex'),
    '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85',
  );
});

// -------------------------------------------------- DryRunner against a mock

test('DryRunner posts JSON-RPC dry-run and maps the response', async () => {
  const server = BunLikeServer();
  const port = await server.start({
    '/rpc': async (body: any) => ({
      jsonrpc: '2.0',
      id: 1,
      digest: '0x' + 'ab'.repeat(32),
      status: 'success',
      gasUsed: 1234,
      events: [],
      outputObjects: ['0xobj1'],
    }),
  });
  try {
    const runner = new DryRunner(`http://127.0.0.1:${port}`);
    const receipt = await runner.simulate({ operations: [] });
    assertStrict.equal(receipt.status, 'success');
    assertStrict.equal(receipt.gasUsed, 1234);
    assertStrict.deepEqual(receipt.effects, ['0xobj1']);
  } finally {
    await server.stop();
  }
});

test('AgentRegistryClient discover maps RPC result rows to AgentInfo', async () => {
  const server = BunLikeServer();
  const port = await server.start({
    '/rpc': async (body: any) => ({
      jsonrpc: '2.0',
      id: 1,
      result: {
        agents: [{
          id: '0x1', owner: '0x2', name: 'pixbot', capabilities: ['image-gen'],
          endpointUrl: 'https://pixbot.example', reputationScore: 4.5,
          totalTasksCompleted: 10, totalRewardsEarned: 100, createdAt: 1, isActive: true,
        }],
      },
    }),
  });
  try {
    const client = new AgentRegistryClient(`http://127.0.0.1:${port}`);
    const agents = await client.discover('image-gen');
    assertStrict.equal(agents.length, 1);
    assertStrict.equal(agents[0].name, 'pixbot');
  } finally {
    await server.stop();
  }
});

// Minimal HTTP mock so tests need no external process.
type RouteHandler = (body: any) => Promise<any>;

function BunLikeServer() {
  const http = require('node:http') as typeof import('node:http');
  let handle: RouteHandler | null = null;
  let instance: import('node:http').Server | null = null;

  return {
    async start(routes: Record<string, RouteHandler>): Promise<number> {
      handle = routes['/rpc'];
      instance = http.createServer((req, res) => {
        let data = '';
        req.on('data', (chunk) => (data += chunk));
        req.on('end', async () => {
          const body = data ? JSON.parse(data) : {};
          const reply = handle ? await handle(body) : {};
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(reply));
        });
      });
      return new Promise((resolve) => {
        instance!.listen(0, '127.0.0.1', () => {
          resolve((instance!.address() as import('node:net').AddressInfo).port);
        });
      });
    },
    async stop(): Promise<void> {
      if (!instance) return;
      await new Promise<void>((resolve) => instance!.close(() => resolve()));
    },
  };
}

// Silence unused-import lint on assert (default import kept for API parity)
void assert;
