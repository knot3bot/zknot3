// NL→PTB Translator — Natural Language to Programmable Transaction Blocks
// Parses human creative intent into structured on-chain operations.

import type { PTB, Operation } from './types';
import { PTBBuilder } from './ptb';

/** Intent types recognized by the translator. */
type Intent =
  | { kind: 'generate_art'; style: string; count: number; license?: string; royalty?: number }
  | { kind: 'transfer'; objects: string[]; recipient: string }
  | { kind: 'split_rewards'; coinId: string; shares: number[] }
  | { kind: 'publish_module'; moduleName: string }
  | { kind: 'list_for_sale'; creations: string[]; price: number; currency: string }
  | { kind: 'unknown'; raw: string };

/** Parse natural language text into a structured intent. */
export function parseIntent(text: string): Intent {
  const t = text.toLowerCase();

  // Art generation patterns
  const artMatch = t.match(
    /(?:generate|create|make)\s+(\d+)\s+(.+?)\s*(?:artwork|art|image|nft|creation)s?\s*(?:with|using)?\s*(.+?)?\s*(?:license|cc)?\s*$/i,
  );
  if (artMatch) {
    return {
      kind: 'generate_art',
      count: parseInt(artMatch[1]),
      style: artMatch[2].trim(),
      license: artMatch[3]?.trim(),
    };
  }

  // Transfer patterns
  const transferMatch = t.match(/transfer\s+(.+?)\s+to\s+(0x[a-fA-F0-9]+|[a-zA-Z0-9_]+)/i);
  if (transferMatch) {
    return {
      kind: 'transfer',
      objects: transferMatch[1].split(',').map(s => s.trim()),
      recipient: transferMatch[2],
    };
  }

  // Split rewards patterns
  const splitMatch = t.match(/split\s+(.+?)\s+(?:into|as)\s+(.+)/i);
  if (splitMatch) {
    const shares = splitMatch[2]
      .split(/,|\s+and\s+/)
      .map(s => parseInt(s.replace('%', '').trim()))
      .filter(n => !isNaN(n));
    return { kind: 'split_rewards', coinId: splitMatch[1], shares };
  }

  // List for sale patterns
  const listMatch = t.match(
    /list\s+(.+?)\s+(?:for|at)\s+(\d+(?:\.\d+)?)\s*(eth|knot|usd)/i,
  );
  if (listMatch) {
    return {
      kind: 'list_for_sale',
      creations: listMatch[1].split(',').map(s => s.trim()),
      price: parseFloat(listMatch[2]),
      currency: listMatch[3].toLowerCase(),
    };
  }

  return { kind: 'unknown', raw: text };
}

/** Translate a structured intent into PTB operations. */
export function intentToPTB(intent: Intent, builder?: PTBBuilder): PTBBuilder {
  const b = builder ?? new PTBBuilder();

  switch (intent.kind) {
    case 'generate_art': {
      b.moveCall('art_generator', 'generate_batch', [intent.count, intent.style]);
      if (intent.license) {
        const licenseType = intent.license.toUpperCase().replace('-', '_');
        b.moveCall('license', 'attach', [licenseType, intent.royalty ?? 500]);
      }
      b.publish([]);
      break;
    }
    case 'transfer': {
      b.transferObjects(intent.objects, intent.recipient);
      break;
    }
    case 'split_rewards': {
      b.splitCoins(intent.coinId, intent.shares);
      break;
    }
    case 'list_for_sale': {
      b.moveCall('marketplace', 'list_batch', [
        intent.creations,
        intent.price,
        intent.currency,
      ]);
      break;
    }
    case 'publish_module': {
      b.publish([]);
      break;
    }
    case 'unknown': {
      // Pass through as a raw MoveCall for manual handling
      b.moveCall('interpreter', 'execute_raw', [intent.raw]);
      break;
    }
  }
  return b;
}

/** One-shot: natural language → PTB. */
export function translate(text: string): PTB {
  const intent = parseIntent(text);
  return intentToPTB(intent).build();
}

// Run with: npx ts-node translator.ts
if (require.main === module) {
  const examples = [
    'Generate 100 cyberpunk artworks with CC-BY license',
    'Transfer artwork_1, artwork_2 to 0xABCD',
    'Split sale_coin into 70, 20, 10',
    'List artwork_1, artwork_2 for 0.5 ETH',
  ];
  for (const ex of examples) {
    console.log(`Input:  ${ex}`);
    const ptb = translate(ex);
    console.log(`  PTB: ${JSON.stringify(ptb.operations.length)} operations`);
    console.log();
  }
}
