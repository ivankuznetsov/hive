require "test_helper"
require "hive/commands/proposal"

class ProposalCommandTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:project_root, :folder, keyword_init: true)

  def test_submit_reads_a_bounded_regular_artifact_and_does_not_accept_actor_spoofing
    with_tmp_dir do |dir|
      task = FakeTask.new(project_root: dir, folder: File.join(dir, ".hive-state", "stages", "4-execute", "task"))
      FileUtils.mkdir_p(task.folder)
      input = File.join(dir, "candidate.json")
      File.write(input, JSON.generate(
        "proposed_change" => "Change review", "motivation" => "Improve recall",
        "evidence" => [ { "label" => "test", "content" => "pass", "media_type" => "text/plain" } ]
      ))
      calls = []
      result = Struct.new(:proposal_id, :source_event_id, :source_commit, :ingestion).new(
        "prp-00000000-0000-4000-8000-000000000001", "pse-#{'a' * 64}", "b" * 40,
        Struct.new(:kind, :event_id).new("record", nil)
      )
      producer = Object.new
      producer.define_singleton_method(:submit) { |**attributes| calls << attributes; result }
      output = StringIO.new

      Hive::Commands::Proposal.new(
        "submit", "task", input: input, json: true, stdout: output,
        task_resolver: ->(_target, _project) { task },
        producer_factory: ->(_task) { producer }, reconciler: ->(_task) { }
      ).call

      assert_equal 1, calls.length
      assert_equal "candidate.json", calls.first.dig(:artifact, "reference")
      assert_equal Digest::SHA256.file(input).hexdigest, calls.first.dig(:artifact, "digest")
      assert_equal true, JSON.parse(output.string).fetch("ok")

      File.write(input, JSON.generate(
        "proposed_change" => "Change review", "motivation" => "Improve recall",
        "evidence" => [], "actor" => "mallory"
      ))
      error = assert_raises(Hive::Proposals::InvalidRecord) do
        Hive::Commands::Proposal.new(
          "submit", "task", input: input,
          task_resolver: ->(_target, _project) { task },
          producer_factory: ->(_task) { producer }, reconciler: ->(_task) { }
        ).call
      end
      assert_match(/unknown fields: actor/, error.message)
    end
  end

  def test_rejects_symlinked_oversize_and_missing_source_artifacts_before_production
    with_tmp_dir do |dir|
      task = FakeTask.new(project_root: dir, folder: dir)
      real = File.join(dir, "real.json")
      link = File.join(dir, "link.json")
      File.write(real, "{}")
      File.symlink(real, link)
      factory = ->(_task) { flunk "producer must not be constructed" }

      error = assert_raises(Hive::Proposals::InvalidRecord) do
        Hive::Commands::Proposal.new(
          "submit", "task", input: link,
          task_resolver: ->(_target, _project) { task }, producer_factory: factory,
          reconciler: ->(_task) { }
        ).call
      end
      assert_match(/regular non-symlink/, error.message)

      File.write(real, "x" * (Hive::Commands::Proposal::MAX_INPUT_BYTES + 1))
      assert_match(/exceeds/, assert_raises(Hive::Proposals::InvalidRecord) do
        Hive::Commands::Proposal.new(
          "submit", "task", input: real,
          task_resolver: ->(_target, _project) { task }, producer_factory: factory,
          reconciler: ->(_task) { }
        ).call
      end.message)
    end
  end

  def test_refresh_compile_only_and_check_use_pinned_external_outputs
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      output = File.join(@tmpdir || Dir.tmpdir, "proposal-compiled-#{SecureRandom.hex(4)}")
      command_output = StringIO.new
      result = Hive::Commands::Proposal.new(
        "refresh", dir, input: nil, compile_only: true,
        source_ref: ops.hive_state_head_sha, output_root: output,
        json: true, stdout: command_output
      ).call

      assert_equal ops.hive_state_head_sha, result.source_commit
      assert File.file?(File.join(output, "wiki", "proposals.json"))
      assert_equal "compiled", JSON.parse(command_output.string).fetch("outcome")
      FileUtils.mkdir_p(File.join(dir, "wiki"))
      FileUtils.cp(File.join(output, "wiki", "proposals.json"), File.join(dir, "wiki"))
      FileUtils.cp(File.join(output, "wiki", "proposals.md"), File.join(dir, "wiki"))

      checked = Hive::Commands::Proposal.new(
        "refresh", dir, input: nil, check: true, stdout: StringIO.new
      ).call
      assert_equal ops.hive_state_head_sha, checked.source_commit

      File.write(File.join(dir, "wiki", "proposals.md"), "stale\n")
      assert_raises(Hive::Proposals::StaleObservation) do
        Hive::Commands::Proposal.new(
          "refresh", dir, input: nil, check: true, stdout: StringIO.new
        ).call
      end
      refute Dir.children(dir).any? { |name| name.start_with?("hive-proposal-refresh-check-") }
    end
  end

  def test_refresh_without_check_enters_the_managed_publication_boundary
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      calls = []
      result = Hive::Commands::Proposal.new(
        "refresh", dir, input: nil, stdout: StringIO.new,
        refresh_runner: ->(project_root, git_ops) { calls << [ project_root, git_ops.hive_state_path ] }
      ).call

      assert_equal "queued", result.fetch("outcome")
      assert_equal [ [ dir, ops.hive_state_path ] ], calls
    end
  end
end
