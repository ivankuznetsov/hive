# StatusChannel starts the broadcaster on the first live page and stops it
# after the last page leaves. The exit hook is only a final process-cleanup
# guard; boot, db:prepare, console, and an idle server perform no status scan.
at_exit { StatusBroadcaster.stop! if defined?(StatusBroadcaster) }
