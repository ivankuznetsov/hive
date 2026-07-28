# Bound workflow authoring lint phase events

- Streamed typed package-reader, command-extractor, and observation-extractor
  rejection events directly into the evaluator's globally bounded finding
  buffer instead of retaining per-phase event arrays.
- Restored incumbent same-instance failure/retry behavior by running lazy
  extraction stages in evaluation order and snapshotting manifest data and
  permissions only when their phase first needs them.
- Kept the facade, finding bytes and order, limit sentinel, Publisher consumer,
  and separate SecurityScanner policy boundary unchanged.

**Pages:** [[modules/workflows]] [[component-boundaries]]
