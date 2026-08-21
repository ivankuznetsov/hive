# Pi model-output truncation is a typed failure

Pi 0.84.2 can end a non-interactive JSON run with `stopReason: "length"` and
exit zero when the selected model consumes its maximum output tokens. If the
model reached that boundary before its final write tool, Hive previously saw
only a missing expected artifact and reported the run as though Pi had silently
done nothing.

`agent-cli-runtime` now normalizes that event as
`kind: model_output_limit`. `Hive::Agent` carries the event into its existing
resource-exhaustion path, preserves the observed output-token count when Pi
reports it, and emits an actionable error telling the operator to raise the
model's `maxTokens` setting or lower reasoning effort. A valid output artifact
still wins, matching the existing token- and turn-limit behavior.

The real Webmail evidence was two large DeepSeek V4 Pro plan reviews that ended
at exactly 8,192 output tokens with no verdict, while smaller reviews ended
with `stopReason: "stop"` and wrote valid results. The host's Pi model override
had reduced the catalog model from its built-in 393.2K maximum output to 8,192;
removing that local cap restored the model's declared ceiling. The host setting
is runtime evidence and is not part of this repository change.
