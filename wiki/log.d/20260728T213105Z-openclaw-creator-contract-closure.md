# OpenClaw creator proof shares its security contracts

- The creator producer, audit gateway, attestor, and release verifier now use
  one complete retained/live installation-identity contract.
- Attestation and release verification now delegate to one strict
  workflow-creator contract instead of maintaining separate equations.
- Attempt and result ledgers now use one bounded no-follow regular-file reader
  with descriptor/path identity checks around the read.
- Deterministic authoring evidence is explicitly marked
  `execution_kind=deterministic_fixture` and `model_loop=not_exercised`.
- The release-candidate builder revision now covers all three shared contract
  sources.

Credentialed OpenClaw authoring remains a separate optional live proof. This
change does not expand the existing containment or socket-attribution claims.
