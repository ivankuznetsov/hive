require "rake/testtask"

# Default suite — everything under test/{unit,integration}. Self-contained,
# uses fake-claude / fake-gh, no network or paid API calls.
Rake::TestTask.new do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/{unit,integration}/**/*_test.rb"]
  t.warning = false
end

# Smoke suite — opt-in, runs against real `claude` and a tmp git repo. Costs
# ~$0.25 per invocation (single brainstorm round). Excluded from the default
# suite so CI without a claude binary doesn't try to run it.
#
#   rake smoke               # run the smoke suite (requires real claude on PATH)
#
# Per project CLAUDE.md (Ivan's rule "use real APIs, make real requests"):
# this is the test bed where claude actually gets called.
Rake::TestTask.new(:smoke) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/smoke/**/*_test.rb"]
  t.warning = false
  t.description = "Run live-claude smoke tests (real subprocess; ~$0.25/run)"
end

task default: :test
