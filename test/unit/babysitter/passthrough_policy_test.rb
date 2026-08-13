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

  def test_git_policy_rejects_unsafe_globals_and_accepts_safe_repository_selectors
    allowed = [
      %w[-C /tmp/repo status],
      %w[--git-dir=/tmp/repo/.git status],
      %w[--work-tree=/tmp/repo status]
    ]
    denied = [
      %w[-ccore.pager=cat status],
      %w[--config-env=core.pager:PAGER status],
      %w[-p status],
      %w[--exec-path=/tmp/helpers status],
      %w[--future-global value status]
    ]

    allowed.each { |argv| assert Hive::Babysitter::GitPolicy.classify(argv, environment: {}).allowed?, argv.inspect }
    denied.each { |argv| refute Hive::Babysitter::GitPolicy.classify(argv, environment: {}).allowed?, argv.inspect }
  end

  def test_git_policy_models_grep_value_options_and_pager_clusters
    allowed = [
      %w[grep --regexp TODO README.md],
      %w[grep --regexp=TODO README.md],
      %w[grep --only-matching TODO README.md],
      %w[grep -e TODO README.md],
      %w[grep -eTODO README.md],
      %w[grep -in TODO README.md]
    ]
    denied = [
      %w[grep --op=less TODO],
      %w[grep -iO TODO]
    ]

    allowed.each { |argv| assert Hive::Babysitter::GitPolicy.classify(argv, environment: {}).allowed?, argv.inspect }
    denied.each { |argv| refute Hive::Babysitter::GitPolicy.classify(argv, environment: {}).allowed?, argv.inspect }
  end

  def test_git_policy_models_read_only_remote_branch_and_config_forms
    allowed = [
      %w[remote show -n origin],
      %w[remote get-url --push --all origin],
      %w[branch],
      %w[branch --show-current],
      %w[branch --contains],
      %w[branch --contains HEAD],
      %w[branch --contains=HEAD],
      %w[config --bool --type=bool --get commit.gpgsign],
      %w[config --get-all remote.origin.url],
      %w[config --list]
    ]
    denied = [
      %w[remote show -n],
      %w[remote set-url origin https://example.test/repo],
      %w[branch --contains=],
      %w[config --replace-all remote.origin.url value]
    ]

    allowed.each { |argv| assert Hive::Babysitter::GitPolicy.classify(argv, environment: {}).allowed?, argv.inspect }
    denied.each { |argv| refute Hive::Babysitter::GitPolicy.classify(argv, environment: {}).allowed?, argv.inspect }
  end

  def test_git_policy_rejects_nonzero_or_malformed_config_count
    assert Hive::Babysitter::GitPolicy.classify(
      %w[status], environment: { "GIT_CONFIG_COUNT" => "0" }
    ).allowed?
    refute Hive::Babysitter::GitPolicy.classify(
      %w[status], environment: { "GIT_CONFIG_COUNT" => "1" }
    ).allowed?
    refute Hive::Babysitter::GitPolicy.classify(
      %w[status], environment: { "GIT_CONFIG_COUNT" => "invalid" }
    ).allowed?
  end

  def test_git_policy_hardens_log_passthrough_after_global_options
    hardened = Hive::Babysitter::GitPolicy.hardened_passthrough_argv(
      %w[-C /tmp/repo log -1], %w[log -1]
    )

    assert_equal %w[-C /tmp/repo log --no-ext-diff --no-textconv -1], hardened.last(6)
    assert_includes hardened.each_cons(2).to_a, %w[-c core.fsmonitor=false]
    assert_includes hardened.each_cons(2).to_a, %w[-c gpg.ssh.program=false]
    assert_includes hardened.each_cons(2).to_a, %w[-c diff.submodule=short]
    assert_includes hardened, "--no-lazy-fetch"
    assert_includes hardened, "--no-pager"
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

  def test_gh_policy_rejects_host_overrides_in_every_repo_option_form
    allowed = [
      %w[-R owner/repo pr view 42],
      %w[--repo=owner/repo pr view 42],
      %w[-Rowner/repo pr view 42]
    ]
    denied = [
      %w[pr view 42 -R evil.example/owner/repo],
      %w[pr view 42 --repo=https://evil.example/owner/repo],
      %w[pr view 42 -Revil.example/owner/repo],
      %w[pr view 42 -cR=evil.example/owner/repo],
      %w[pr view 42 -cR evil.example/owner/repo],
      %w[api rate_limit --hostname evil.example]
    ]

    allowed.each { |argv| assert Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
    denied.each { |argv| refute Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
  end

  def test_gh_policy_models_api_endpoint_option_consumption
    allowed = [
      %w[api -i rate_limit],
      %w[api --header=Accept:application/json]
    ]
    denied = [
      %w[api -- https://evil.example/rate_limit],
      %w[api --header Accept:application/json https://evil.example/rate_limit]
    ]

    allowed.each { |argv| assert Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
    denied.each { |argv| refute Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
  end

  def test_gh_policy_rejects_api_methods_and_payloads_but_allows_explicit_safe_get_fields
    allowed = [
      %w[api -X=GET rate_limit],
      %w[api -Fq=value -X GET rate_limit],
      %w[api --field=q=value -X GET rate_limit]
    ]
    denied = [
      %w[api -iX POST repos/owner/repo/dispatches],
      %w[api -F q=@secret rate_limit],
      %w[api --input payload.json rate_limit],
      %w[api -fquery=value rate_limit],
      %w[api --raw-field=query=value rate_limit],
      %w[api -Fq=@secret -X GET rate_limit],
      %w[api --field=q=@secret -X GET rate_limit],
      %w[api --input=payload.json -X GET rate_limit]
    ]

    allowed.each { |argv| assert Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
    denied.each { |argv| refute Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
  end

  def test_gh_policy_rejects_token_and_auth_host_selectors
    allowed = [
      %w[auth status],
      %w[auth status active],
      %w[auth status -a]
    ]
    denied = [
      %w[auth token],
      %w[auth status --show-token],
      %w[auth status -t],
      %w[auth status -hgithub.com],
      %w[auth status --hostname=github.com]
    ]

    allowed.each { |argv| assert Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
    denied.each { |argv| refute Hive::Babysitter::GhPolicy.classify(argv).allowed?, argv.inspect }
  end

  def test_gh_policy_stops_browser_option_scanning_at_operand_separator
    assert Hive::Babysitter::GhPolicy.classify(%w[pr view 42 -- --web]).allowed?
    assert Hive::Babysitter::GhPolicy.classify(%w[pr list -d]).allowed?
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
      real_env_key: "REAL", environment: {},
      skip_reporter: -> { "skip" }
    )
    _out, err = capture_io { assert_equal 127, runner.call }
    assert_match(/REAL is unset/, err)

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

  def test_runner_default_executor_forwards_the_real_binary_and_argv
    executed = nil
    original_exec = Kernel.method(:exec)
    runner = Hive::Babysitter::PassthroughRunner.new(
      tool: "gh", argv: %w[pr view 42], allowed: true,
      real_env_key: "REAL", environment: { "REAL" => "/usr/bin/gh" },
      skip_reporter: -> { "skip" }
    )

    Kernel.define_singleton_method(:exec) { |*args| executed = args; 29 }
    begin
      assert_equal 29, runner.call
    ensure
      Kernel.define_singleton_method(:exec, original_exec)
    end
    assert_equal [ "/usr/bin/gh", "pr", "view", "42" ], executed
  end
end
