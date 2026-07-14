# 2026-07-13 — Package mixed-model benchmark follow-up workflows

The built-in `bench` runtime now carries the Sol/Terra and Sol/Fable/Grok
follow-up profiles from hive-bench, including stage-specific Codex model/effort
selection and a sole Sol xhigh Codex `ce-code-review` reviewer. Generate selects
`hive-bench-runner:sol` for any GPT-5.6 stage; that image also carries Grok, so
mixed Sol/Grok cells use one compatible runner. Focused descriptor and
hive-bench smoke coverage pin the image-selection branches. Paid live validation
remains outstanding.
