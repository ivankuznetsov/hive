# Keyed command result proof matrix

This matrix records the local evidence for durable command output and names the
remaining consumer boundary honestly. It does not promote adapter-level tests
into a live hivedev C4 result.

## Shared result contract

`CommandOperation` performs lookup before mutable task resolution, persists the
typed result and public receipt before output, and reconstructs replay output
from the saved template. Its tests exercise restart replay, conflict without a
second effect, unresolved interruption, display-only format changes, answer
binding reconstruction, and byte-identical act observation-token expansion.
The answer binding and observation token are reconstructed from safe frozen
fields; literal token bytes are not used as durable effect evidence.

The store tests independently close and reopen SQLite before replay, reject a
changed request or principal without result disclosure, return active and
unresolved typed outcomes, fence stale generations, and keep terminal replay
available while new namespace intake is disabled.

## Supported boundary matrix

| Boundary | Adapter/contract evidence | Result/replay evidence |
| --- | --- | --- |
| `new` | `Commands::New` constructs a `CommandOperation`; base-only storage fails before task creation | `test/integration/new_idempotency_test.rb` runs the public command, loses/retries output after movement, proves one creation and validates conflict status 20 |
| answer write | `CommandMutations` freezes the answer binding and `Commands::Answer` exposes the operation boundary | `CommandOperationTest#test_answer_replay_reconstructs_response_binding_not_request_binding`; answer command tests retain ordinary binding/freshness behavior |
| `approve` | Catalog and adapter tests freeze selector, direction, observation and task identity | receipt adapter contract plus approval-operation tests preserve the domain operation identity across retries |
| descriptor-backed stage action | replay lookup is outside durable worker admission; dispatch context carries the receipt generation | stage-action tests cover one-envelope durable success/failure and expired worker output; lifecycle tests cover restart/SIGKILL |
| `act` | keyed success stays un-emitted until receipt finalization | act tests plus `test_observation_token_template_reconstructs_byte_identical_success` |
| targeted `archive`/closure | catalog distinguishes listing from mutation and routes non-closure errors through stage-action schema | receipt contract test emits the keyed archive receipt; schema tests retain the optional closure `command_receipt` without changing required closure fields |
| terminal-only prune | the only keyed maintenance mode; fixed candidates and outcomes are stored in the maintenance batch | `CommandOperationTest#test_interrupted_keyed_prune_resumes_before_replay` and maintenance restart/batch tests |

The adapter rows above prove the shared boundary and their command-specific
serialization. A live C4 command matrix is unavailable and remains a consumer
follow-up; see `docs/command-receipts-c4-comparison.md`.

## Typed outcomes

The closed command schemas and schema registry admit and validate:

- status 20, `command_conflict`, for changed input/principal under a claimed key;
- status 21, `command_in_progress`, for an actively owned identical request;
- status 22, `command_unresolved_pending`, for non-terminal ambiguity; and
- status 22, `command_original_result_unavailable`, for a terminal explicit
  settlement. JSON state/reason, not status 22 alone, distinguishes the latter.

The public `new` integration test validates the emitted status-20 envelope.
Store/operation tests execute statuses 21 and 22 and receipt-command tests
validate their envelopes. Schema-file tests validate the full reason vocabulary
for every supported closed schema. This is local terminal behavior evidence;
there is no claim that every row was exercised through an external C4 binary.

Focused verification command:

```sh
bin/test test/unit/command_mutations_test.rb \
  test/unit/command_operation_test.rb \
  test/unit/command_receipt_store_test.rb \
  test/unit/command_receipt_contract_test.rb \
  test/unit/schema_files_test.rb \
  test/unit/commands/new_command_receipt_test.rb \
  test/unit/commands/answer_test.rb \
  test/unit/commands/approve_test.rb \
  test/unit/commands/stage_action_test.rb \
  test/unit/commands/act_test.rb \
  test/integration/new_idempotency_test.rb
```

The 2026-09-28 combined receipt/dispatch/maintenance focused run, including
this matrix, completed 928 runs and 4,581 assertions with no failures, errors,
or skips.
