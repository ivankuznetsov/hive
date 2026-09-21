require "test_helper"
require "rbconfig"
require "hive/task_workspace/publication"

class TaskWorkspacePublicationCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Task = Data.define(:folder, :project_root, :slug)
  Status = Hive::TaskWorkspace::Publication::Status

  class BadIo
    def closed? = false
    def close = raise(IOError, "close failed")
  end

  def test_pointer_failures_and_default_reader_are_explicit
    with_service do |subject, folder, worktrees|
      assert_kind_of Numeric, subject.instance_variable_get(:@monotonic_clock).call
      diagnostics = []
      assert_nil subject.send(:read_pointer, diagnostics)
      assert_equal "pointer_identity_mismatch", diagnostics.last.fetch("reason")

      subject.instance_variable_set(:@pointer_reader, -> { strict_pointer(worktrees).merge("repository" => "github.com/other/repo") })
      diagnostics = []
      assert_nil subject.send(:read_pointer, diagnostics)
      assert_equal "repository_mismatch", diagnostics.last.fetch("reason")

      subject.instance_variable_set(
        :@pointer_reader,
        -> { raise Hive::TaskWorkspace::SourceError.new(source: "worktree_receipt", reason: "missing") }
      )
      diagnostics = []
      assert_nil subject.send(:read_pointer, diagnostics)
      assert_equal "missing", diagnostics.last.fetch("reason")

      subject.instance_variable_set(:@pointer_reader, -> { raise "unexpected" })
      assert_equal "unavailable", subject.call.fetch("state")

      subject.instance_variable_set(:@pointer_reader, nil)
      File.write(File.join(folder, "worktree.yml"), YAML.dump(strict_pointer(worktrees)))
      assert_equal "demo", subject.send(:read_pointer, []).fetch("branch")
    end
  end

  def test_pointer_file_rejects_truncation_duplicates_shapes_and_yaml
    with_service(pointer: nil) do |subject, folder, worktrees|
      cases = {
        "path: a\npath: b\nbranch: demo\n" => "pointer_duplicate_keys",
        "- item\n" => "pointer_shape_invalid",
        "path: [\n" => "pointer_yaml_invalid"
      }
      cases.each do |content, reason|
        File.write(File.join(folder, "worktree.yml"), content)
        error = assert_raises(Hive::TaskWorkspace::SourceError) do
          subject.send(:read_pointer_file)
        end
        assert_equal reason, error.reason
      end

      File.binwrite(File.join(folder, "worktree.yml"), "path: #{worktrees}/demo\nbranch: demo\n\0")
      error = assert_raises(Hive::TaskWorkspace::SourceError) do
        subject.send(:read_pointer_file)
      end
      assert_equal "pointer_truncated", error.reason
    end
  end

  def test_local_observation_and_git_helpers_fail_soft
    with_service do |subject, _folder, worktrees|
      pointer = strict_pointer(worktrees)
      diagnostics = []

      values = [ "/git/project", "/git/other", "worktree #{worktrees}/demo\n" ]
      with_replaced_singleton_method(subject, :git_value, ->(*, **) { values.shift }) do
        local = subject.send(:observe_local, pointer, diagnostics)
        assert_equal "unavailable", local.fetch("state")
        assert_equal "worktree_ownership_mismatch", diagnostics.last.fetch("reason")
      end

      responses = [ "/git/common", "/git/common", "worktree #{worktrees}/demo\n", "d" * 40, "other" ]
      with_replaced_singleton_method(subject, :git_value, ->(*, **) { responses.shift.to_s }) do
        with_replaced_singleton_method(subject, :observe_base_ref, ->(*) { nil }) do
          with_replaced_singleton_method(subject, :observe_base, ->(*) { "ancestor" }) do
            with_replaced_singleton_method(subject, :observe_commits, ->(*) { [] }) do
              with_replaced_singleton_method(subject, :observe_tracking, ->(*) { { "state" => "pushed" } }) do
                local = subject.send(:observe_local, pointer, diagnostics)
                assert_equal "other", local.fetch("branch")
                assert_includes diagnostics.map { |row| row["reason"] }, "branch_mismatch"
              end
            end
          end
        end
      end

      error = Hive::TaskWorkspace::SourceError.new(source: "local_git", reason: "read_failed")
      with_replaced_singleton_method(subject, :git_capture, ->(*) { raise error }) do
        assert_nil subject.send(:observe_base_ref, "/tmp", "main", diagnostics)
        assert_empty subject.send(:observe_commits, "/tmp", "a" * 40, "b" * 40, diagnostics)
        assert_equal "unavailable",
                     subject.send(:observe_tracking, "/tmp", "demo", "b" * 40, diagnostics).fetch("state")
      end

      invalid_status = Status.new(success?: true, exitstatus: 0)
      with_replaced_singleton_method(
        subject, :git_capture, ->(*) { [ "invalid", "", invalid_status, {} ] }
      ) do
        assert_equal "unavailable",
                     subject.send(:observe_tracking, "/tmp", "demo", "b" * 40, diagnostics).fetch("state")
      end
      divergent = Status.new(success?: false, exitstatus: 1)
      with_replaced_singleton_method(
        subject, :git_capture, ->(*) { [ "", "", divergent, {} ] }
      ) do
        assert_equal "divergent",
                     subject.send(:observe_base, "/tmp", "a" * 40, "b" * 40, diagnostics)
      end
      calls = 0
      with_replaced_singleton_method(subject, :git_capture, lambda { |*|
        calls += 1
        [ calls == 1 ? "a" * 40 : "bad counts", "", invalid_status, {} ]
      }) do
        assert_equal "unavailable",
                     subject.send(:observe_tracking, "/tmp", "demo", "b" * 40, diagnostics).fetch("state")
      end
    end
  end

  def test_pr_reader_and_frontmatter_failures_are_bounded
    with_service do |subject, folder, worktrees|
      pointer = strict_pointer(worktrees)
      diagnostics = []

      File.binwrite(File.join(folder, "pr.md"), "\0binary")
      assert_equal "unavailable", subject.send(:read_pr, pointer, diagnostics).fetch("state")

      File.write(File.join(folder, "pr.md"), "# No identity\n")
      assert_equal "partial", subject.send(:read_pr, pointer, diagnostics).fetch("state")

      duplicate = "---\npr_url: a\npr_url: b\n---\nbody\n"
      assert_equal({}, subject.send(:parse_pr_document, duplicate, diagnostics).first)
      shape = "---\n- item\n---\nbody\n"
      assert_equal({}, subject.send(:parse_pr_document, shape, diagnostics).first)
      invalid = "---\nkey: [\n---\nbody\n"
      assert_equal({}, subject.send(:parse_pr_document, invalid, diagnostics).first)

      FileUtils.rm_f(File.join(folder, "pr.md"))
      File.write(File.join(folder, "linked-pr"), "body")
      File.symlink(File.join(folder, "linked-pr"), File.join(folder, "pr.md"))
      assert_equal "unavailable", subject.send(:read_pr, pointer, diagnostics).fetch("state")
    end
  end

  def test_publication_states_deadlines_bytes_and_runner_failures
    with_service do |subject, _folder, _worktrees|
      local = { "state" => "current", "base_branch" => "main", "push" => { "state" => "pushed" } }
      pr = { "state" => "current" }
      remote = { "observation" => { "state" => "OPEN", "base_branch" => "other" } }
      assert_equal "remote_base_divergent", subject.send(:publication_state, local, pr, remote)

      subject.instance_variable_set(:@deadline, -1.0)
      assert_equal "local_git_deadline_seconds", assert_raises(Hive::TaskWorkspace::SourceError) {
        subject.send(:git_capture, "/tmp", [ "status" ])
      }.details.fetch("cap")

      subject.instance_variable_set(
        :@deadline, subject.instance_variable_get(:@monotonic_clock).call + 10.0
      )
      subject.instance_variable_set(:@remaining_bytes, 0)
      assert_equal "local_git_bytes", assert_raises(Hive::TaskWorkspace::SourceError) {
        subject.send(:git_capture, "/tmp", [ "status" ])
      }.details.fetch("cap")

      subject.instance_variable_set(:@remaining_bytes, 100)
      subject.instance_variable_set(:@runner, ->(*) { raise "runner failed" })
      assert_equal "git_failed", assert_raises(Hive::TaskWorkspace::SourceError) {
        subject.send(:git_capture, "/tmp", [ "status" ])
      }.reason

      assert_nil subject.send(:canonical_repository, "not github")
      assert_nil subject.send(:valid_time_or_nil, "bad")
    end
  end

  def test_default_runner_maps_missing_binary_close_errors_and_hard_kill
    with_service do |subject, _folder, _worktrees|
      with_replaced_singleton_method(Process, :spawn, ->(*) { raise Errno::ENOENT }) do
        assert_equal "git_missing", assert_raises(Hive::TaskWorkspace::SourceError) {
          subject.send(:run_command, [ "missing" ], timeout_sec: 1, max_bytes: 10)
        }.reason
      end

      pipes = [ [ BadIo.new, BadIo.new ], [ BadIo.new, BadIo.new ] ]
      with_replaced_singleton_method(IO, :pipe, -> { pipes.shift }) do
        with_replaced_singleton_method(Process, :spawn, ->(*) { raise Errno::ENOENT }) do
          assert_raises(Hive::TaskWorkspace::SourceError) do
            subject.send(:run_command, [ "missing" ], timeout_sec: 1, max_bytes: 10)
          end
        end
      end

      monotonic = Process.method(:clock_gettime)
      subject.instance_variable_set(
        :@monotonic_clock, -> { monotonic.call(Process::CLOCK_MONOTONIC) }
      )
      error = assert_raises(Hive::TaskWorkspace::SourceError) do
        subject.send(
          :run_command,
          [ RbConfig.ruby, "-e", "trap('TERM') {}; loop { sleep 1 }" ],
          timeout_sec: 0.01, max_bytes: 16
        )
      end
      assert_equal "limit_exhausted", error.reason
      assert_nil subject.send(:terminate_group, 2_000_000_000)

      kills = []
      ticks = [ 0.0, 1.0 ]
      subject.instance_variable_set(:@monotonic_clock, -> { ticks.shift || 1.0 })
      with_replaced_singleton_method(Process, :kill, ->(signal, pid) { kills << [ signal, pid ] }) do
        with_replaced_singleton_method(Process, :waitpid2, ->(*) { nil }) do
          assert_nil subject.send(:terminate_group, 123)
        end
      end
      assert_equal [ [ "TERM", -123 ], [ "KILL", -123 ] ], kills
    end
  end

  private

  def with_service(pointer: :default)
    with_tmp_dir do |root|
      folder = File.join(root, "task")
      worktrees = File.join(root, "worktrees")
      FileUtils.mkdir_p([ folder, worktrees ])
      task = Task.new(folder, root, "demo")
      pointer_reader = if pointer == :default
        -> { strict_pointer(worktrees).merge("branch" => "other") }
      end
      subject = Hive::TaskWorkspace::Publication.new(
        task: task, expected_repository: "github.com/acme/demo",
        expected_root: worktrees, pointer_reader: pointer_reader,
        runner: ->(*) { raise "unused" }
      )
      yield subject, folder, worktrees
    end
  end

  def strict_pointer(worktrees)
    {
      "path" => File.join(worktrees, "demo"), "branch" => "demo",
      "base_branch" => "main", "base_oid" => "c" * 40,
      "repository" => "github.com/acme/demo"
    }
  end
end
