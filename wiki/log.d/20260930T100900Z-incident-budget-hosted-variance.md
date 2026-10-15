# Incident budget hosted-runner variance

The three enabled real-subprocess incident scenarios took 32.600 seconds on a
hosted runner while remaining below the sixteen-second per-scenario ceiling.
Raise the aggregate advisory cap to thirty-six seconds and pin that observed
scheduling variance, keeping timing visible without treating normal shared
runner scheduling as a functional regression.
