# Share feature-map persistence across Patrol engines

Live periodic sweeps exposed a missing `write_features` method on Architecture
Patrol's state store. The shared mapper calls it only outside dry-run mode;
existing tests used dry-run mapping or injected a mapper, hiding the mismatch.

Moved the unchanged batch persistence method from ordinary Patrol's state store
to their shared base. Added a periodic child regression using a real local Git
origin, default mapper, reviewer, result store, and finding admission. Only the
external provider is faked, with evidence anchored to the committed source.
