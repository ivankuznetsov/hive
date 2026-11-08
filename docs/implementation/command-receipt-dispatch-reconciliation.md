# Command receipt dispatch and reconciliation proof

This receipt traces the three shipped durable-dispatch callers through the
shared command lifecycle. It is local producer evidence, not a claim that the
unavailable hivedev C4 consumer has adopted the contract.

## One shared lifecycle

1. The command receipt is reserved and its generation and frozen request
   fingerprint are persisted before an effect is prepared.
2. `CommandDispatchLifecycle` acquires the intent pin with the caller-declared
   absolute retry horizon before enqueue. The transport id is derived from the
   receipt/effect/ordinal; it is not the caller key.
3. `DispatchRepository` writes the dispatch request and private command context
   atomically. The context carries receipt id, generation, principal, request
   fingerprint, effect id, ordinal, and retry horizon.
4. A restarted consumer restores that context, revalidates the process-bound
   capability and task ownership generation, and reacquires the same pin
   identity. Missing or changed context fails closed instead of falling back to
   unkeyed work.
5. Terminal dispatch acknowledgement is recorded before the pin is closed.
   Worker success becomes caller-visible only after the original command
   receipt contains its durable typed result.
6. A successor is allocated by the store in one transaction from the current
   eligible predecessor. The stable intent/cycle binding makes simultaneous or
   repeated handlers return the same successor; request drift conflicts.

## Caller coverage

| Caller | Production boundary | Concrete regression evidence |
| --- | --- | --- |
| Bot enqueue | `Hive::Bot::DispatchRequestWriter` delegates keyed delivery to `CommandDispatchLifecycle` | `test_same_cycle_bot_handlers_and_failed_successor_redelivery_use_shared_allocator`; `test_keyed_bot_write_acquires_pin_before_enqueue`; local admission and capacity-deferral tests |
| Foreground durable Attempts | `Hive::Attempts::CommandDispatch` buffers the terminal result behind the lifecycle | `test_attempt_dispatch_binds_context_and_reports_buffered_failure`; `test_attempt_dispatch_requires_a_retry_horizon_and_uses_default_state_home`; shared lifecycle restart, concurrency, and SIGKILL tests |
| Daemon consumption | `Hive::Daemon::Dispatcher` restores the durable command context and uses the same lifecycle | `test_keyed_daemon_same_cycle_handlers_and_failed_successor_redelivery_use_shared_lifecycle`; authenticated context restoration and generation revalidation tests |

`test_restart_reacquires_one_pin_and_same_cycle_successor_is_stable` exercises a
real SQLite close/reopen. `test_attempts_same_cycle_concurrency_uses_the_shared_cross_process_allocator`
uses competing processes. `test_sigkill_matrix_preserves_each_durable_command_boundary`
kills the child at the pin, context, acknowledgement, and completion boundaries
and verifies restart convergence without a second allocation.

## Fences and interrupted effects

The receipt generation fences late finalization. The task ownership generation
is revalidated immediately before worker effects. Dispatch context comparison
fences principal, receipt, fingerprint, effect and ordinal changes. Successor
allocation separately CASes the allocation version, predecessor, intent and
delivery-cycle identity.

Interrupted execution is deliberately narrower than generic “activity exists”
recovery:

| Observation | Allowed outcome |
| --- | --- |
| Exact original boundary result is already stored | Finalize/replay that byte-equivalent typed result |
| Exact Git push/PR identity and observed OID prove the submitted effect | Resume the publication state machine without another remote mutation |
| Exact dispatch request/result correlation proves child completion | Resume the dispatch boundary and persist the original caller result |
| Provider observation is unavailable, the remote OID is wrong, a composite step is unaccounted for, or only generic task activity exists | Remain `unresolved`; do not repeat the effect |
| Whole-effect non-application is authoritatively proven | Persist terminal failure with explicit retry eligibility; only then may a later delivery cycle allocate one successor |

`CommandOperationTest` covers original-result recovery after a lost receipt
commit, applied-push reconciliation, dispatch-result reconciliation, generic
task-activity refusal, and unknown-effect refusal. `GithubPublicationTest`
uses deterministic provider observations for lost push/create responses, wrong
identity/OID, partial inventory, and provider uncertainty. Those are not live
GitHub tests. No live hivedev C4 end-to-end run or live provider credential was
used for this receipt.

Focused verification command:

```sh
bin/test test/unit/command_dispatch_lifecycle_test.rb \
  test/unit/bot/dispatch_request_writer_durable_test.rb \
  test/unit/daemon/dispatcher_test.rb \
  test/unit/runtime_control_plane/dispatch_repository_test.rb \
  test/unit/attempts/context_test.rb \
  test/unit/command_operation_test.rb \
  test/unit/github_publication_test.rb
```

The 2026-09-28 combined receipt/dispatch/maintenance focused run, including
these files, completed 928 runs and 4,581 assertions with no failures, errors,
or skips.
