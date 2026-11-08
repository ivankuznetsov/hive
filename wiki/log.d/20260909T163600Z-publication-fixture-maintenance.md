# Keep publication fixture cleanup deterministic

`GithubPublicationTest` disables automatic Git maintenance in its disposable
working and bare repositories. Git 2.55 launched detached maintenance during
publication tests; removal of `objects/maintenance.lock` raced with Ruby's
temporary-directory cleanup in hosted coverage shard 2. Production Git
configuration and publication assertions are unchanged.
