// PTBBuilder — Programmatic Programmable Transaction Block construction
import type { PTB, Operation, ObjectID, Address } from './types';
import type { AgentWallet } from './wallet';

export class PTBBuilder {
  private operations: Operation[] = [];
  private sponsorAddress: string | null = null;

  /** Add a Move call operation. */
  moveCall(module: string, func: string, args: any[]): this {
    this.operations.push({ MoveCall: { module, function: func, args } });
    return this;
  }

  /** Transfer objects to a recipient. */
  transferObjects(objects: ObjectID[], recipient: Address): this {
    this.operations.push({ TransferObjects: { objects, recipient } });
    return this;
  }

  /** Split a coin into multiple amounts. */
  splitCoins(coinId: ObjectID, amounts: number[]): this {
    this.operations.push({ SplitCoins: { coinId, amounts } });
    return this;
  }

  /** Merge multiple coins into one. */
  mergeCoins(coinIds: ObjectID[]): this {
    this.operations.push({ MergeCoins: { coinIds } });
    return this;
  }

  /** Publish Move modules. */
  publish(modules: Uint8Array[]): this {
    this.operations.push({ Publish: { modules } });
    return this;
  }

  /** Build and return the PTB. */
  build(): PTB {
    return { operations: [...this.operations] };
  }

  /** Set a gas sponsor for this PTB. */
  sponsoredBy(sponsorAddress: Address): this {
    this.sponsorAddress = sponsorAddress;
    return this;
  }

  /** Submit the PTB with gas sponsorship. */
  async submitWithSponsor(wallet: AgentWallet, nodeUrl: string = 'http://localhost:9003'): Promise<any> {
    const ptb = this.build();
    const tx = {
      sender: wallet.getAddress(),
      payer: this.sponsorAddress,
      operations: ptb.operations,
      gasBudget: 1000000,
      sequence: Date.now(), // simplified
      bypassConsensus: ptb.operations.length === 1, // Fast Path for single ops
    };
    return wallet.signAndSubmit(tx, nodeUrl);
  }

  /** Submit without sponsorship. */
  async submit(wallet: AgentWallet, nodeUrl: string = 'http://localhost:9003'): Promise<any> {
    return this.submitWithSponsor(wallet, nodeUrl);
  }

  /** Reset builder for a new PTB. */
  reset(): this {
    this.operations = [];
    this.sponsorAddress = null;
    return this;
  }
}

/** Quick PTB creation helper. */
export function ptb(): PTBBuilder {
  return new PTBBuilder();
}
