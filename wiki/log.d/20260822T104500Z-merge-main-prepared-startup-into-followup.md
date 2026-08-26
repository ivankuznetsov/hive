# Merge main (prepared OpenCode startup) into benchmark runtime follow-up

Merged `main` (reliable prepared OpenCode startup #1170, historical patrol
finding migration #1173) into `fix/opencode-benchmark-runtime-followup`. Both
branches had independently grown a "configured model route" concept, so seven
files conflicted.

- `opencode/overlay.rb` — `main` renamed `configured_route_variants` to
  `configured_variants` and treats a declared model key whose definition is not
  a Hash as a configured route with no variants (previously `nil`, i.e. route
  absent). Took `main`'s version and name; the rename has no other callers.
- `opencode/probe.rb` — this branch always ran `models --verbose` and used the
  configuration as a *fallback* (`inventory_variants || configured_variants`);
  `main` skips that inventory subprocess entirely when the configuration
  declares the route, unions the two variant lists, and gives the call a
  30s `MODEL_INVENTORY_TIMEOUT_SECONDS` deadline. Took `main`'s structure and
  kept this branch's `configured_model_route` evidence: under the
  short-circuit, `inventory_variants.nil?` holds exactly when the route was
  accepted on the configuration alone, which is the condition that evidence
  was recording.
- `lib/hive/agent.rb` — independent additions at the same seam. `main` added a
  `normalized.kind == :timed_out` early return (timeout marker + `:timeout`
  status) ahead of the generic non-completed path; this branch added
  `diagnostic = result[:inspection_diagnostic] || normalized.diagnostic` to
  that generic path. Kept both, with the timeout branch first so it keeps
  reporting `normalized.diagnostic` unchanged.
- `values.rb` — formatting only (`configured_variants:` keyword wrapped onto
  its own line). Took `main`.
- `opencode_preparation_test.rb` — both sides added near-duplicate coverage.
  Took `main`'s file (it also adds the inventory-deadline and large-prompt
  stdin tests), folded this branch's `configured_model_route` evidence
  assertion into `test_selected_custom_model_survives_a_stale_local_inventory`,
  and re-added `test_explicit_model_definition_still_requires_the_requested_variant`
  — `main` has no equivalent, since its rival test covers a *missing*
  declaration rather than a declared model whose requested variant is absent.
- `opencode_agent_lifecycle_test.rb` — disjoint tests inserted at the same
  offset; kept all four.
- `wiki/modules/agent_profile.md` — merged both prose blocks: `main`'s
  inspection-deadline and stale-catalog paragraph plus this branch's tool-only
  terminal-record sentence, with a line noting the `configured_model_route`
  evidence.

See [[modules/agent_profile]], [[modules/agent_cli_runtime]].
