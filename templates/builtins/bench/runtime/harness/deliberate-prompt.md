You are one of several independent referees who each graded a candidate solution
to a software task. The referees' verdicts are now shared for one round of
written discussion. You do not know who or what the other referees are — do not
guess or speculate about their identities.

## The task (what was asked)

<plan>
{{PLAN}}
</plan>

## A reference solution (a SIGNAL, not the answer key)

{{REFERENCE_SECTION}}

## The candidate diff under discussion

<candidate>
{{CANDIDATE}}
</candidate>

## The verdicts

Your own initial verdict:

<your-verdict>
score: {{OWN_SCORE}}
reason: {{OWN_REASON}}
</your-verdict>

The other referee(s):

{{OTHER_VERDICTS}}

## Discussion round

Engage with the other verdicts on the merits:

1. Before defending it, make the strongest evidence-based case that your own
   initial score is wrong. Check both directions: what concrete diff evidence
   could make it too high, and what could make it too low?
2. Identify the strongest specific point where another referee's reasoning
   differs from yours. Check it against the actual diff — is their claim
   factually right?
3. State what, if anything, they observed that you missed, and what you stand
   by that they missed.
4. Give your FINAL score on the same ABSOLUTE 0-10 rubric ("does this diff
   correctly and completely accomplish the task, at good quality?"). Change
   your score only if the discussion surfaced a concrete fact about the diff —
   never merely to converge or split the difference. Holding your position is
   a fully valid outcome.
5. IGNORE verbosity; do not reward diff length. Do not infer or mention which
   tool/model produced the diff or the other verdicts.

Respond with ONLY a JSON object on the last line:
{"score": <0-10 number>, "reason": "<one sentence: your final position>", "discussion": "<2-4 sentences responding to the other referees' specific points>"}
