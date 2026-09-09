# Refresh the release Buildx action pin

Updated all three release container jobs from docker/setup-buildx-action v4.2.0
to the upstream v4.3.0 commit and corrected the stale version comments. Action
metadata is unchanged between these releases. The release-workflow contract is
validated without executing publication or creating a release tag.
