Deployed hivedev.ai from source commit 5e9219ecb61838082627c57e522712e60952e0b8.
Cloudflare Worker version: 75042770-1899-4a17-ab26-58599c514874.
Production D1 is migrated; hostname-restricted Turnstile secret is stored in
Cloudflare. Public DNS resolves via Cloudflare and Google; HTTPS, desktop and
mobile scripted branches, installation links, privacy text, 404/405 responses
and invalid-token rejection passed. Local DNS retained a negative cache, so
HTTPS/browser checks used an IP returned by public DNS with the real hostname
and certificate validation intact.
A real successful signup remains pending because the browser could not reach
a Turnstile challenge host. Remote D1 contains zero signups after verification.
The existing hivecli.sh Worker/domain binding is unchanged.
