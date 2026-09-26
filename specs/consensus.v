(* zknot3 Formal Verification Specifications *)
(* Version: 0.3.0 — machine-checked with the Rocq Prover (Coq) 9.3 *)
(* Compile: coqc specs/consensus.v *)
(* *)
(* Verified here (Qed, no axioms): *)
(*   - quorum_intersection : two >2/3 quorums overlap by >1/3 stake *)
(*   - commit_safety       : conflicting commits share honest stake *)
(*   - bft_honest_bound    : n >= 3f+1  =>  honest >= 2f+1 *)
(*   - precedes_irrefl / precedes_trans : version-lattice strict order *)
(* *)
(* Environment assumptions (Parameter, NOT proved here): the ObjectID hash *)
(* is modelled abstractly; injectivity of the concrete BLAKE3 encoding is *)
(* an assumption of the deployment, not a theorem of this file. *)
(* The exhaustively-checked executable counterparts of these properties *)
(* live in tools/formal/proofs.zig (`zig build test-formal`). *)

Require Import ZArith.
Require Import List.
Require Import Lia.
Import ListNotations.

Open Scope Z_scope.

(** *********************** OBJECT MODEL *********************** *)
Module ObjectID.
  (* Abstract identity type with an opaque hash. Injectivity is stated as
     an explicit deployment assumption, not a proof obligation here. *)
  Parameter t : Type.
  Parameter hash : t -> t.
  Axiom hash_injective : forall a b : t, hash a = hash b -> a = b.
End ObjectID.

Module Version.
  Record version_t := Version_mk {
    v_seq : Z;
    v_causal : ObjectID.t
  }.

  Definition precedes (a b : version_t) : Prop :=
    v_seq a < v_seq b /\ v_causal a = v_causal b.

  Theorem precedes_irrefl : forall a : version_t, ~ precedes a a.
  Proof.
    intros a [Hseq _]; lia.
  Qed.

  Theorem precedes_trans : forall a b c : version_t,
    precedes a b -> precedes b c -> precedes a c.
  Proof.
    intros a b c [H1 H2] [H3 H4]; split; [lia | congruence].
  Qed.
End Version.

Module Ownership.
  Inductive own_tag := OwnOwned | OwnShared | OwnImmutable.
  Record ownership_t := Ownership_mk { o_tag : own_tag; o_owner : Z }.
  Definition zero_address : Z := 0.

  (* Owned objects must have a non-zero owner; this is a well-formedness
     predicate on states, checked where states are constructed. *)
  Definition well_formed (o : ownership_t) : Prop :=
    match o_tag o with
    | OwnOwned => o_owner o <> zero_address
    | _ => True
    end.
End Ownership.

(** *********************** CONSENSUS *********************** *)
Module Quorum.
  Definition stake := Z.

  Fixpoint sum_stakes (vals : list stake) : Z :=
    match vals with nil => 0 | v :: vs => v + sum_stakes vs end.

  (* Quorum defined without division: more than 2/3 of total. *)
  Definition is_quorum (q total : stake) : Prop := 3 * q > 2 * total.

  (* BFT condition: at most f of total stake is Byzantine. *)
  Definition bft_bound (total f : stake) : Prop := total >= 3 * f + 1.

  Theorem bft_honest_bound : forall total f : stake,
    bft_bound total f -> total - f >= 2 * f + 1.
  Proof.
    intros total f H; unfold bft_bound in H; lia.
  Qed.

  (* Quorum intersection: two quorums overlap by strictly more than 1/3 of
     total stake. Since |S1 ∩ S2| >= |S1| + |S2| - |U|, a pair of quorums
     in a universe of total stake must share > total/3. *)
  Theorem quorum_intersection : forall q1 q2 total : stake,
    total > 0 ->
    is_quorum q1 total -> is_quorum q2 total ->
    3 * (q1 + q2 - total) > total.
  Proof.
    intros q1 q2 total Hpos H1 H2; unfold is_quorum in *; lia.
  Qed.

  (* Commit safety: two conflicting commits each need a quorum; by
     intersection the shared stake exceeds the Byzantine budget f when
     total >= 3f+1, so some honest validator double-voted — excluded. *)
  Theorem commit_safety : forall q1 q2 total f : stake,
    total > 0 ->
    bft_bound total f ->
    is_quorum q1 total -> is_quorum q2 total ->
    q1 + q2 - total > f.
  Proof.
    (* overlap q1+q2-total exceeds f directly from the three bounds:
       3*q1 > 2*total, 3*q2 > 2*total, total >= 3*f+1. *)
    intros q1 q2 total f Hpos Hbft H1 H2;
    unfold is_quorum, bft_bound in *; lia.
  Qed.
