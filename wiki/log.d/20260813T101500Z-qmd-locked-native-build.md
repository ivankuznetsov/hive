# Close the QMD native dependency boundary

The managed installer now disables every npm lifecycle script while realizing
the release-owned QMD lock. It builds better-sqlite3 explicitly from its
integrity-checked source with a locked node-gyp, local Node headers, and offline
node-gyp configuration. QMD package and integrity environment inputs can no
longer select artifacts outside the release lock. Missing local headers or any
native build failure preserves the previous managed QMD installation.
