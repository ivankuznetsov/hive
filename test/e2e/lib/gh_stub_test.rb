require_relative "../../test_helper"
require "json"
require "open3"
require_relative "gh_stub"
require_relative "paths"
require_relative "sandbox_env"

class E2EGhStubTest < Minitest::Test
  def invoke(stub, *args, chdir: Dir.pwd, extra_env: {})
    Open3.capture3(
      { "HIVE_E2E_GH_STUB_DIR" => stub.root }.merge(extra_env),
      Hive::E2E::Paths.gh_shim,
      *args,
      chdir: chdir
    )
  end

  def test_consumes_ordered_responses_and_audits_cwd_and_repository
    Dir.mktmpdir("gh-stub-home") do |home|
      Dir.mktmpdir("gh-stub-cwd") do |cwd|
        stub = Hive::E2E::GhStub.new(home)
        stub.install([
          {
            "args" => [ "pr", "view", "7", "--repo", "github.example/acme/widgets" ],
            "cwd" => cwd,
            "repository" => "github.example/acme/widgets",
            "response" => { "state" => "OPEN", "isDraft" => true }
          },
          {
            "args" => [ "pr", "view", "7", "--json", "state" ],
            "response" => { "state" => "MERGED" },
            "stderr" => "staged warning\n",
            "exit_status" => 0
          }
        ])

        out, err, status = invoke(
          stub, "pr", "view", "7", "--repo", "github.example/acme/widgets", chdir: cwd
        )
        assert status.success?
        assert_equal({ "state" => "OPEN", "isDraft" => true }, JSON.parse(out))
        assert_empty err

        out, err, status = invoke(stub, "pr", "view", "7", "--json", "state")
        assert status.success?
        assert_equal({ "state" => "MERGED" }, JSON.parse(out))
        assert_equal "staged warning\n", err

        stub.verify!
        audit = stub.audit
        assert_equal 2, audit.size
        assert audit.all? { |entry| entry.fetch("matched") }
        assert_equal cwd, audit.first.fetch("cwd")
        assert_equal "github.example/acme/widgets", audit.first.fetch("repository")
      end
    end
  end

  def test_absent_mismatched_and_exhausted_scripts_fail_closed_without_fallback
    Dir.mktmpdir("gh-stub-home") do |home|
      stub = Hive::E2E::GhStub.new(home)

      _out, err, status = invoke(stub, "auth", "status")
      refute status.success?
      assert_match(/no scripted interactions/, err)
      assert_equal false, stub.audit.last.fetch("matched")

      stub.install([ { "args" => [ "pr", "view", "7" ], "response" => { "state" => "OPEN" } } ])
      _out, err, status = invoke(stub, "pr", "close", "7")
      refute status.success?
      assert_match(/argv mismatch/, err)
      assert_equal 0, JSON.parse(File.read(stub.state_path)).fetch("next_index")

      invoke(stub, "pr", "view", "7")
      _out, err, status = invoke(stub, "pr", "view", "7")
      refute status.success?
      assert_match(/script exhausted/, err)
      assert_raises(Hive::E2E::GhStub::VerificationError) { stub.verify! }
    end
  end

  def test_rejects_invalid_interaction_definitions_before_writing_script
    Dir.mktmpdir("gh-stub-home") do |home|
      stub = Hive::E2E::GhStub.new(home)

      assert_raises(ArgumentError) { stub.install([ { "args" => "auth status" } ]) }
      assert_raises(ArgumentError) do
        stub.install([ { "args" => [ "auth", "status" ], "stdout" => "ok", "response" => {} } ])
      end
      refute File.exist?(stub.script_path)
    end
  end

  def test_infers_repository_identity_from_the_checkout_origin
    Dir.mktmpdir("gh-stub-home") do |home|
      Dir.mktmpdir("gh-stub-repo") do |repo|
        system("git", "-C", repo, "init", "--quiet", exception: true)
        system("git", "-C", repo, "remote", "add", "origin", "git@github.example:acme/widgets.git", exception: true)
        stub = Hive::E2E::GhStub.new(home)
        stub.install([
          { "args" => [ "pr", "view", "7" ], "repository" => "github.example/acme/widgets" }
        ])

        original_repo = ENV["GH_REPO"]
        original_host = ENV["GH_HOST"]
        ENV["GH_REPO"] = "attacker/spoofed"
        ENV["GH_HOST"] = "github.attacker.example"
        File.write(File.join(repo, "Gemfile"), "source \"https://rubygems.org\"\n")
        Hive::E2E::SandboxEnv.with(repo, home) do |env|
          _out, err, status = invoke(stub, "pr", "view", "7", chdir: repo, extra_env: env)

          assert status.success?, err
        end

        assert_equal "github.example/acme/widgets", stub.audit.first.fetch("repository")
        assert_equal "cwd_origin", stub.audit.first.fetch("repository_source")
      ensure
        ENV["GH_REPO"] = original_repo
        ENV["GH_HOST"] = original_host
      end
    end
  end

  def test_rejected_call_cannot_be_erased_by_installing_a_later_script
    Dir.mktmpdir("gh-stub-home") do |home|
      stub = Hive::E2E::GhStub.new(home)

      _out, _err, status = invoke(stub, "auth", "status")
      refute status.success?

      stub.install([ { "args" => [ "version" ], "stdout" => "gh version synthetic\n" } ])
      _out, _err, status = invoke(stub, "version")
      assert status.success?

      error = assert_raises(Hive::E2E::GhStub::VerificationError) { stub.verify! }
      assert_match(/rejected 1 invocation/, error.message)
      assert_equal [ false, true ], stub.audit.map { |entry| entry.fetch("matched") }
    end
  end

  def test_second_script_install_is_rejected_instead_of_replacing_evidence
    Dir.mktmpdir("gh-stub-home") do |home|
      stub = Hive::E2E::GhStub.new(home)
      stub.install([ { "args" => [ "version" ] } ])

      error = assert_raises(ArgumentError) do
        stub.install([ { "args" => [ "auth", "status" ] } ])
      end

      assert_match(/already installed/, error.message)
      assert_equal [ "version" ], JSON.parse(File.read(stub.script_path)).dig("interactions", 0, "args")
    end
  end
end
