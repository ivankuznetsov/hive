# Task-projection marker UTF-8 encoding

Byte-oriented marker scanning can return valid UTF-8 reason attributes tagged
ASCII-8BIT. JSON 3 rejects those values during routine projection cache-key
generation, hiding the containing project behind `project_load_failed`.
TaskProjection canonicalization now retags copied binary keys/values as UTF-8
before JSON generation. Bytes, source objects and valid projection fingerprints
are preserved. Invalid UTF-8 still fails rather than being scrubbed into an
alternative identity. Regression tests cover nested keys/values and invalid bytes.
