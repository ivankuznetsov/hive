- Review CI timeouts (wall clock and idle-output) now keep the output the
  run printed before it was killed. `CiFix.run_ci_once` shares its capped
  capture buffer with the run loop, `CommandError` carries that output, and
  `Review.ci_terminal_result` writes it to `reviews/ci-error-<pass>.md` and
  names the file in the `REVIEW_ERROR reason=ci_unrunnable` message.
  Previously the reader thread's private buffer was discarded on kill, so
  hivedev C5's two 3600s timeouts left nothing to debug. See
  [[stages/review]].
