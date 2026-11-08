# Correct benchmark dependency isolation documentation

Verified that the existing benchmark isolation contract removes hive-cli from
the candidate bundle while retaining dependency gems. Corrected the new runtime
packaging notes to match that boundary, and moved the explanatory paragraph out
of the dependency table. Source-matched runtime installation does not expand the
isolation boundary or change provider execution.
