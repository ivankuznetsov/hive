require "test_helper"
require "hive/stages/open_pr"

class HiveStagesOpenPrTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, :state_file, :project_root, :slug, keyword_init: true)
  Scan = Struct.new(:fetch_failed, :fetch_error, :hits, keyword_init: true)


  def make_task(root)
    folder = File.join(root, ".hive-state", "stages", "5-open-pr", "open-pr-task")
    FileUtils.mkdir_p(folder)
    Task.new(
      folder: folder,
      state_file: File.join(folder, "pr.md"),
      project_root: root,
      slug: "open-pr-task"
    )
  end

  def write_pointer(task, worktree_path, branch: task.slug)
    File.write(File.join(task.folder, "worktree.yml"), { "path" => worktree_path, "branch" => branch }.to_yaml)
  end

  def cfg
    { "budget_usd" => {}, "timeout_sec" => {} }
  end

  def with_basic_open_pr_run_stubs(existing_pr: nil, scan: Scan.new(fetch_failed: false, fetch_error: nil, hits: []), &block)
    with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, ->(_cfg) { }) do
      with_replaced_singleton_method(Hive::Gh, :lookup_existing_pr, ->(_worktree_path, _branch, cfg:) { existing_pr }) do
        with_replaced_singleton_method(Hive::Gh, :push_branch!, ->(_worktree_path, _branch, cfg:) { }) do
          with_replaced_singleton_method(Hive::Gh, :scan_pr_for_secrets, ->(state_file:, pr_url:, cfg:) { scan }) do
            with_replaced_singleton_method(Hive::Stages::Base, :stage_profile, ->(_cfg, _stage) { :profile }) do
              with_replaced_singleton_method(Hive::Stages::Base, :render, ->(_template, _bindings) { "prompt" }) do
                yield
              end
            end
          end
        end
      end
    end
  end

  def test_run_lands_error_when_open_pr_agent_tampers_with_protected_files
    with_tmp_dir do |root|
      task = make_task(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      write_pointer(task, worktree)

      with_basic_open_pr_run_stubs do
        with_replaced_singleton_method(Hive::ProtectedFiles, :snapshot, ->(_folder) { Object.new }) do
          with_replaced_singleton_method(Hive::ProtectedFiles, :diff, ->(_before, _after) { [ "worktree.yml" ] }) do
            with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_args, **_kwargs) { }) do
              result = Hive::Stages::OpenPr.run!(task, cfg)

              marker = Hive::Markers.current(task.state_file)
              assert_equal({ commit: "open_pr_tampered", status: :error }, result)
              assert_equal :error, marker.name
              assert_equal "open_pr_tampered", marker.attrs.fetch("reason")
              assert_equal "worktree.yml", marker.attrs.fetch("files")
            end
          end
        end
      end
    end
  end

  def test_run_returns_non_terminal_marker_status_without_rewriting_error
    with_tmp_dir do |root|
      task = make_task(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      write_pointer(task, worktree)

      with_basic_open_pr_run_stubs do
        with_replaced_singleton_method(Hive::ProtectedFiles, :snapshot, ->(_folder) { Object.new }) do
          with_replaced_singleton_method(Hive::ProtectedFiles, :diff, ->(_before, _after) { [] }) do
            with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
              Hive::Markers.set(task.state_file, :review_waiting, reason: "human")
            }) do
              result = Hive::Stages::OpenPr.run!(task, cfg)

              assert_equal({ commit: nil, status: :review_waiting }, result)
              assert_equal :review_waiting, Hive::Markers.current(task.state_file).name
            end
          end
        end
      end
    end
  end

  def test_worktree_pointer_rejects_missing_directory
    with_tmp_dir do |root|
      task = make_task(root)
      write_pointer(task, File.join(root, "missing-worktree"))

      _out, err, status = with_captured_exit do
        Hive::Stages::OpenPr.worktree_pointer_or_exit(task)
      end

      assert_equal 1, status
      assert_match(/worktree pointer .* no longer exists/, err)
    end
  end

  def test_validate_complete_marker_rejects_missing_url_and_non_draft_marker
    with_tmp_dir do |root|
      task = make_task(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      remediated = []

      missing_url = Hive::Markers::State.new(name: :complete, attrs: {}, raw: nil)
      result = Hive::Stages::OpenPr.validate_complete_marker(task, missing_url, worktree, task.slug, cfg)
      assert_equal({ commit: "open_pr_marker_missing_url", status: :error }, result)
      assert_equal "open_pr_marker_missing_url", Hive::Markers.current(task.state_file).attrs.fetch("reason")

      marker = Hive::Markers::State.new(
        name: :complete,
        attrs: { "pr_url" => "https://example.com/pr/1", "is_draft" => "false" },
        raw: nil
      )
      with_replaced_singleton_method(Hive::Stages::OpenPr, :remediate_orphan_pr!, ->(url) { remediated << url }) do
        result = Hive::Stages::OpenPr.validate_complete_marker(task, marker, worktree, task.slug, cfg)
      end

      assert_equal({ commit: "open_pr_not_draft", status: :error }, result)
      assert_equal [ "https://example.com/pr/1" ], remediated
      assert_equal "open_pr_not_draft", Hive::Markers.current(task.state_file).attrs.fetch("reason")
    end
  end

  def test_validate_complete_marker_rejects_real_pr_that_is_not_draft
    with_tmp_dir do |root|
      task = make_task(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      marker = Hive::Markers::State.new(
        name: :complete,
        attrs: { "pr_url" => "https://example.com/pr/2", "is_draft" => "true" },
        raw: nil
      )
      remediated = []

      with_replaced_singleton_method(Hive::Gh, :lookup_existing_pr, lambda { |_worktree, _branch, cfg:|
        { "url" => "https://example.com/pr/2", "isDraft" => false }
      }) do
        with_replaced_singleton_method(Hive::Stages::OpenPr, :remediate_orphan_pr!, ->(url) { remediated << url }) do
          result = Hive::Stages::OpenPr.validate_complete_marker(task, marker, worktree, task.slug, cfg)

          assert_equal({ commit: "open_pr_not_draft", status: :error }, result)
          assert_equal [ "https://example.com/pr/2" ], remediated
          assert_equal "open_pr_not_draft", Hive::Markers.current(task.state_file).attrs.fetch("reason")
        end
      end
    end
  end

  def test_validate_complete_marker_records_lookup_failure
    with_tmp_dir do |root|
      task = make_task(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      marker = Hive::Markers::State.new(
        name: :complete,
        attrs: { "pr_url" => "https://example.com/pr/3", "is_draft" => "true" },
        raw: nil
      )

      result = nil
      with_replaced_singleton_method(Hive::Gh, :lookup_existing_pr, ->(_worktree, _branch, cfg:) { raise Hive::GhError, "api unavailable" }) do
        result = Hive::Stages::OpenPr.validate_complete_marker(task, marker, worktree, task.slug, cfg)
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "open_pr_lookup_failed", status: :error }, result)
      assert_equal "open_pr_lookup_failed", marker.attrs.fetch("reason")
      assert_match(/api unavailable/, marker.attrs.fetch("detail"))
    end
  end

  def test_remediation_helpers_scrub_and_close_prs
    calls = []
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*argv) { calls << argv }) do
      Hive::Stages::OpenPr.remediate_secret_leak!("")
      Hive::Stages::OpenPr.remediate_orphan_pr!("")
      Hive::Stages::OpenPr.remediate_secret_leak!("https://example.com/pr/4")
      Hive::Stages::OpenPr.remediate_orphan_pr!("https://example.com/pr/5")
    end

    assert_equal 4, calls.length
    assert_equal [ "gh", "pr", "edit", "https://example.com/pr/4", "--body", "[redacted: hive detected a credential pattern]" ], calls[0]
    assert_equal [ "gh", "pr", "close", "https://example.com/pr/4" ], calls[1]
    assert_equal [ "gh", "pr", "edit", "https://example.com/pr/5", "--body", "[redacted: hive rejected this PR state]" ], calls[2]
    assert_equal [ "gh", "pr", "close", "https://example.com/pr/5" ], calls[3]
  end

  def test_remediate_secret_leak_warns_when_scrub_fails
    failing_capture = ->(*_argv) { raise Hive::GhError, "network down" }

    with_replaced_singleton_method(Hive::Gh, :capture3, failing_capture) do
      _out, err = capture_io do
        Hive::Stages::OpenPr.remediate_secret_leak!("https://example.com/pr/9")
      end

      assert_includes err, "failed to scrub leaked PR https://example.com/pr/9"
      assert_includes err, "Hive::GhError: network down"
      assert_includes err, "manually edit and close it before resuming"
    end
  end

  def test_remediate_orphan_pr_warns_when_close_fails
    failing_capture = ->(*_argv) { raise Hive::GhError, "network down" }

    with_replaced_singleton_method(Hive::Gh, :capture3, failing_capture) do
      _out, err = capture_io do
        Hive::Stages::OpenPr.remediate_orphan_pr!("https://example.com/pr/10")
      end

      assert_includes err, "failed to close rejected PR https://example.com/pr/10"
      assert_includes err, "Hive::GhError: network down"
      assert_includes err, "manually inspect it before resuming"
    end
  end

  def test_handle_secret_scan_result_records_fetch_failure_and_hits
    with_tmp_dir do |root|
      task = make_task(root)
      fetch_failed = Scan.new(fetch_failed: true, fetch_error: "rate limited", hits: [ { name: :token } ])

      result = Hive::Stages::OpenPr.handle_secret_scan_result(task, "https://example.com/pr/6", fetch_failed, "open_pr")
      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "open_pr_secret_scan_failed", status: :error }, result)
      assert_equal "secret_scan_fetch_failed", marker.attrs.fetch("reason")
      assert_equal "rate limited", marker.attrs.fetch("detail")
      assert_equal "token", marker.attrs.fetch("patterns")

      remediated = []
      hit = Scan.new(fetch_failed: false, fetch_error: nil, hits: [ { name: :api_key } ])
      with_replaced_singleton_method(Hive::Stages::OpenPr, :remediate_secret_leak!, ->(url) { remediated << url }) do
        result = Hive::Stages::OpenPr.handle_secret_scan_result(task, "https://example.com/pr/7", hit, "open_pr")
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "open_pr_secret_blocked", status: :error }, result)
      assert_equal [ "https://example.com/pr/7" ], remediated
      assert_equal "secret_in_pr_body", marker.attrs.fetch("reason")
      assert_equal "api_key", marker.attrs.fetch("patterns")
    end
  end

  def test_write_pr_md_rejects_empty_url
    with_tmp_dir do |root|
      task = make_task(root)

      _out, err, status = with_captured_exit do
        Hive::Stages::OpenPr.write_pr_md(task, { "url" => "", "number" => 9 })
      end

      assert_equal 1, status
      assert_match(/empty url/, err)
      refute File.exist?(task.state_file)
    end
  end
end
