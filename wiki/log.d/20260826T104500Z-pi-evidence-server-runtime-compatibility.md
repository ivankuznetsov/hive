# Preserve Pi project-server evidence capability after runtime extraction

The Pi evidence runtime now carries the controller-issued `project_server`
capability through its support adapter into the generated extension and its
closed tool allowlist. This keeps non-Hive visual evidence able to start its
attempt-owned project server through `hive evidence server` after the provider
runtime extraction.

The controller-side project command sandbox also supplies the explicit
exclusions required by the shared parent-directory helper, so terminal evidence
continues to build its isolated bubblewrap command boundary.
