require "test_helper"
require "hive/remote/command_policy"
require "hive/cli"
require "open3"

class RemoteCommandPolicyTest < Minitest::Test
  def test_every_registered_command_and_alias_has_an_explicit_classification
    commands = Hive::CLI.all_commands.keys + Hive::CLI.map.keys
    commands.each do |command|
      refute_equal :unsupported, Hive::Remote::CommandPolicy.classify(command), command
    end
    assert_equal :unsupported, Hive::Remote::CommandPolicy.classify("future-command")
    assert_equal :supported_remote, Hive::Remote::CommandPolicy.classify("new")
    assert_equal :local_only, Hive::Remote::CommandPolicy.classify("drop")
    assert_equal :context_management, Hive::Remote::CommandPolicy.classify("context")
  end

  def test_remote_local_only_and_unknown_fail_before_dispatch
    contexts = fixed_contexts(remote)
    [ %w[init /tmp/checkout], %w[unknown] ].each do |argv|
      error = assert_raises(Hive::UsageError) do
        Hive::Remote::CommandPolicy.preflight!(argv, contexts: contexts)
      end
      assert_match(/--context local/, error.message)
    end
    assert_equal [ nil, nil ], contexts.selections
  end

  def test_local_token_administration_and_runtime_actions_identify_their_authority
    policy = Hive::Remote::CommandPolicy
    assert_equal "local-server-token-registry", policy.target_for("token", %w[token create])
    assert_equal "local-client-configuration", policy.target_for("context", %w[context add nas])
    %w[status projects payloads].each { |action| refute policy.mutation?("runtime", [ "runtime", action ]) }
    assert policy.mutation?("runtime", %w[runtime future-repair])
    assert policy.mutation?("answer", %w[answer demo:task --binding opaque])
    refute policy.mutation?("answer", %w[answer demo:task --json])
    assert_equal "demo:task", policy.target_for("act", %w[act workflow.advance demo:task --project demo])
    assert_equal "demo:task", policy.target_for("act", %w[act --observation opaque workflow.advance task --project demo])
    assert_equal "demo:task", policy.target_for("answer", %w[answer --binding opaque task --project demo])
    assert_equal "demo:task", policy.target_for("approve", %w[approve --generation opaque task --project demo])
    assert policy.mutation?("context", %w[--json context use nas])
    assert policy.mutation?("token", %w[--json token revoke public-id])
    assert_equal "demo:task", policy.target_for("act", %w[--json act --observation opaque workflow.advance task --project demo])
  end

  def test_local_administration_and_diagnostic_read_modes_have_explicit_mutation_policy
    policy = Hive::Remote::CommandPolicy
    refute policy.mutation?("status", %w[status --diagnose task])
    assert policy.mutation?("status", %w[status --diagnose task --write])
    refute policy.mutation?("archive", %w[archive --json])
    assert policy.mutation?("archive", %w[archive demo:task])
    refute policy.mutation?("patrol", %w[patrol --list])
    assert policy.mutation?("patrol", %w[patrol --project demo])
    refute policy.mutation?("refactor-patrol", %w[refactor-patrol --show sample])
    refute policy.mutation?("digest", %w[--json digest show])
    assert policy.mutation?("digest", %w[--json digest prune])
  end

  def test_context_override_is_removed_once_and_literal_tail_is_preserved
    contexts = fixed_contexts({ "name" => "local", "type" => "local" })
    output = StringIO.new
    invocation = Hive::Remote::CommandPolicy.preflight!(
      %w[new project --context local -- words --context literal], contexts: contexts, stderr: output
    )
    assert_equal %w[new project -- words --context literal], invocation.argv
    assert_match(/context=local.*authority=unrestricted-local-operator.*target=project/, output.string)
    assert_equal [ "local" ], contexts.selections
  end

  def test_supported_remote_invocation_never_uses_local_command_adapter
    contexts = fixed_contexts(remote)
    dispatcher = lambda do |invocation|
      assert_equal remote, invocation.context
      assert_equal %w[status --json], invocation.argv
      :transport_result
    end
    invocation = Hive::Remote::CommandPolicy.preflight!(%w[status --json], contexts: contexts, dispatcher: dispatcher)
    assert invocation.handled?
    assert_equal :transport_result, invocation.result
    assert_equal [ nil ], contexts.selections
  end

  def test_remote_help_remains_client_side_and_new_literal_help_stays_text
    contexts = fixed_contexts(remote)
    [ %w[init --help], %w[--help init], %w[--json task --help] ].each do |argv|
      invocation = Hive::Remote::CommandPolicy.preflight!(argv, contexts: contexts)
      assert_equal "help", invocation.command
      refute invocation.handled?
    end
    assert_raises(Hive::UsageError) do
      Hive::Remote::CommandPolicy.preflight!(%w[new project describe --help literally], contexts: contexts)
    end
  end

  def test_native_wrappers_reject_remote_commands_before_runtime_activation_or_project_discovery
    Dir.mktmpdir("hive-context-wrappers") do |root|
      client_home = File.join(root, "client")
      checkout = File.join(root, "unrelated-checkout")
      FileUtils.mkdir_p(checkout)
      File.write(File.join(checkout, "sentinel"), "unchanged")
      contexts = Hive::ConnectionContexts.new(
        root: File.join(client_home, "connections"),
        verifier: ->(*) { { "instance_id" => "server-1", "api_version" => "v1" } }
      )
      contexts.add("nas", url: "https://nas.example", token: "never-print-this-bearer")
      contexts.use("nas")
      hive = File.expand_path("../../../bin/hive", __dir__)
      hv = File.expand_path("../../../bin/hv", __dir__)
      environment = { "HIVE_HOME" => client_home, "HIVE_BIN_OVERRIDE" => hive }
      [ hive, hv ].each do |wrapper|
        [ %w[init .], %w[unknown] ].each do |arguments|
          stdout, stderr, status = Open3.capture3(environment, wrapper, *arguments, chdir: checkout)
          refute status.success?, [ wrapper, arguments ].inspect
          assert_match(/--context local/, stderr)
          assert_empty stdout
          refute_includes stderr, "never-print-this-bearer"
          refute File.exist?(File.join(client_home, "runtime-control-plane.sqlite3"))
          assert_equal [ "sentinel" ], Dir.children(checkout)
          assert_equal "unchanged", File.read(File.join(checkout, "sentinel"))
        end
        stdout, stderr, status = Open3.capture3(environment, wrapper, "--context", "local", "version", chdir: checkout)
        assert status.success?, stderr
        assert_equal Hive::VERSION, stdout.strip
      end
    end
  end

  def test_context_after_new_prose_selects_the_remote_installation
    contexts = fixed_contexts(remote)
    dispatcher = lambda do |invocation|
      assert_equal %w[new myproj idea], invocation.argv
      :remote_capture
    end
    invocation = Hive::Remote::CommandPolicy.preflight!(
      %w[new myproj idea --context nas], contexts: contexts, dispatcher: dispatcher
    )
    assert invocation.handled?
    assert_equal :remote_capture, invocation.result
    assert_equal [ "nas" ], contexts.selections
    assert_equal %w[hive new myproj idea --context nas],
      Hive::CliArgvPolicy.local_child_argv(%w[hive new myproj idea --context nas])
  end

  def test_context_inside_new_prose_is_literal_for_policy_and_child_wrappers
    argv = %w[new myproj -- add a --context flag to the CLI]
    assert_equal [ argv, nil ], Hive::CliArgvPolicy.extract_context(argv)
    assert_equal [ argv, "nas" ], Hive::CliArgvPolicy.extract_context([ "--context", "nas", *argv ])
    assert_equal [ "hive", "--context", "local", *argv ], Hive::CliArgvPolicy.local_child_argv([ "hive", *argv ])
    assert_equal %w[new myproj -- add a --context flag to the CLI],
      Hive::CliArgvPolicy.lift_new_options(argv, value_options: %w[--workflow --context])
  end

  private

  def fixed_contexts(value)
    Struct.new(:context, :selections) do
      def resolve(name: nil)
        selections << name
        context
      end
    end.new(value, [])
  end

  def remote
    { "name" => "nas", "type" => "remote", "url" => "https://nas.example", "instance_id" => "server-1" }
  end
end
