# Bound workflow authoring lint phase events

- Streamed typed package-reader, command-extractor, and observation-extractor
  rejection events directly into the evaluator's globally bounded finding
  buffer instead of retaining per-phase event arrays.
- Restored incumbent same-instance failure/retry behavior by running lazy
  extraction stages in evaluation order and retaining the incumbent manifest
  accessor timing without cross-phase memoization or irrelevant graph walks.
- Kept the facade, finding bytes and order, limit sentinel, Publisher consumer,
  and separate SecurityScanner policy boundary unchanged.

**Pages:** [[modules/workflows]] [[component-boundaries]]
