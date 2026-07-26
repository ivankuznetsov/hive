require "test_helper"
require "hive/web/task_diff"

class WebTaskDiffTest < Minitest::Test
  FakeTask = Data.define(:folder, :project_root, :slug)
  Status = Data.define(:success?, :exitstatus)

  class ScriptedRunner
    attr_reader :argv

    def initialize(results)
      @results = results.dup
      @argv = []
    end

    def call(argv, **)
      @argv << argv
      @results.shift || [ "", "", Status.new(success?: true, exitstatus: 0) ]
    end
  end

  def task
    FakeTask.new(folder: "/tasks/demo", project_root: "/repo", slug: "demo")
  end

  def pointer
    {
      "path" => "/repo.worktrees/demo",
      "branch" => "demo",
      "execute_base_head" => "a" * 40
    }
  end

  def service(results, **options)
    runner = ScriptedRunner.new(results)
    instance = Hive::Web::TaskDiff.new(
      task: task,
      expected_root: "/repo.worktrees",
      pointer_reader: ->(**) { pointer },
      runner: runner,
      **options
    )
    [ instance, runner ]
  end

  def ok(output = "")
    [ output, "", Status.new(success?: true, exitstatus: 0) ]
  end

  def test_empty_output_is_a_mutable_typed_empty_result
    diff, = service([ ok, ok, ok, ok ])

    result = diff.call

    assert_equal "empty", result.state
    assert_equal 200, result.http_status
    result.sections.each_value do |content|
      refute content.frozen?
      assert_equal "", content
    end
  end

  def test_committed_staged_unstaged_and_untracked_layers_remain_distinct
    diff, runner = service([
      ok("committed\n"),
      ok("staged\n"),
      ok("unstaged\n"),
      ok("new.txt\0nested/other.txt\0")
    ])

    result = diff.call

    assert_equal "available", result.state
    assert_equal "committed\n", result.sections.fetch("committed")
    assert_equal "staged\n", result.sections.fetch("staged")
    assert_equal "unstaged\n", result.sections.fetch("unstaged")
    assert_equal "new.txt\nnested/other.txt\n", result.sections.fetch("untracked")
    assert runner.argv.all? { |argv| argv.is_a?(Array) }
    assert runner.argv.flatten.include?("--no-ext-diff")
  end

  def test_oversized_output_is_capped_and_marked_truncated
    diff, = service(
      [ ok("x" * 33), ok, ok, ok ],
      max_bytes: 32
    )

    result = diff.call

    assert_equal "truncated", result.state
    assert_equal 32, result.sections.fetch("committed").bytesize
    assert result.truncated
  end

  def test_invalid_encoding_and_secrets_are_scrubbed_and_redacted
    invalid = "token=ghp_abcdefghijklmnopqrstuvwxyz1234567890\xff".b
    diff, = service([ ok(invalid), ok, ok, ok ])

    result = diff.call

    assert_equal "truncated", result.state
    assert result.invalid_encoding
    refute_includes result.sections.fetch("committed"), "ghp_"
    assert_includes result.sections.fetch("committed"), "\uFFFD"
  end

  def test_missing_git_timeout_and_nonzero_exit_are_typed
    {
      Hive::Web::TaskDiff::MissingBinary.new("missing") => [ "unavailable", 503, "git_missing" ],
      Hive::Web::TaskDiff::CommandTimeout.new("timeout") => [ "unavailable", 504, "git_timeout" ]
    }.each do |failure, expected|
      runner = ->(*) { raise failure }
      diff = Hive::Web::TaskDiff.new(
        task: task,
        expected_root: "/repo.worktrees",
        pointer_reader: ->(**) { pointer },
        runner: runner
      )

      result = diff.call
      assert_equal expected, [ result.state, result.http_status, result.reason ]
    end

    diff, = service([
      [ "", "fatal: auth token ghp_abcdefghijklmnopqrstuvwxyz1234567890", Status.new(success?: false, exitstatus: 1) ]
    ])
    result = diff.call
    assert_equal [ "unavailable", 422, "git_failed" ],
                 [ result.state, result.http_status, result.reason ]
    refute_includes result.diagnostic, "ghp_"
  end

  def test_missing_or_foreign_pointer_is_a_conflict_not_an_exception
    diff = Hive::Web::TaskDiff.new(
      task: task,
      expected_root: "/repo.worktrees",
      pointer_reader: ->(**) { raise Hive::WorktreeError, "worktree.yml is missing" },
      runner: ->(*) { flunk "git must not run" }
    )

    result = diff.call

    assert_equal [ "unavailable", 409, "worktree_unavailable" ],
                 [ result.state, result.http_status, result.reason ]
  end
end
