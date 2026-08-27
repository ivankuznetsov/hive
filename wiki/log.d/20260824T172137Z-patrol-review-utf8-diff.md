## Patrol Fix review accepts valid UTF-8 Git diffs

- Kept Patrol Fix diff custody and SHA-256 identity over the bounded raw Git
  bytes while decoding a validated copy for the independent review prompt.
- Valid non-ASCII patch text no longer crashes canonical JSON serialization
  merely because the bounded Git reader labels process output as binary.
- Malformed diff bytes still fail closed before the review agent launches.
