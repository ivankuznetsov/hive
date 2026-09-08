## Preserve workflow identity in shared reviewer sessions

The first live standalone reviewer exposed a coding-only synthetic task facade: it omitted workflow identity and hardcoded its stage. Session activity consequently defaulted to coding, invalidating the pr-review journal. The shared facade now carries metadata workflow and the task's actual stage directory. A regression covers standalone review identity; coding remains the fallback for legacy metadata.
