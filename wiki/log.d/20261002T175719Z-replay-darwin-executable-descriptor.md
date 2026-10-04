# 2026-10-02 — Launch Darwin replay artifacts with executable descriptors

- Hosted macOS reached launch but rejected every read-only `/dev/fd/<fd>` alias
  with `descriptor_exec_failed`; Darwin exposes execute permission on these
  synthetic entries only when the underlying descriptor was opened `O_EXEC`.
- Replay now retains separate identity-matched readable and executable
  descriptors on Darwin. Shebang and fallback scripts use the readable alias;
  native binaries use the `O_EXEC` alias and retain `repro.sh` as `argv[0]`.
- The alias-mismatch portability fixture now follows the host platform, so APFS
  admission validation cannot mask the intended descriptor refusal. A green
  hosted macOS run for this correction remains outstanding.
