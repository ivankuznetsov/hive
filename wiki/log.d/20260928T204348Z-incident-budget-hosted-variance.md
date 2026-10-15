# Incident budget hosted-runner variance

The three enabled real-subprocess incident scenarios took 33.638 seconds on a
hosted runner while remaining below the sixteen-second per-scenario ceiling.
Restore the thirty-six-second aggregate advisory cap and pin that observed
scheduling variance, keeping timing visible without treating normal shared
runner scheduling as a functional regression.
