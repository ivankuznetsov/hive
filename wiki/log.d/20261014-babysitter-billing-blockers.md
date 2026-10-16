# Babysitter skips GitHub Actions billing holds

Todero repeatedly launched repair agents for failed checks whose runners never
started because of account billing. A clean agent exit was recorded as success
while the check remained red. The babysitter now classifies an exclusively
billing-blocked CI context as an operator blocker before agent launch. Repeated
ticks spend no agent tokens; independent code failures and conflicts remain
repairable. Regression coverage exercises repeated ticks and mixed failures.
