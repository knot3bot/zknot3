// Core types for Creator³ Agent SDK

export type Address = string; // hex-encoded 32-byte address
export type ObjectID = string; // hex-encoded 32-byte object ID

export interface KeyPair {
  publicKey: Uint8Array;  // 32 bytes
  secretKey: Uint8Array;  // 32 bytes
}

export interface AgentInfo {
  id: ObjectID;
  owner: Address;
  name: string;
  capabilities: Capability[];
  endpointUrl: string;
  reputationScore: number;
  totalTasksCompleted: number;
  totalRewardsEarned: number;
  createdAt: number;
  isActive: boolean;
}

export type Capability =
  | 'image-gen'
  | 'text-gen'
  | 'music-gen'
  | 'video-gen'
  | 'code-gen'
  | 'data-analysis'
  | 'design'
  | 'translation'
  | string; // custom capability

export interface PTB {
  operations: Operation[];
}

export type Operation =
  | { MoveCall: { module: string; function: string; args: any[] } }
  | { TransferObjects: { objects: ObjectID[]; recipient: Address } }
  | { SplitCoins: { coinId: ObjectID; amounts: number[] } }
  | { MergeCoins: { coinIds: ObjectID[] } }
  | { Publish: { modules: Uint8Array[] } }
  | { MakeMoveVec: { typeTag: string; elements: ObjectID[] } };

export interface License {
  type: 'CC0' | 'CC-BY' | 'CC-BY-SA' | 'MIT' | 'AllRightsReserved' | 'Custom';
  terms?: string;
  royaltyBps: number; // basis points, 500 = 5%
  expirationSecs: number; // 0 = perpetual
}

export interface TxReceipt {
  digest: string;
  status: 'success' | 'out_of_gas' | 'resource_error';
  gasUsed: number;
  events: Event[];
}

export interface Event {
  type: string;
  payload: Uint8Array;
}
