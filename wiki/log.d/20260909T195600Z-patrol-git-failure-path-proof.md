# Exercise bounded Git failure paths

Hosted coverage identified untested oversized-index cancellation and missing private object directory handling. Focused regressions now prove an oversized record stays rejected when Git exits during cancellation, and missing private metadata blocks adoption without advancing the protected source. The focused pair passes 41 tests and 178 assertions.
