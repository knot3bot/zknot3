/-
zknot3 Formal Verification Specifications
Version 0.3.0 — machine-checked with Lean 4 (v4.34.1)
Compile: lake env lean specs/consensus.lean   (or: lean specs/consensus.lean)

Verified here (no `axiom`, no `sorry`):
  - precedes_irrefl / precedes_trans : version-lattice strict partial order
  - quorum_intersection / commit_safety : BFT commit-safety arithmetic
  - bft_honest_bound : n >= 3f+1 => honest >= 2f+1
  - linear_no_dup_preserved : linear resource discipline under Step/Star

Environment assumptions (Parameter, NOT proved here): the ObjectID hash is
modelled abstractly; injectivity of the concrete BLAKE3 encoding is a
deployment assumption, not a theorem of this file. The Coq counterpart
(specs/consensus.v) and the exhaustively-checked executable proofs
(tools/formal/proofs.zig) cover the same properties.
-/

-- ObjectID as BLAKE3 256-bit hash
structure ObjectID where
  bytes : ByteArray
  deriving BEq

-- Version lattice with sequence and causal hash
structure Version where
  seq : Nat
  causal : ObjectID

def precedes (a b : Version) : Prop :=
  a.seq < b.seq ∧ a.causal = b.causal

theorem precedes_irrefl (a : Version) : ¬ precedes a a := by
  intro ⟨h, _⟩
  exact Nat.lt_irrefl _ h

theorem precedes_trans (a b c : Version)
    (hab : precedes a b) (hbc : precedes b c) : precedes a c :=
  ⟨Nat.lt_trans hab.1 hbc.1, hab.2.trans hbc.2⟩

-- Ownership quotient set
inductive Ownership where
  | Owned (owner : Nat)
  | Shared
  | Immutable

/- Consensus and BFT safety -/

-- Quorum defined without division: strictly more than 2/3 of total.
def IsQuorum (q total : Nat) : Prop := 3 * q > 2 * total

def BftBound (total f : Nat) : Prop := total ≥ 3 * f + 1

theorem bft_honest_bound (total f : Nat) (h : BftBound total f) :
    total - f ≥ 2 * f + 1 := by
  unfold BftBound at h; omega

/- Quorum intersection: two quorums overlap by strictly more than 1/3 of
   total stake, since |S1 ∩ S2| ≥ |S1| + |S2| − |U|. -/
theorem quorum_intersection (q1 q2 total : Nat)
    (h1 : IsQuorum q1 total) (h2 : IsQuorum q2 total) :
    3 * (q1 + q2 - total) > total := by
  unfold IsQuorum at h1 h2; omega

/- Commit safety: two conflicting commits each need a quorum; their
   overlap exceeds the Byzantine budget f under the BFT bound, so some
   honest validator must have voted for both — excluded by slashing. -/
theorem commit_safety (q1 q2 total f : Nat)
    (hbft : BftBound total f)
    (h1 : IsQuorum q1 total) (h2 : IsQuorum q2 total) :
    q1 + q2 - total > f := by
  unfold IsQuorum BftBound at *; omega

/- Linear type system for Move-style resources -/

inductive ResourceTag where
  | Coin | NFT | SharedObj
  deriving BEq

structure Resource where
  id : ObjectID
  tag : ResourceTag
  used : Bool
  deriving BEq

/- VM state: resources in scope are either "live" (usable) or already
   consumed by a linear operation. -/
structure VMState where
  live : List Resource
  consumed : List ObjectID

inductive Step : VMState → VMState → Prop where
  /- Consuming (moving) resources only removes entries from the live set. -/
  | move : ∀ (s s' : VMState),
      s'.live.Sublist s.live →
      Step s s'
  /- Publishing a module introduces exactly one resource with a fresh id. -/
  | publish : ∀ (s s' : VMState) (r : Resource),
      s'.live = r :: s.live →
      r.id ∉ s.live.map Resource.id →
      Step s s'

/-- Reflexive-transitive closure of Step. -/
inductive Star : VMState → VMState → Prop where
  | refl : ∀ (s : VMState), Star s s
  | step : ∀ (s₁ s₂ s₃ : VMState), Step s₁ s₂ → Star s₂ s₃ → Star s₁ s₃

/-- Linear discipline: live resource ids are pairwise distinct
    (each resource exists at most once — no duplication, no retention). -/
def NoDupIds (l : List Resource) : Prop :=
  (l.map Resource.id).Pairwise (· ≠ ·)

theorem noDupIds_cons {r : Resource} {rs : List Resource} :
    NoDupIds (r :: rs) ↔ r.id ∉ rs.map Resource.id ∧ NoDupIds rs := by
  show (r.id :: rs.map Resource.id).Pairwise (· ≠ ·) ↔ _
  rw [List.pairwise_cons]
  constructor
  · intro ⟨hall, hpw⟩
    exact ⟨fun hmem => hall _ hmem rfl, hpw⟩
  · intro ⟨hmem, hpw⟩
    exact ⟨fun a' ha => fun heq => hmem (heq ▸ ha), hpw⟩

/-- Consumption (sublist) preserves the linear discipline. -/
theorem sublist_preserves_nodup {l₁ l₂ : List Resource}
    (hsub : l₁.Sublist l₂) (hnd : NoDupIds l₂) : NoDupIds l₁ :=
  List.Pairwise.sublist (List.Sublist.map Resource.id hsub) hnd

/-- Publishing a fresh id preserves the linear discipline. -/
theorem publish_preserves_nodup {rs : List Resource} {r : Resource}
    (hid : r.id ∉ rs.map Resource.id) (hnd : NoDupIds rs) :
    NoDupIds (r :: rs) :=
  List.pairwise_cons.2 ⟨fun _ ha => fun heq => hid (heq ▸ ha), hnd⟩

/-- Linear safety: across any run of VM steps, no resource id is
    duplicated — resources cannot be double-owned. -/
theorem linear_no_dup_preserved (s s' : VMState)
    (hrun : Star s s') (hinit : NoDupIds s.live) :
    NoDupIds s'.live := by
  induction hrun with
  | refl => exact hinit
  | @step s₁ s₂ _ hstep _ ih =>
    cases hstep with
    | move hsub => exact ih (sublist_preserves_nodup hsub hinit)
    | publish r heq hid =>
      have hnd2 : NoDupIds s₂.live := by
        rw [heq]; exact publish_preserves_nodup hid hinit
      exact ih hnd2

-- Machine-checked audit: every theorem above must depend on no axioms.
#print axioms precedes_irrefl
#print axioms precedes_trans
#print axioms bft_honest_bound
#print axioms quorum_intersection
#print axioms commit_safety
#print axioms linear_no_dup_preserved
