# Make the Workflow Creator hostile campaign opt-in

The normal test and coverage paths continue to exercise the deterministic
Workflow Creator Values and TextSafety contracts, but skip the expensive
20,000-case IEEE-754 and randomized canonicalization campaign. Run
`bundle exec rake test:hostile` to execute that campaign explicitly.
