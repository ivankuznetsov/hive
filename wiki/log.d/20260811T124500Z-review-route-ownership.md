## Reject nested review provider pools

Provider routing now fails configuration loading when declared on a review
role or reviewer entry. Review and Patrol actors share their enclosing durable
attempt, so the supported routing boundaries are `review.routing` and
`patrol.routing`; accepting nested pools previously promised selections that
could never control the journaled attempt.
