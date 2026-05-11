// AgentRegistryClient — On-chain agent discovery
import type { AgentInfo, Capability } from './types';

export class AgentRegistryClient {
  private nodeUrl: string;

  constructor(nodeUrl: string = 'http://localhost:9003') {
    this.nodeUrl = nodeUrl;
  }

  /** Register a new agent on-chain. */
  async register(
    owner: string, name: string, capabilities: Capability[], endpointUrl: string,
  ): Promise<string> {
    const body = JSON.stringify({
      jsonrpc: '2.0',
      method: 'knot3_registerAgent',
      params: [{ owner, name, capabilities, endpointUrl }],
      id: 1,
    });
    const rsp = await fetch(`${this.nodeUrl}/rpc`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
    });
    const data = await rsp.json();
    return data.result?.agentId ?? '';
  }

  /** Discover agents by capability, sorted by reputation. */
  async discover(capability: Capability): Promise<AgentInfo[]> {
    const body = JSON.stringify({
      jsonrpc: '2.0', method: 'knot3_discoverAgents',
      params: [{ capability }], id: 1,
    });
    const rsp = await fetch(`${this.nodeUrl}/rpc`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
    });
    const data = await rsp.json();
    return data.result?.agents ?? [];
  }

  /** Update agent reputation after task completion. */
  async updateReputation(agentId: string, delta: number, reward: number): Promise<void> {
    const body = JSON.stringify({
      jsonrpc: '2.0', method: 'knot3_agentReputation',
      params: [{ agentId, scoreDelta: delta, rewardAmount: reward }], id: 1,
    });
    await fetch(`${this.nodeUrl}/rpc`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
    });
  }

  /** List all registered agents. */
  async listAll(): Promise<AgentInfo[]> {
    const body = JSON.stringify({
      jsonrpc: '2.0', method: 'knot3_listAgents', params: [], id: 1,
    });
    const rsp = await fetch(`${this.nodeUrl}/rpc`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
    });
    const data = await rsp.json();
    return data.result?.agents ?? [];
  }
}
