# Reject hyphenated credential-shaped audit reasons

The shared secret detector now recognizes hyphenated `sk-proj-...` credential
forms. Provider-health operator reason validation uses that shared detector, so
such material is rejected before it can enter a circuit journal, audit receipt,
human output, or JSON projection.
