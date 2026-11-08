# Cover detached supervisor handoff failure and descriptor contracts

Hosted PR #1172 coverage identified an unexercised trusted load-path fallback
and private supervisor call path. Focused tests now verify that a vanished
runtime dependency does not restore ambient RUBYLIB, and that the private
command passes claim/ready pipes, timers, store and result through its supervisor
boundary. Production behavior and the coverage threshold are unchanged.
