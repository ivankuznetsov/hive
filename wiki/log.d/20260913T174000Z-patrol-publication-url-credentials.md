# Omit URL credentials from Patrol Fix PR evidence

Credential-bearing example URLs in a successful review could block publication.
The PR body now omits URL userinfo while preserving the immutable source receipt.
Regression coverage uses mixed-case schemes and verifies the real scanner accepts
the resulting body; the existing API-key test still proves rejection before push.
