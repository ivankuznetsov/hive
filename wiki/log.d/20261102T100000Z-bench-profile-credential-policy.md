# Direct benchmark profile credential policy (U1)

Ported the canonical hive-bench profile declaration from commit dce0f15.
Pi selects an API variable by explicit provider prefix; Claude/Codex select
only their configured OAuth file. Both inherited OAuth overrides are cleared,
and unsupported/missing profile policy refuses before any subprocess.
The packaged v2 HiveDriver path is unchanged.
