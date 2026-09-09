# Authenticate the nested evidence-rework worker target

The durable attempt context now resolves the task from `hive evidence rework
TARGET`'s fourth argument and binds that controller-only worker to the task's
current artifacts stage. Automatic implementation rework can therefore cross
from reviewed outcome evidence back to execute without rejecting `rework` as a
nonexistent task slug.
