## Share workflow stage resolution with durable workers

Live standalone review admission selected `1-review`, but worker validation and recovery dispatch still resolved `review` against coding's `6-review`. Move the existing standalone verb mapping into `Workflows.for_verb` and share it across command admission, worker context validation and queued dispatch. Regression tests cover review, archive and rejection of an incorrectly admitted coding stage.
