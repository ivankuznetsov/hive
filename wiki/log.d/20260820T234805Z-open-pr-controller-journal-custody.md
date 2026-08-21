# Terminal attempt delivery respects live stage ownership

Hive itself updates `task-journal.jsonl` and `task-projection.json` to record
live agent activity while an open-PR provider call is in flight. Before this
change, those normal controller writes looked identical to provider tampering,
so a successful draft-PR creation could land
`ERROR reason=open_pr_tampered` and wait through an unnecessary daemon retry.

The terminal execute-attempt observer now acquires the ordinary task ownership
lock before appending its condition record or rebuilding the task projection.
If open PR or any other stage runner owns the task, that non-blocking claim
returns `:pending` immediately. The daemon retries after the stage releases and
then delivers the observation once. This uses the existing scheduler ownership
boundary rather than a second long-held lock or a provider sandbox.

Open PR therefore keeps `task-journal.jsonl` and `task-projection.json` in its
full firewall manifest. Pi retains the repository, wiki, shell, and network
access needed to author and verify the PR, while a direct provider mutation is
still detected and restored. Regression coverage proves a live stage lock
defers terminal delivery without blocking and that the same observation is
delivered and acknowledged after release.
