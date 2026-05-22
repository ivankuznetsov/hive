require "test_helper"
require "hive/commands/finding_toggle"

class HiveCommandsFindingToggleTest < Minitest::Test
  FakeFinding = Struct.new(:id, :severity, :accepted)
  FakeDoc = Struct.new(:findings, :path, :summary)
  FakeTask = Struct.new(:slug, :stage_index, :stage_name, :folder, :hive_state_path, :project_root)

  def command(operation: Hive::Commands::FindingToggle::ACCEPT, **kwargs)
    Hive::Commands::FindingToggle.new(operation, "slug", **kwargs)
  end

  def task
    FakeTask.new("slug-260522-abcd", 4, "execute", "/tmp/task", "/tmp/state", "/tmp/project")
  end

  def test_call_wraps_internal_errors_with_json_envelope
    cmd = command(json: true)
    cmd.define_singleton_method(:do_call) { raise RuntimeError, "boom" }
    error = nil

    out, _err = capture_io do
      error = assert_raises(Hive::InternalError) { cmd.call }
    end

    assert_match(/internal error: RuntimeError: boom/, error.message)
    payload = JSON.parse(out)
    assert_equal "hive-findings", payload.fetch("schema")
    assert_equal "error", payload.fetch("error_kind")
    assert_equal "accept", payload.fetch("operation")
  end

  def test_call_wraps_internal_errors_without_json_envelope
    cmd = command(json: false)
    cmd.define_singleton_method(:do_call) { raise RuntimeError, "boom" }

    out, _err = capture_io do
      error = assert_raises(Hive::InternalError) { cmd.call }
      assert_match(/internal error: RuntimeError: boom/, error.message)
    end

    assert_equal "", out
  end

  def test_no_selection_message_for_all_with_empty_review
    doc = FakeDoc.new([], "/tmp/reviews/ce-review-02.md", nil)

    assert_equal "review file has no findings: /tmp/reviews/ce-review-02.md",
                 command(all: true).send(:no_selection_message, doc)
  end

  def test_no_selection_message_for_missing_severity_reports_available_values
    doc = FakeDoc.new(
      [ FakeFinding.new(1, "high", false), FakeFinding.new(2, "low", false) ],
      "/tmp/reviews/ce-review-02.md",
      nil
    )

    message = command(severity: "medium").send(:no_selection_message, doc)

    assert_includes message, "no findings with severity 'medium'"
    assert_includes message, %(["high", "low"])
  end

  def test_render_text_reports_noop_for_already_matching_findings
    out, err = capture_io do
      command(operation: Hive::Commands::FindingToggle::REJECT).send(
        :render_text,
        task,
        "/tmp/state/stages/4-execute/slug/reviews/ce-review-02.md",
        [ 1 ],
        []
      )
    end

    assert_includes out, "hive: rejected 0/1 finding(s) in ce-review-02.md"
    assert_includes out, "no-op: every selected finding was already rejected"
    assert_equal "", err
  end

  def test_next_action_handles_no_findings_and_no_accepted_findings
    no_findings = FakeDoc.new([], nil, { "accepted" => 0, "total" => 0 })
    none_accepted = FakeDoc.new([], nil, { "accepted" => 0, "total" => 2 })

    assert_equal({ "kind" => Hive::Schemas::NextActionKind::NO_OP, "reason" => "no findings" },
                 command.send(:next_action, task, no_findings))

    action = command.send(:next_action, task, none_accepted)
    assert_equal Hive::Schemas::NextActionKind::RUN, action.fetch("kind")
    assert_equal "no accepted findings; re-run to mark execute_complete", action.fetch("reason")
    assert_equal "hive develop slug-260522-abcd --from 4-execute", action.fetch("command")
  end

  def test_error_kind_for_covers_finding_toggle_specific_errors
    cmd = command

    assert_equal "ambiguous_slug", cmd.send(
      :error_kind_for,
      Hive::AmbiguousSlug.new("ambiguous", slug: "slug", candidates: [])
    )
    assert_equal "no_review_file", cmd.send(:error_kind_for, Hive::NoReviewFile.new("none"))
    assert_equal "no_selection", cmd.send(:error_kind_for, Hive::NoSelection.new("none"))
    assert_equal "rollback_failed", cmd.send(:error_kind_for, Hive::RollbackFailed.new("rollback failed"))
    assert_equal "invalid_task_path", cmd.send(:error_kind_for, Hive::InvalidTaskPath.new("bad"))
    assert_equal "error", cmd.send(:error_kind_for, Hive::Error.new("generic"))
  end

  def test_rollback_messages_include_underlying_and_rollback_errors
    cmd = command
    captured = {}
    original = Hive::CommitOrRollback.singleton_class.instance_method(:attempt!)
    Hive::CommitOrRollback.define_singleton_method(:attempt!) do |_error, on_undo:, rolled_back_message:, rollback_failed_message:|
      captured[:rolled_back] = rolled_back_message.call(StandardError.new("commit nope"))
      captured[:rollback_failed] = rollback_failed_message.call(
        StandardError.new("commit nope"),
        StandardError.new("undo nope")
      )
      on_undo
    end

    cmd.send(:rollback_review_change!, task, "/tmp/state/reviews/ce-review-02.md", "original", Hive::GitError.new("commit"))

    assert_includes captured.fetch(:rolled_back), "underlying: StandardError: commit nope"
    assert_includes captured.fetch(:rollback_failed), "rollback error: StandardError: undo nope"
  ensure
    Hive::CommitOrRollback.singleton_class.define_method(:attempt!, original) if original
  end

  def test_commit_change_skips_commit_when_index_has_no_diff
    cmd = command
    calls = []
    fake_ops = Object.new
    fake_ops.define_singleton_method(:run_git!) { |*args| calls << args }
    original_git_ops = Hive::GitOps.singleton_class.instance_method(:new)
    original_capture3 = Open3.singleton_class.instance_method(:capture3)
    status = Object.new
    status.define_singleton_method(:success?) { true }

    Hive::GitOps.define_singleton_method(:new) { |_project_root| fake_ops }
    Open3.define_singleton_method(:capture3) { |*_args| [ "", "", status ] }

    cmd.send(:commit_change, task, "/tmp/state/reviews/ce-review-02.md", [ { "id" => 7 } ])

    assert_equal 1, calls.size
    assert_equal [ "-C", "/tmp/state", "add", "--", "reviews/ce-review-02.md" ], calls.first
  ensure
    Hive::GitOps.singleton_class.define_method(:new, original_git_ops) if original_git_ops
    Open3.singleton_class.define_method(:capture3, original_capture3) if original_capture3
  end
end
