# Exercise the real Git lock-owner probe

Dogfood verification found that PSmisc fuser rejects `--`, so the conservative
lock probe always declined recovery. Pass the absolute Git-resolved path
directly. A real-process regression now verifies an open lock is preserved,
an unowned lock is recovered, and Git can write afterward. Missing probe tools
still leave locks untouched.
