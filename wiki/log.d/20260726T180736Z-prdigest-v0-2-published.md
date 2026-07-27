# 2026-07-26 — PRDigest 0.2.0 published

PRDigest 0.2.0 is publicly installable from RubyGems. Hive now resolves and
locks that release through its existing deterministic `prdigest run` adapter;
the additive facts and prose modes remain outside Hive.

The dependency update retains PRDigest 0.1.1's native Octokit `Time`
normalization, advances the runtime constraint and executable fallback to
`~> 0.2.0`, and keeps Hive's explicit-date and catch-up ownership unchanged.

Release verification clean-installed the public gem and exercised its versioned
facts contract before this downstream merge was prepared.
