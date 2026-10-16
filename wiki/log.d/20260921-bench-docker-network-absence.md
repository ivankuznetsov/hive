# Recognize Docker's missing-network response

Live campaign preflight exposed a Docker error shape absent from the fixture:
`Error response from daemon: network NAME not found`. Managed benchmark network
setup now treats this exact requested-network response as absence, while still
rejecting permission and other inspection failures. The fixture uses the observed
response. No candidate inference had started when this preflight failed.
