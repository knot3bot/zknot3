# Creator³ — AI Agent Capability Roadmap

## Current State (✅ Done)

| Capability | Implementation |
|------------|---------------|
| Identity Bridge | zkLogin (OAuth/OIDC → on-chain address) |
| Gas-Free Execution | Gas Station allowlist + payer != sender |
| Atomic Multi-Step | PTB 6 operation types |
| Behavior Preview | dryRunTransaction |
| Creative Randomness | VRF (ECVRF RFC 9381) |
| Creation License | License model (6 types + royalty) |
| Provenance | parent/child/fork reference graph |
| Standard Library | Coin.transfer/Transfer/Event.emit |

---

## Phase 1: Agent SDK (P0)

### Architecture

```
zknot3-agent-sdk (TypeScript)
├── AgentWallet          — Key management + zkLogin auth
├── PTBBuilder           — Programmatic PTB construction
├── DryRunner            — Pre-submit simulation
├── EventSubscriber      — WebSocket chain event subscription
├── GasEstimator         — Gas cost prediction
└── LicenseAttacher      — Auto-attach license to creations
```

### AgentWallet

```typescript
class AgentWallet {
  // OAuth login → derive on-chain address
  static async fromOAuth(provider: 'google'|'apple'|'github', jwt: string): AgentWallet
  
  // Generate ephemeral keypair for tx signing
  async generateEphemeralKey(): KeyPair
  
  // Sign and submit transaction
  async signAndSubmit(tx: Transaction): TxReceipt
  
  // Get wallet address
  getAddress(): string  // derived from issuer + subject + ephemeral_pubkey
}
```

### PTBBuilder

```typescript
class PTBBuilder {
  // Add a Move call
  moveCall(module: string, func: string, args: any[]): this
  
  // Transfer objects
  transferObjects(objects: string[], recipient: string): this
  
  // Split coins (for royalties)
  splitCoins(coinId: string, amounts: number[]): this
  
  // Publish modules
  publish(modules: Uint8Array[]): this
  
  // Build and return the PTB
  build(): PTB
  
  // Submit with sponsor
  submitWithSponsor(wallet: AgentWallet, sponsor: string): Promise<TxReceipt>
}
```

---

## Phase 2: Agent Registry (P0)

### On-Chain Contract

```move
module creator3::agent_registry {
    struct Agent has key, store {
        id: UID,
        owner: address,
        name: string,
        capabilities: vector<string>,  // ["image-gen", "text-gen", "music-gen"]
        endpoint_url: string,          // API endpoint for agent calls
        reputation_score: u64,
        total_tasks_completed: u64,
        total_rewards_earned: u64,
        created_at: u64,
        is_active: bool,
    }

    // Register a new agent
    public fun register(
        name: string,
        capabilities: vector<string>,
        endpoint_url: string
    ): Agent

    // Update reputation after task completion
    public fun updateReputation(
        agent_id: UID,
        score_delta: i64
    )

    // Discover agents by capability
    public fun discoverByCapability(
        capability: string
    ): vector<AgentInfo>

    // Deactivate agent
    public fun deactivate(agent_id: UID)
}
```

### API

```
POST /rpc  knot3_discoverAgents  → [AgentInfo]
POST /rpc  knot3_registerAgent   → AgentID
POST /rpc  knot3_agentReputation → success
```

---

## Phase 3: NL → PTB Translation (P1)

### Flow

```
Human Natural Language
    │
    ▼
AI Model (GPT-4/Claude)
    │  Parse intent → structured actions
    ▼
PTBBuilder
    │  Build atomic operations
    ▼
dryRunTransaction  ← verify
    │
    ▼
Submit PTB  ← on-chain execution
```

### Example

```
Input:  "Generate 100 cyberpunk artworks with CC-BY license,
         list them at 0.1 ETH each, split royalties 70/20/10
         between creator/curator/platform"

Output PTB:
  [0] MoveCall(generate_artwork, {style:"cyberpunk", count:100})
  [1] Publish([artwork_module])
  [2] MoveCall(attach_license, {type: CC_BY, royalty_bps: 500})
  [3] MoveCall(list_batch, {price: 0.1, currency: ETH})
  [4] SplitCoins(sale_coin, [70, 20, 10])
  [5] ConfigureRoyalty(creator:70%, curator:20%, platform:10%)
```

---

## Phase 4: Creation Marketplace (P1)

### Contract

```move
module creator3::marketplace {
    struct Listing has key, store {
        id: UID,
        creation_id: UID,
        seller: address,
        price: u64,
        currency: string,
        license: License,
        royalty_bps: u16,
        created_at: u64,
        is_active: bool,
    }

    struct Bid has key, store {
        id: UID,
        listing_id: UID,
        bidder: address,
        amount: u64,
        expires_at: u64,
    }

    public fun list(creation_id, price, currency): Listing
    public fun buy(listing_id): (Creation, Coin)
    public fun bid(listing_id, amount, expiry): Bid
    public fun acceptBid(bid_id): (Creation, Coin)
}
```

---

## Phase 5: Agent-to-Agent Communication (P2)

### Protocol

```
AgentMessage {
    sender: AgentID,
    recipient: AgentID,
    message_type: TaskRequest | TaskAccept | TaskComplete | Feedback,
    payload: PTB,          // delegated execution
    reward: Coin,          // payment for task
    deadline: u64,         // epoch timestamp
}
```

### Workflow

```
Human ──→ AgentA: "Design a logo for my project"
              │
AgentA ──→ AgentB: TaskRequest(logo_design, reward: 100)
              │
AgentB ──→ AgentA: TaskComplete(logo_creation_id)
              │
AgentA ──→ Human: Present result
              │
Human ──→ AgentA: Feedback(approved, tip: 50)
              │
AgentA ──→ AgentB: Reward(100 + 50 tip)
```

---

## Implementation Priority

| Phase | Item | Effort | Impact | Status |
|-------|------|--------|--------|--------|
| P0 | Agent SDK (TypeScript) | 3 days | Agent dev barrier ↓ | ← Current |
| P0 | Agent Registry (Move) | 2 days | Discoverable trust | ← Current |
| P1 | NL→PTB Translation | 5 days | Natural language on-chain | Planned |
| P1 | Creation Marketplace | 3 days | Monetization loop | Planned |
| P2 | Agent-to-Agent Comm | 3 days | Multi-agent swarm | Planned |
| P2 | IPFS Integration | 2 days | Large content storage | Planned |

---

*Creator³ — Three-Source Integration, Human-AI Co-Creation, Digital Life Evolution*