End Quorum.

Module Mysticeti.
  Import Quorum.

  Record block_t := Block_mk {
    b_id : ObjectID.t;
    b_round : Z;
    b_votes : list stake;
    b_ancestors : list ObjectID.t
  }.

  (* A block is committed when its accumulated vote stake is a quorum
     under the given total stake. *)
  Definition committed (b : block_t) (total : stake) : Prop :=
    is_quorum (sum_stakes (b_votes b)) total.

  (* DAG integrity as a well-formedness predicate: ancestors must live in
     strictly earlier rounds. *)
  Definition dag_well_formed (b1 b2 : block_t) : Prop :=
    In (b_id b2) (b_ancestors b1) -> b_round b2 < b_round b1.

  (* Two conflicting blocks (different ids, same round) cannot both commit
     without intersecting quorums — the arithmetic content is exactly
     Quorum.commit_safety. *)
  Theorem no_conflicting_commits : forall (b1 b2 : block_t) (total f : stake),
    total > 0 ->
    bft_bound total f ->
    b_id b1 <> b_id b2 ->
    committed b1 total ->
    committed b2 total ->
    sum_stakes (b_votes b1) + sum_stakes (b_votes b2) - total > f.
  Proof.
    intros b1 b2 total f Hpos Hbft Hne Hc1 Hc2.
    unfold committed in *.
    exact (commit_safety _ _ _ f Hpos Hbft Hc1 Hc2).
  Qed.
End Mysticeti.

(** *********************** LINEAR TYPES *********************** *)
Module Resource.
  Inductive res_tag := ResCoin | ResNFT | ResSharedObj.
  Record resource_t := Resource_mk { r_id : ObjectID.t; r_tag : res_tag; r_used : bool }.

  (* Linear-use discipline as a predicate over resource lists: a resource
     appears at most once, so it cannot be both moved and retained. *)
  Fixpoint no_dup_ids (rs : list resource_t) : Prop :=
    match rs with
    | nil => True
    | r :: rest => ~ (exists r', In r' rest /\ r_id r' = r_id r) /\ no_dup_ids rest
    end.

  (* The linear discipline: a resource id introduced at the head never
     reappears later in the list — ids cannot be double-owned. *)
  Theorem no_double_use : forall (rs : list resource_t) (r r' : resource_t),
    no_dup_ids (r :: rs) -> In r' rs -> r_id r' <> r_id r.
  Proof.
    intros rs r r' [Hid _] Hin Heq.
    apply Hid; exists r'; split; assumption.
  Qed.
End Resource.

(** *********************** SYSTEM *********************** *)
Module System.
  Record system_state := System_mk {
    s_form : list ObjectID.t;
    s_property : list Resource.resource_t;
    s_metric : list Z
  }.

  Definition consistent (s : system_state) : Prop := Resource.no_dup_ids (s_property s).

  (* Consistency is exactly the resource no-duplicate-id discipline. *)
  Theorem consistent_iff : forall s : system_state,
    consistent s <-> Resource.no_dup_ids (s_property s).
  Proof.
    intros s; reflexivity.
  Qed.
End System.
