# Persist benchmark generation attempts outside candidate checkouts

Run, Pipeline and HiveDriver persist `generation-attempt.json` before generation
starts and finalize patch/plan/context inputs before evaluation. Identical-byte
regeneration rotates identity. Verified completed-artifact recovery retains it;
unfinalized recovery promotes and verifies artifacts before recording
`recovery-finalized`. Execute/review resume rotates identity before the container
runs. Driver configuration compatibility remains a separate exact-equality check.
Legacy recovery does not acquire continuity with old evaluations. Available
attempt telemetry survives quota/gate/judge parking and is deduplicated by the
scorer. Reused output records verified producer lineage as well as its own
artifact bindings.
