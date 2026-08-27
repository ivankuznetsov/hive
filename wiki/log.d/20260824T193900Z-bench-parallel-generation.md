# Run benchmark generation cells concurrently

- Changed the packaged bench generate stage to start every unbought campaign
  cell before waiting for any one cell to finish.
- Preserved one stderr file, command, exit status, and result classification per
  cell, and still reap every child before merging or writing a terminal marker.
- Added focused workflow coverage for the launch-before-reap ordering and
  per-cell scratch cleanup contract.
