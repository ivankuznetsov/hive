require "test_helper"
require "hive/babysitter/git_policy"
require "hive/babysitter/gh_policy"
require "hive/babysitter/passthrough_runner"

class BabysitterPassthroughPolicyTest < Minitest::Test
  def test_git_policy_classifies_reads_without_side_effects
    allowed = [
      %w[status --short],
      %w[log -p -1],
      %w[remote -v]
    ]
    denied = [
      %w[push origin main],
      %w[log --output=/tmp/leak],
      %w[-c core.pager=cat status]
    ]

    allowed.each { |argv| assert Hive::Babysitter::GitPolicy.classify(argv, environment: {}).allowed?, argv.inspect }
    denied.each { |argv| refute Hive::Babysitter::GitPolicy.classify(argv, environment: {}).allowed?, argv.inspect }
    refute Hive::Babysitter::GitPolicy.classify(%w[status], environment: { "GIT_EXEC_PATH" => "/tmp" }).allowed?
  end

  def test_gh_policy_classifies_reads_without_side_effects
    allowed = [
      %w[pr view 42 --json number],
      %w[api -X GET repos/owner/repo],
      %w[run list]
    ]
    denied = [
      %w[pr edit 42 --title changed],
      %w[pr view 42 --web],
      %w[pr view https://evil.example/owner/repo/pull/1],
      %w[api -X POST repos/owner/repo]
    ]

    allowed.each { |argv| assert Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
    denied.each { |argv| refute Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
  end

  def test_runner_owns_skip_and_validated_handoff
    skips = 0
    runner = Hive::Babysitter::PassthroughRunner.new(
      tool: "git", argv: %w[push], allowed: false,
      real_env_key: "REAL", environment: {},
      skip_reporter: -> { skips += 1; "skipped" }
    )
    _out, err = capture_io { assert_equal 0, runner.call }
    assert_equal 1, skips
    assert_equal "skipped\n", err

    prepared = false
    executed = nil
    environment = { "REAL" => "/usr/bin/tool" }
    runner = Hive::Babysitter::PassthroughRunner.new(
      tool: "git", argv: %w[status], allowed: true,
      real_env_key: "REAL", environment: environment,
      skip_reporter: -> { flunk "allowed command was skipped" },
      prepare_environment: ->(env) { prepared = true; env["SAFE"] = "1" },
      command_argv: -> { %w[--safe status] },
      executor: ->(real, argv, env) { executed = [ real, argv, env["SAFE"] ]; 23 }
    )

    assert_equal 23, runner.call
    assert prepared
    assert_equal [ "/usr/bin/tool", %w[--safe status], "1" ], executed
  end

  def test_runner_maps_real_binary_validation_and_exec_failures
    runner = Hive::Babysitter::PassthroughRunner.new(
      tool: "gh", argv: %w[pr view], allowed: true,
      real_env_key: "REAL", environment: { "REAL" => "relative" },
      skip_reporter: -> { "skip" }
    )
    _out, err = capture_io { assert_equal 127, runner.call }
    assert_match(/must be an absolute path/, err)

    runner = Hive::Babysitter::PassthroughRunner.new(
      tool: "gh", argv: %w[pr view], allowed: true,
      real_env_key: "REAL", environment: { "REAL" => "/missing/gh" },
      skip_reporter: -> { "skip" },
      executor: ->(*) { raise Errno::ENOENT, "missing" }
    )
    _out, err = capture_io { assert_equal 127, runner.call }
    assert_match(/cannot exec real gh/, err)
  end
end
