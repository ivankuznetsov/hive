# Preserve discovery subprocess exit ownership

Background Patrol discovery can run Git while the dispatcher reaps ancillary
children. The supervisor now waits only for its tracked real child PIDs; this
also applies to graceful shutdown. Foreign discovery exit statuses remain
available to their Gh capture owner instead of becoming false ECHILD failures.

A focused process-wait regression covers discovery beside a supervised child.
Patrol reservation coverage also exhausts the launch allowance after discovery
and proves the stale candidate remains unreserved until the next UTC day.
The redundant scheduler-presence guard after the async arbiter guard is removed.
