# Recheck operator generation after intent reconciliation

Provider-health block, unblock, and reset now repeat their generation CAS after
reconciling unresolved probe intents. If reconciliation advances the scope by
accepting a live claim, the operator mutation returns stale and must be retried
from a fresh inspection instead of accepting two transitions from one observed
generation.
