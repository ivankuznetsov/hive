require "test_helper"
require "hive/markers"
require "hive/lock"
require "hive/config"
require "hive/task"
require "hive/agent"
require "hive/agent_profiles"
require "hive/stages/base"

# Direct coverage for Hive::Stages::Base.spawn_agent: profile check_version! /
# preflight! ordering, the warn_isolation_reduced trigger when the configured
# profile lacks add_dir_flag, and the default-profile fallback. Closes
# doc-review #11 (spawn_agent has zero direct tests) and #10
# (warn_isolation_reduced has zero tests).
class SpawnAgentTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_CLAUDE_HANG HIVE_FAKE_CLAUDE_LOG_DIR
       HIVE_FAKE_CLAUDE_VERSION].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_task(dir, stage = "2-brainstorm", slug = "spawn-test-260425-aaaa")
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  # --- default profile selection ------------------------------------------

  def test_default_profile_is_claude
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x",
        max_budget_usd: 1,
        timeout_sec: 5
        # no profile: kwarg
      )
      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      # claude-specific flags must appear
      assert_includes argv, "arg=--dangerously-skip-permissions"
      assert_includes argv, "arg=--no-session-persistence"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # --- preflight ordering --------------------------------------------------

  def test_preflight_runs_before_agent_spawn
    # Build a profile whose preflight raises; assert no spawn happens.
    raising_profile = Hive::AgentProfile.new(
      name: :raises_preflight,
      bin_default: FAKE_BIN,
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      output_format_flags: [ "--verbose" ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker,
      preflight: -> { raise Hive::AgentError, "preflight blocked" }
    )

    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      log_dir = Dir.mktmpdir("no-spawn-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir

      err = assert_raises(Hive::AgentError) do
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: "x", max_budget_usd: 1, timeout_sec: 5,
          profile: raising_profile
        )
      end
      assert_match(/preflight blocked/, err.message)

      # No argv log written → no spawn happened.
      argv_log = File.join(log_dir, "fake-claude-argv.log")
      refute File.exist?(argv_log), "agent must not spawn when preflight raises"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # --- warn_isolation_reduced --------------------------------------------

  def test_isolation_warning_written_when_profile_lacks_add_dir_flag
    # Profile with no add_dir_flag, claude bin (so it actually runs).
    no_add_dir_profile = Hive::AgentProfile.new(
      name: :no_isolation,
      bin_default: FAKE_BIN,
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      add_dir_flag: nil, # the gap under test
      output_format_flags: [ "--verbose" ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker
    )

    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x", max_budget_usd: 1, timeout_sec: 5,
        add_dirs: [ dir ],
        profile: no_add_dir_profile
      )

      log_path = File.join(task.log_dir, "isolation-warnings.log")
      assert File.exist?(log_path), "isolation-warnings.log must be written"
      content = File.read(log_path)
      assert_match(/profile :no_isolation has no add_dir_flag/, content)
      assert_match(/ADR-018/, content)
      assert_includes content, dir, "log must cite the ignored add_dirs"
    end
  end

  def test_no_isolation_warning_when_profile_has_add_dir_flag
    # Default claude profile has --add-dir; passing add_dirs is fine.
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x", max_budget_usd: 1, timeout_sec: 5,
        add_dirs: [ dir ]
        # default claude profile
      )
      log_path = File.join(task.log_dir, "isolation-warnings.log")
      refute File.exist?(log_path),
             "no warning expected when profile has add_dir_flag"
    end
  end

  def test_isolation_warning_rejects_non_array_add_dirs
    no_add_dir_profile = Hive::AgentProfile.new(
      name: :no_isolation,
      bin_default: FAKE_BIN,
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      output_format_flags: [ "--verbose" ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker
    )

    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      err = assert_raises(ArgumentError) do
        # spawn_agent's signature requires Array; pass through warn helper.
        Hive::Stages::Base.send(
          :warn_isolation_reduced,
          task, no_add_dir_profile, { wrong: "type" }
        )
      end
      assert_match(/Array/, err.message)
    end
  end

  # --- cross-spawn nonce isolation property -----------------------------

  def test_cross_spawn_nonce_isolation_two_distinct_renders
    # The SEC-1 fix's security property: a leaked nonce in one render cannot
    # forge a closing tag against any sibling render. Verify by rendering
    # the same template twice with separately-fetched tags and asserting:
    # (a) tags differ, (b) one render's close-tag does not match the other's
    # nonce, (c) the literal hostile string `</user_supplied>` (no nonce)
    # would not match either render's close-tag.
    tag_a = Hive::Stages::Base.user_supplied_tag
    tag_b = Hive::Stages::Base.user_supplied_tag

    refute_equal tag_a, tag_b, "per-spawn nonces must be fresh per call"

    open_a, close_a = "<#{tag_a}>", "</#{tag_a}>"
    open_b, close_b = "<#{tag_b}>", "</#{tag_b}>"

    refute_equal close_a, close_b, "close tags must be distinct per spawn"
    refute open_a.include?(tag_b), "spawn-A's open must not contain spawn-B's nonce"
    refute close_a.include?(tag_b), "spawn-A's close must not contain spawn-B's nonce"

    # Naive hostile literal — no per-render nonce attached. Must not match
    # either close tag.
    naive_hostile = "</user_supplied>"
    refute_equal naive_hostile, close_a
    refute_equal naive_hostile, close_b
  end
end
