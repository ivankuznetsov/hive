require "test_helper"
require "open3"
require "hive/agent_support/operator_authority"
require "hive/agent"
require "hive/task"

class AgentOperatorAuthorityTest < Minitest::Test
  include HiveTestHelper

  Authority = Hive::AgentSupport::OperatorAuthority

  def test_operator_attribution_does_not_accept_caller_source_or_environment_credentials
    result = Authority.assert_operator!(process_tree: -> { [] })
    assert_equal({ "caller" => "uid:#{Process.uid}", "source" => "operator_cli" }, result)
    assert_predicate result, :frozen?
  end

  def test_each_supported_adapter_launch_denies_operator_commands_even_with_environment_override
    with_tmp_dir do |dir|
      task = real_review_task(dir)
      assert_equal "review", task.stage_name
      %i[claude codex pi grok opencode].each do |adapter|
        %w[reviewer triage fix].each do |role|
          agent = Hive::Agent.new(
            task:, prompt: role, log_label: role, max_budget_usd: nil, timeout_sec: 5,
            profile: Hive::AgentProfiles.lookup(adapter),
            permission_mode: adapter == :opencode ? "read-only" : nil,
            identity_arguments: adapter == :opencode ? [ "--model", "openai/gpt-5" ] : [],
            launch_environment: { Authority::ENVIRONMENT_KEY => "operator" }
          )
          assert_equal Authority::ENVIRONMENT_VALUE,
                       agent.child_environment.fetch(Authority::ENVIRONMENT_KEY), "#{adapter}/#{role}"
          invocation = if adapter == :opencode
            agent.extend(Hive::AgentSupport::OpenCode::Execution)
            agent.send(:prepare_native_invocation).invocation
          else
            agent.send(:compiled_invocation)
          end
          policy = invocation.capability_evidence.find { |item| item.capability == :operator_command_denial }
          assert policy, "missing required command policy for #{adapter}/#{role}"
          assert_equal [ "review-grant" ], policy.arguments, "#{adapter}/#{role}"
        ensure
          agent&.cleanup_mcp_launch!
        end
      end
    end
  end

  def test_an_actual_managed_ancestor_cannot_authorize_its_child_by_unsetting_environment
    lib = File.expand_path("../../lib", __dir__)
    guard = <<~RUBY
      require "hive/agent_support/operator_authority"
      begin
        Hive::AgentSupport::OperatorAuthority.assert_operator!
        abort "grant allowed"
      rescue Hive::AgentSupport::OperatorAuthority::Denied => error
        puts error.error_kind
      end
    RUBY
    parent = <<~RUBY
      require "open3"
      output, errors, status = Open3.capture3(
        { #{Authority::ENVIRONMENT_KEY.inspect} => nil },
        #{RbConfig.ruby.inspect}, "-I", #{lib.inspect}, "-e", #{guard.inspect}
      )
      $stdout.write(output)
      $stderr.write(errors)
      exit status.exitstatus
    RUBY
    output, errors, status = Open3.capture3(
      { Authority::ENVIRONMENT_KEY => Authority::ENVIRONMENT_VALUE },
      RbConfig.ruby, "-e", parent
    )
    assert status.success?, errors
    assert_equal "agent_denied\n", output
  end

  def test_any_managed_ancestor_refuses_without_using_a_target_task
    tree = -> { [ { "managed" => false }, { "managed" => true } ] }
    error = assert_raises(Authority::Denied) { Authority.assert_operator!(process_tree: tree) }
    assert_equal "agent_denied", error.error_kind
    assert_match(/operator/, error.message)
  end

  def test_unavailable_or_changed_ancestry_fails_closed
    tree = -> { raise IOError, "ancestry changed" }
    error = assert_raises(Authority::AuthorityUnavailable) do
      Authority.assert_operator!(process_tree: tree)
    end
    assert_equal "source_unverified", error.error_kind
  end

  def test_required_command_denial_is_compiled_for_every_adapter_without_tool_scope_flags
    %i[claude codex pi grok opencode].each do |adapter|
      profile = Hive::AgentProfiles.lookup(adapter)
      invocation = Hive::AgentRuntime.compile(Hive::AgentRuntime::Request.new(
        profile:, prompt: "review", denied_commands: [ "review-grant" ],
        disallowed_tools: [ "Write" ],
        permission_arguments: adapter == :opencode ? [ "--auto" ] : nil,
        identity_arguments: adapter == :opencode ? [ "--model", "openai/gpt-5" ] : []
      ))
      policy = invocation.capability_evidence.find { |item| item.capability == :operator_command_denial }
      assert policy.supported, adapter
      assert_equal [ "review-grant" ], policy.arguments
      if %i[claude grok].include?(adapter)
        assert invocation.argv.any? { |argument| argument.include?("Bash(*review-grant*)") }
      end
      if adapter == :claude
        rules = invocation.argv.fetch(invocation.argv.index("--disallowedTools") + 1).split(",")
        assert_equal [ "Write", "Bash(*review-grant*)" ], rules
      end
    end
  end

  def test_unknown_required_command_denial_refuses_instead_of_dropping_it
    error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
      Hive::AgentRuntime.compile(Hive::AgentRuntime::Request.new(
        profile: Hive::AgentProfiles.lookup(:codex), prompt: "review",
        denied_commands: [ "future-operator-command" ]
      ))
    end
    assert_equal :operator_command_denial, error.evidence.capability
  end

  def test_native_opencode_denies_grants_after_explicit_shell_allow_rules
    with_tmp_dir do |dir|
      task = Struct.new(:folder, :stage_name).new(dir, "6-review")
      profile = Hive::AgentProfiles.lookup(:opencode)
      agent = Hive::Agent.new(
        task:, profile:, prompt: "fix", max_budget_usd: nil, timeout_sec: 5,
        permission_mode: "workspace-write", bash_patterns: [ "*" ]
      )
      agent.extend(Hive::AgentSupport::OpenCode::Execution)
      environment = agent.send(:native_environment, profile.support_configuration)
      rules = JSON.parse(environment.fetch("OPENCODE_PERMISSION")).fetch("bash")
      assert_equal "allow", rules.fetch("*")
      assert_equal "deny", rules.fetch("*review-grant*")
      assert_equal Authority::ENVIRONMENT_VALUE, environment.fetch(Authority::ENVIRONMENT_KEY)
    ensure
      agent&.cleanup_mcp_launch!
    end
  end

  def test_special_codex_reviewer_capture_enforces_the_same_command_boundary
    require "hive/reviewers"
    require "hive/reviewers/runtime"
    lib = File.expand_path("../../lib", __dir__)
    script = <<~RUBY
      require "hive/agent_support/operator_authority"
      ENV.delete(#{Authority::ENVIRONMENT_KEY.inspect})
      begin
        Hive::AgentSupport::OperatorAuthority.assert_operator!
        abort "grant allowed"
      rescue Hive::AgentSupport::OperatorAuthority::Denied => error
        puts error.error_kind
      end
    RUBY
    result = Hive::Reviewers::Runtime.capture(
      environment: {}, argv: [ RbConfig.ruby, "-I", lib, "-e", script ],
      chdir: Dir.pwd, timeout_sec: 5, timeout_message: "timed out"
    )
    assert result.success?, result.error
    assert_equal "agent_denied\n", result.stdout
  end

  def test_provenance_unavailable_prevents_launching_any_adapter
    with_replaced_singleton_method(Authority::ProcessTree, :new, -> { -> { raise IOError, "unreadable" } }) do
      assert_raises(Authority::AuthorityUnavailable) { Authority.launch_environment }
    end
  end

  def test_procfs_reads_are_bounded_and_refuse_cycles_and_excess_ancestry
    with_tmp_dir do |root|
      write_process(root, 10, 11)
      write_process(root, 11, 10)
      assert_raises(IOError) { proc_tree(root).call }
      Authority::MAX_ANCESTORS.times do |index|
        write_process(root, index + 10, index + 11)
      end
      assert_raises(IOError) { proc_tree(root).call }
      write_process(root, 10, 1)
      File.write(File.join(root, "10", "environ"), "x" * (Authority::MAX_ENVIRONMENT_BYTES + 1))
      assert_raises(IOError) { proc_tree(root).call }
    end
  end

  def test_procfs_skips_other_users_and_accepts_unreadable_session_root_only
    with_tmp_dir do |root|
      write_process(root, 10, 1)
      assert_equal false, proc_tree(root, uid: Process.uid + 1).call.first.fetch("managed")
      File.chmod(0o000, File.join(root, "10", "environ"))
      assert_equal false, proc_tree(root).call.first.fetch("managed")
      write_process(root, 10, 11)
      File.chmod(0o000, File.join(root, "10", "environ"))
      assert_raises(Errno::EACCES) { proc_tree(root).call }
    end
  end

  def test_changed_procfs_identity_is_not_accepted
    with_tmp_dir do |root|
      write_process(root, 10, 1)
      original = File.method(:binread)
      write = method(:write_process)
      read = lambda do |path, limit|
        bytes = original.call(path, limit)
        write.call(root, 10, 1, start: 43) if path.end_with?("environ")
        bytes
      end
      with_replaced_singleton_method(File, :binread, read) { assert_raises(IOError) { proc_tree(root).call } }
    end
  end

  def test_ps_reads_verify_identity_and_enforce_the_same_denial_policy
    responses = [ [ "1 #{Process.uid} Mon Oct 20 12:00:00 2026", true ],
                  [ "ruby #{Authority::ENVIRONMENT_KEY}=#{Authority::ENVIRONMENT_VALUE}", true ],
                  [ "1 #{Process.uid} Mon Oct 20 12:00:00 2026", true ] ]
    with_ps_responses(responses) do
      tree = Authority::ProcessTree.new(pid: 10, platform: "darwin", ps: "/bin/ps")
      assert_raises(Authority::Denied) { Authority.assert_operator!(process_tree: tree) }
    end
    responses = [ [ "1 #{Process.uid} Mon Oct 20 12:00:00 2026", true ],
                  [ "ruby", true ],
                  [ "1 #{Process.uid} Mon Oct 20 12:00:00 2026", true ] ]
    with_ps_responses(responses) do
      tree = Authority::ProcessTree.new(pid: 10, platform: "darwin")
      assert_equal "operator_cli", Authority.assert_operator!(process_tree: tree).fetch("source")
    end
  end

  def test_ps_missing_inventory_identity_environment_or_changed_identity_refuses
    with_replaced_singleton_method(File, :executable?, ->(*) { false }) do
      tree = Authority::ProcessTree.new(pid: 10, platform: "darwin")
      assert_raises(Authority::AuthorityUnavailable) { Authority.assert_operator!(process_tree: tree) }
    end
    [
      [ [ "", false ] ],
      [ [ "1 #{Process.uid}", true ] ],
      [ [ "1 #{Process.uid} started", true ], [ "", false ] ],
      [ [ "1 #{Process.uid} started", true ], [ "x" * (Authority::MAX_ENVIRONMENT_BYTES + 1), true ] ],
      [ [ "1 #{Process.uid} started", true ], [ "ruby", true ], [ "1 #{Process.uid} changed", true ] ]
    ].each do |responses|
      with_ps_responses(responses) do
        tree = Authority::ProcessTree.new(pid: 10, platform: "darwin", ps: "/bin/ps")
        assert_raises(Authority::AuthorityUnavailable) { Authority.assert_operator!(process_tree: tree) }
      end
    end
  end

  private

  def real_review_task(root)
    folder = File.join(root, ".hive-state", "stages", "6-review", "operator-policy-261102-aaaa")
    FileUtils.mkdir_p(folder)
    prepare_test_task_run(folder)
    Hive::Task.new(folder)
  end

  def write_process(root, pid, parent, start: 42)
    path = File.join(root, pid.to_s)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "stat"), "#{pid} (ruby) #{([ 'S', parent ] + Array.new(17, 0) + [ start ]).join(' ')}")
    File.chmod(0o600, File.join(path, "environ")) if File.exist?(File.join(path, "environ"))
    File.write(File.join(path, "environ"), "PATH=/usr/bin\0")
  end

  def proc_tree(root, **options)
    Authority::ProcessTree.new(pid: 10, proc_root: root, platform: "linux", **options)
  end

  def with_ps_responses(responses)
    responses = responses.dup
    capture = lambda do |*|
      text, success = responses.shift
      [ text, "", Struct.new(:success?).new(success) ]
    end
    with_replaced_singleton_method(Open3, :capture3, capture) { yield }
  end
end
