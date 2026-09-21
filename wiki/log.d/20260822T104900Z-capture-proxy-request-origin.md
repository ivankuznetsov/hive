# Managed capture maps request origin metadata at the proxy boundary

**Problem:** A live Pi Webmail artifact run could render GET pages through the
random issued `.invalid` origin, but Rails rejected every CSRF-protected POST.
The browser supplied that issued origin while the deliberately loopback-hosted
upstream request made `request.base_url` the controller-issued app port.

**Change:** The capture proxy now translates only its exact `Origin` and
`Referer` request metadata to the loopback application endpoint. Foreign or
malformed values remain unchanged for the application to reject, the upstream
`Host` stays loopback-only, and response redirects retain their existing
inverse translation to the browser origin. A focused regression test covers
both the exact mapping and foreign-value preservation.

See [[stages/artifacts]].
