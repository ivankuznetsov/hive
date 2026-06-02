require "test_helper"
require "tmpdir"
require "json"

# U7 — cross-process flock proof (plan 2026-05-27-003).
#
# The unit test `test_cross_process_writes_do_not_clobber_each_other` drives two
# State instances in ONE process — serialized by the in-process Mutex, so it
# can't prove the cross-process `flock`. This is its real-process counterpart:
# two independent OS processes hammer the same `update_check.json`, one writing
# `nudge` (daemon role) and one writing `last_notified_version` (bot role).
#
# Without the flock, each op's load!→mutate→persist read-modify-write races: a
# process that loaded an EARLY value then writes the whole @data back AFTER the
# other process's latest write clobbers it with a stale value. Each process
# writes a monotonically increasing value, so the proof is that BOTH keys end at
# each process's LAST write — a stale clobber leaves one behind. (Asserting
# merely non-nil would be vacuous: every write persists all keys, so neither
# key goes nil once both have written.) Characterized with the flock bypassed:
# ~40% of runs show a regressed value; with the flock it is deterministic.
class UpdateCheckStateCrossProcessTest < Minitest::Test
  ITERATIONS = 500

  def test_concurrent_processes_do_not_clobber_each_others_keys
    Dir.mktmpdir do |dir|
      path = File.join(dir, "update_check.json")
      go = File.join(dir, "go")
      writer = write_child_script(dir)
      lib = File.expand_path("../../lib", __dir__)

      # Spawn both, then release them together via the `go` barrier so their
      # write loops genuinely overlap (otherwise one could finish before the
      # other starts and the flock would never be contended).
      pids = %w[daemon bot].map do |role|
        Process.spawn(RbConfig.ruby, "-I#{lib}", writer, path, role, ITERATIONS.to_s, go)
      end
      File.write(go, "go")
      statuses = pids.map { |pid| Process.waitpid2(pid).last }

      assert(statuses.all?(&:success?), "both writer processes should exit cleanly: #{statuses.inspect}")
      last = ITERATIONS - 1
      data = JSON.parse(File.read(path))
      assert_equal "9.9.#{last}", data.dig("nudge", "latest"),
                   "the daemon's LAST nudge must win — a stale bot RMW clobbering it means the flock failed"
      assert_equal "8.8.#{last}", data["last_notified_version"],
                   "the bot's LAST notified-version must win — a stale daemon RMW clobbering it means the flock failed"
    end
  end

  private

  def write_child_script(dir)
    path = File.join(dir, "cross_process_writer.rb")
    File.write(path, <<~RUBY)
      require "hive/update_check/state"
      state = Hive::UpdateCheck::State.new(path: ARGV[0])
      role = ARGV[1]
      go = ARGV[3]
      sleep 0.001 until File.exist?(go) # start barrier — both loops begin together
      Integer(ARGV[2]).times do |i|
        if role == "daemon"
          state.set_nudge(latest: "9.9.\#{i}", channel: "brew", command: "hive update")
        else
          state.record_notified!("8.8.\#{i}")
        end
      end
    RUBY
    path
  end
end
