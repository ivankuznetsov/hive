require "test_helper"
require "rbconfig"
require "hive/process_kill"
require "hive/web/task_diff"

class WebTaskDiffTest < Minitest::Test
  include HiveTestHelper

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
    assert_equal "empty", result.to_h.fetch("state")
    assert_equal result.sections, result.to_h.fetch("sections")
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

  def test_positional_pointer_adapter_and_head_fallback
    calls = []
    positional = lambda do |folder, project_root:, slug:, expected_root:|
      calls << [ folder, project_root, slug, expected_root ]
      pointer.merge("execute_base_head" => nil, "base_oid" => nil)
    end
    runner = ScriptedRunner.new([
      ok("#{'b' * 40}\n"),
      ok("committed\n"), ok, ok, ok
    ])
    diff = Hive::Web::TaskDiff.new(
      task: task,
      expected_root: "/repo.worktrees",
      pointer_reader: positional,
      runner: runner
    )

    result = diff.call

    assert_equal "available", result.state
    assert_equal "committed\n", result.sections.fetch("committed")
    assert_equal(
      [ [ "/tasks/demo", "/repo", "demo", "/repo.worktrees" ] ],
      calls
    )
    assert_includes runner.argv.first, "rev-parse"
  end

  def test_invalid_resolved_head_is_a_typed_git_failure
    diff = Hive::Web::TaskDiff.new(
      task: task,
      expected_root: "/repo.worktrees",
      pointer_reader: ->(**) {
        pointer.merge("execute_base_head" => nil, "base_oid" => nil)
      },
      runner: ScriptedRunner.new([ ok("not-an-oid\n") ])
    )

    result = diff.call

    assert_equal "unavailable", result.state
    assert_equal "git_failed", result.reason
    assert_match(/invalid HEAD identity/, result.diagnostic)
  end

  def test_capture_converts_an_exec_enoent_to_missing_binary
    diff = Hive::Web::TaskDiff.new(
      task: task,
      expected_root: "/repo.worktrees",
      pointer_reader: ->(**) { pointer },
      runner: ->(*) { raise Errno::ENOENT, "git" },
      git_bin: "/missing/git"
    )

    result = diff.call

    assert_equal "git_missing", result.reason
    assert_equal 503, result.http_status
  end

  def test_default_runner_bounds_stdout_and_stderr_and_reports_status
    diff, = service([])
    output, error, status, metadata = diff.send(
      :run_command,
      [
        RbConfig.ruby, "-e",
        "STDOUT.write('o' * 64); STDERR.write('e' * 32); exit 3"
      ],
      timeout_sec: 2,
      max_bytes: 16,
      diagnostic_max_bytes: 8
    )

    assert_equal "o" * 16, output
    assert_equal "e" * 8, error
    refute status.success?
    assert_equal 3, status.exitstatus
    assert metadata.fetch(:stdout_truncated)
    assert metadata.fetch(:stderr_truncated)
  end

  def test_default_runner_reports_missing_binary_and_timeout
    diff, = service([])
    assert_raises(Hive::Web::TaskDiff::MissingBinary) do
      diff.send(
        :run_command, [ "/definitely/missing/hive-git" ],
        timeout_sec: 1, max_bytes: 16, diagnostic_max_bytes: 16
      )
    end

    error = assert_raises(Hive::Web::TaskDiff::CommandTimeout) do
      diff.send(
        :run_command, [ RbConfig.ruby, "-e", "sleep 30" ],
        timeout_sec: 0.01, max_bytes: 16, diagnostic_max_bytes: 16
      )
    end
    assert_match(/timed out/, error.message)
  end

  def test_default_runner_tolerates_an_io_closed_during_final_cleanup
    diff, = service([])
    real_pipe = IO.method(:pipe)
    decorated_reader = nil
    decorated_close = nil
    calls = 0
    replacement = lambda do
      reader, writer = real_pipe.call
      calls += 1
      if calls == 1
        decorated_reader = reader
        decorated_close = reader.method(:close)
        reader.define_singleton_method(:close) { raise IOError, "closed concurrently" }
      end
      [ reader, writer ]
    end

    result = with_replaced_singleton_method(IO, :pipe, replacement) do
      diff.send(
        :run_command, [ RbConfig.ruby, "-e", "print 'ok'" ],
        timeout_sec: 2, max_bytes: 16, diagnostic_max_bytes: 16
      )
    end

    assert_equal "ok", result.first
  ensure
    decorated_close&.call unless decorated_reader&.closed?
  end

  def test_terminate_group_escalates_when_term_is_ignored_and_tolerates_missing_process
    diff, = service([])
    ready_reader, ready_writer = IO.pipe
    pid = Process.spawn(
      RbConfig.ruby, "-e", "trap('TERM') {}; STDOUT.sync = true; puts 'ready'; sleep 30",
      pgroup: true, out: ready_writer, err: File::NULL
    )
    ready_writer.close
    assert_equal "ready\n", Timeout.timeout(2) { ready_reader.gets }

    result = diff.send(:terminate_group, pid)
    assert(result.nil? || result.is_a?(Array))
    refute Hive::ProcessKill.pid_alive?(pid)
    assert_nil diff.send(:terminate_group, 999_999)
  ensure
    ready_reader&.close unless ready_reader&.closed?
    ready_writer&.close unless ready_writer&.closed?
    if pid && Hive::ProcessKill.pid_alive?(pid)
      Process.kill("KILL", -pid) rescue nil
      Process.waitpid(pid) rescue nil
    end
  end
end
