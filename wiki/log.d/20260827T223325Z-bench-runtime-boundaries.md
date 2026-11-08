# Verify benchmark runtime boundaries at the executable path

**Fix:** The packaged Pi extension lived in a PATH wrapper that Hive bypassed
through `HIVE_PI_BIN`, and its predicate still named GLM 5.2 after the Ox Alpha
route moved to GLM 5.3 Flash. Sealed cells also ran later controller commands
from a candidate-writable PATH and repository.

**Action:** Made the privilege-dropping Pi launcher load the extension itself,
removed the dead wrapper, and covered GLM 5.3 Flash. Sealed controllers now use
root-owned command/state directories. A root-owned Git wrapper pins the offline
origin, disables candidate-controlled hooks/helpers, and runs every repository
Git operation as uid 1000 instead of root.
