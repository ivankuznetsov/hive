---
slug: build-a-patrol-native-self-260829-cc36
created_at: 2026-08-29T13:55:00Z
original_text: |
  Build a Patrol-native self-learning skills and self-improvement harness
  
  Reference paper: WikiSkill: Compiling Agent Experience into Persistent Knowledge for Skill Evolution
  - arXiv: https://arxiv.org/abs/2608.27454
  - PDF: https://arxiv.org/pdf/2608.27454
  
  Context:
  Hive already owns two mature discovery controllers that should become the foundation of skill evolution rather than building a separate collector. Ordinary Patrol provides bounded snapshot-pinned evidence discovery, atomic evidence admission, semantic deduplication, deterministic routing, quotas, durable findings, verified repair loops, and review handoff. Architecture Patrol provides durable cross-boundary thesis jobs, rotating scopes, post-merge analysis, deduplication, explicit dispositions, routing, and audited history. Reuse those mechanisms to compile repeated agent experience into persistent llm-wiki knowledge and evaluated repo-local skill candidates.
  
  Desired architecture:
  - Ordinary Patrol is the local empirical signal lane: identify recurring execution failures, review findings, tool misuse, retry patterns, and successful corrective patterns from bounded eligible Hive artifacts.
  - Architecture Patrol is the synthesis lane: cluster signals across tasks/components, distinguish code defects from instruction or workflow defects, and produce evidence-backed skill-evolution theses.
  - llm-wiki is the provenance-backed knowledge substrate for accepted patterns, contradictions, freshness, scope, and rejected-candidate impact.
  - A Hive-owned evolution controller compiles one thesis into one immutable repo-local skill candidate, runs blind held-out evaluation against active and fixed baselines, records results, and proposes an active-version transition.
  - Activation is never automatic and never routes through agent-plugins. It requires explicit human approval through a Hive-owned compare-and-swap transition with smoke verification and rollback.
  - Rejected candidates remain durable evidence and feed future patrol/architecture-patrol synthesis without contaminating held-out evaluation.
  
  Acceptance criteria:
  - Reuse shared Patrol and Architecture Patrol primitives for snapshots, source identity, evidence admission, deduplication, scoring or disposition, quotas, leases, durable jobs, routing, and audit records; do not fork equivalent infrastructure.
  - Define typed signal, pattern/thesis, candidate, evaluation, decision, activation, and rollback contracts with stable IDs and digests.
  - Add a target taxonomy that can route findings to code-fix, architecture thesis, knowledge-only update, or skill-evolution candidate without conflating these lanes.
  - Ingest only bounded allowlisted Hive artifacts; exclude secrets, private conversations, raw unrelated transcripts, untracked or ignored files, and evaluator holdouts.
  - Preserve train/development versus held-out isolation; proposer and worker cannot access hidden cases, rubrics, answers, or prior per-case results.
  - Evaluate candidate versus current active version and a fixed baseline on immutable manifests; correctness and safety failures veto activation.
  - Require explicit human approval for Hive-owned activation; no agent-plugins dependency or path.
  - Retain accepted and rejected candidate identity, evidence, metrics, evaluator provenance, decision, impact, reason, and rollback lineage.
  - Make cycles resumable and idempotent under crashes, retries, duplicate signals, default-branch movement, and concurrent daemon activity.
  - Share the existing daily patrol ceiling and provider-native budget guards; expose clear status and hold reasons.
  - Add end-to-end tests covering repeated-signal synthesis, deduplication, knowledge-only disposition, candidate proposal, blind evaluation, rejection, approval, activation, smoke-failure rollback, and recovery.
  - Document how normal Patrol, Architecture Patrol, llm-wiki, and the skill-evolution harness interact, including ownership boundaries and operator controls.
---

# build-a-patrol-native-self-260829-cc36

Build a Patrol-native self-learning skills and self-improvement harness

Reference paper: WikiSkill: Compiling Agent Experience into Persistent Knowledge for Skill Evolution
- arXiv: https://arxiv.org/abs/2608.27454
- PDF: https://arxiv.org/pdf/2608.27454

Context:
Hive already owns two mature discovery controllers that should become the foundation of skill evolution rather than building a separate collector. Ordinary Patrol provides bounded snapshot-pinned evidence discovery, atomic evidence admission, semantic deduplication, deterministic routing, quotas, durable findings, verified repair loops, and review handoff. Architecture Patrol provides durable cross-boundary thesis jobs, rotating scopes, post-merge analysis, deduplication, explicit dispositions, routing, and audited history. Reuse those mechanisms to compile repeated agent experience into persistent llm-wiki knowledge and evaluated repo-local skill candidates.

Desired architecture:
- Ordinary Patrol is the local empirical signal lane: identify recurring execution failures, review findings, tool misuse, retry patterns, and successful corrective patterns from bounded eligible Hive artifacts.
- Architecture Patrol is the synthesis lane: cluster signals across tasks/components, distinguish code defects from instruction or workflow defects, and produce evidence-backed skill-evolution theses.
- llm-wiki is the provenance-backed knowledge substrate for accepted patterns, contradictions, freshness, scope, and rejected-candidate impact.
- A Hive-owned evolution controller compiles one thesis into one immutable repo-local skill candidate, runs blind held-out evaluation against active and fixed baselines, records results, and proposes an active-version transition.
- Activation is never automatic and never routes through agent-plugins. It requires explicit human approval through a Hive-owned compare-and-swap transition with smoke verification and rollback.
- Rejected candidates remain durable evidence and feed future patrol/architecture-patrol synthesis without contaminating held-out evaluation.

Acceptance criteria:
- Reuse shared Patrol and Architecture Patrol primitives for snapshots, source identity, evidence admission, deduplication, scoring or disposition, quotas, leases, durable jobs, routing, and audit records; do not fork equivalent infrastructure.
- Define typed signal, pattern/thesis, candidate, evaluation, decision, activation, and rollback contracts with stable IDs and digests.
- Add a target taxonomy that can route findings to code-fix, architecture thesis, knowledge-only update, or skill-evolution candidate without conflating these lanes.
- Ingest only bounded allowlisted Hive artifacts; exclude secrets, private conversations, raw unrelated transcripts, untracked or ignored files, and evaluator holdouts.
- Preserve train/development versus held-out isolation; proposer and worker cannot access hidden cases, rubrics, answers, or prior per-case results.
- Evaluate candidate versus current active version and a fixed baseline on immutable manifests; correctness and safety failures veto activation.
- Require explicit human approval for Hive-owned activation; no agent-plugins dependency or path.
- Retain accepted and rejected candidate identity, evidence, metrics, evaluator provenance, decision, impact, reason, and rollback lineage.
- Make cycles resumable and idempotent under crashes, retries, duplicate signals, default-branch movement, and concurrent daemon activity.
- Share the existing daily patrol ceiling and provider-native budget guards; expose clear status and hold reasons.
- Add end-to-end tests covering repeated-signal synthesis, deduplication, knowledge-only disposition, candidate proposal, blind evaluation, rejection, approval, activation, smoke-failure rollback, and recovery.
- Document how normal Patrol, Architecture Patrol, llm-wiki, and the skill-evolution harness interact, including ownership boundaries and operator controls.

<!-- WAITING -->
