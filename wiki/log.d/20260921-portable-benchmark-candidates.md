# Portable benchmark candidate declarations

The packaged `bench` workflow accepts `candidate_profiles` in the committed
campaign contract. Profiles declare native Hive plan/execute/review model routes,
reasoning effort, optional explicit code reviewers, and explicit plan-review
routes. Historical candidate IDs cannot be shadowed. Single-model profiles retain
the benchmark's no-plan-review default.

Provider credentials are environment-variable references, not campaign values.
Pi accepts a campaign-owned public model catalog with HTTPS endpoints and declared
environment references. OpenCode no longer requires OpenRouter for unrelated
providers. The runner uses its baked CE skills for Pi instead of a workstation
checkout. Runner builds require an explicit Hive source checkout.

Verification includes packaged workflow installation, legacy candidate behavior,
new profile compilation, invalid profile rejection, and native controller storage
and usage fixtures. Live campaigns and shared dogfood deployment remain separate
verification steps; these local tests do not establish benchmark results.
