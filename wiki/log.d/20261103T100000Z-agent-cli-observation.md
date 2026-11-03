## Agent CLI observation contract

Added immutable executable identity observations with explicit environment,
cwd, and spawn selection authority. Filesystem versions require provider
metadata linked to the selected executable. Advisory version capture has its
own bounded deadline and does not reuse or alter minimum-version enforcement.
The isolated spawn selector now shares its implementation with observations.
