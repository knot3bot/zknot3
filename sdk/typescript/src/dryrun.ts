// DryRunner — Pre-submit transaction simulation
import type { TxReceipt } from './types';

export class DryRunner {
  private nodeUrl: string;

  constructor(nodeUrl: string = 'http://localhost:9003') {
    this.nodeUrl = nodeUrl;
  }

  /** Simulate a PTB without committing state changes. */
  async simulate(ptb: any): Promise<TxReceipt & { effects: string[] }> {
    const body = JSON.stringify({
      jsonrpc: '2.0',
      method: 'knot3_dryRunTransaction',
      params: [ptb],
      id: 1,
    });

    const response = await fetch(`${this.nodeUrl}/rpc`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    });
    const result = await response.json();
    return {
      digest: result.digest,
      status: result.status,
      gasUsed: result.gasUsed,
      events: result.events || [],
      effects: result.outputObjects || [],
    };
  }
}
