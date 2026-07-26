require "test_helper"
require "hive/stages/open_pr"

class HiveStagesOpenPrTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, :state_file, :project_root, :slug, :depends_on, :id, keyword_init: true)
  Scan = Struct.new(:fetch_failed, :fetch_error, :hits, keyword_init: true)


  def make_task(root, depends_on: nil)
    folder = File.join(root, ".hive-state", "stages", "5-open-pr", "open-pr-task")
    FileUtils.mkdir_p(folder)
    Task.new(
      folder: folder,
      state_file: File.join(folder, "pr.md"),
      project_root: root,
      slug: "open-pr-task",
      depends_on: depends_on,
      id: 2
    )
  end

  def write_pointer(task, worktree_path, branch: task.slug)
    File.write(File.join(task.folder, "worktree.yml"), { "path" => worktree_path, "branch" => branch }.to_yaml)
  end

  def write_dependency_meta(task)
    Hive::TaskMeta.write(task.folder, id: task.id, slug: task.slug, display_name: nil, depends_on: task.depends_on)
  end

  def cfg
    { "budget_usd" => {}, "timeout_sec" => {} }
  end

  def with_basic_open_pr_run_stubs(existing_pr: nil, merged_pr: nil, scan: Scan.new(fetch_failed: false, fetch_error: nil, hits: []), &block)
    # With PR #138 fix #145, run! calls `lookup_prs_for_branch` ONCE and
    # filters in-process. The legacy `existing_pr` / `merged_pr` kwargs
    # are preserved for caller ergonomics: we compose the canonical
    # `gh pr list` array from them.
    prs = []
    prs << existing_pr.merge("state" => existing_pr["state"] || "OPEN") if existing_pr
    prs << merged_pr.merge("state" => merged_pr["state"] || "MERGED") if merged_pr
    with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, ->(_cfg) { }) do
      with_replaced_singleton_method(Hive::Gh, :lookup_prs_for_branch, ->(_worktree_path, _branch, cfg:) { prs }) do
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
      pointer_path = File.join(task.folder, "worktree.yml")
      original_pointer = File.binread(pointer_path)

      with_basic_open_pr_run_stubs do
        with_replaced_singleton_method(
          Hive::Stages::Base,
          :spawn_agent,
          ->(*_args, **_kwargs) { File.write(pointer_path, "path: /tmp/foreign\n") }
        ) do
          # capture_io swallows the expected `local_head_oid` warn —
          # this test uses a plain dir, not a git repo, so the new
          # rev-parse warn fires by design. Keep it out of test output.
          result = nil
          capture_io { result = Hive::Stages::OpenPr.run!(task, cfg) }

          marker = Hive::Markers.current(task.state_file)
          assert_equal({ commit: "open_pr_tampered", status: :error }, result)
          assert_equal :error, marker.name
          assert_equal "open_pr_tampered", marker.attrs.fetch("reason")
          assert_equal "worktree.yml", marker.attrs.fetch("files")
          assert_equal "true", marker.attrs.fetch("restored")
          assert_equal original_pointer, File.binread(pointer_path)
        end
      end
    end
  end

  def test_run_uses_persisted_implementation_provider_profile
    with_tmp_dir do |root|
      task = make_task(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      write_pointer(task, worktree)
      identity = Struct.new(:provider).new("codex")
      looked_up = []

      with_basic_open_pr_run_stubs do
        with_replaced_singleton_method(
          Hive::Stages::Base, :implementation_stage_identity,
          ->(_task, _cfg, _stage) { identity }
        ) do
          with_replaced_singleton_method(
            Hive::AgentProfiles, :lookup,
            ->(provider, cfg:) { looked_up << [ provider, cfg ]; :persisted_profile }
          ) do
            with_replaced_singleton_method(Hive::ProtectedFiles, :snapshot, ->(_folder) { Object.new }) do
              with_replaced_singleton_method(Hive::ProtectedFiles, :diff, ->(_before, _after) { [ "worktree.yml" ] }) do
                with_replaced_singleton_method(Hive::Stages::OpenPr, :spawn_open_pr_agent, ->(*_args, **_kwargs) { }) do
                  capture_io { Hive::Stages::OpenPr.run!(task, cfg) }
                end
              end
            end
          end
        end
      end

      assert_equal [ [ "codex", cfg ] ], looked_up
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
              result = nil
              capture_io { result = Hive::Stages::OpenPr.run!(task, cfg) }

              assert_equal({ commit: nil, status: :review_waiting }, result)
              assert_equal :review_waiting, Hive::Markers.current(task.state_file).name
            end
          end
        end
      end
    end
  end

  def test_run_refuses_merged_pr_recovery_with_empty_url
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        head_oid = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
        write_pointer(task, worktree)
        merged = {
          "url" => "",
          "number" => 134,
          "state" => "MERGED",
          "isDraft" => false,
          "headRefOid" => head_oid
        }

        with_basic_open_pr_run_stubs(merged_pr: merged) do
          _out, err, status = with_captured_exit do
            Hive::Stages::OpenPr.run!(task, cfg)
          end

          assert_equal 1, status
          assert_match(/merged PR with an empty url/, err)
          refute File.exist?(task.state_file)
        end
      end
    end
  end

  def test_run_recovers_when_branch_pr_is_already_merged
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        head_oid = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
        write_pointer(task, worktree)
        merged = {
          "url" => "https://example.com/pr/134",
          "number" => 134,
          "state" => "MERGED",
          "isDraft" => false,
          "headRefOid" => head_oid
        }
        scan = Scan.new(fetch_failed: false, fetch_error: nil, hits: [])
        scanned = []

        with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, ->(_cfg) { }) do
          with_replaced_singleton_method(Hive::Gh, :lookup_prs_for_branch, ->(_worktree_path, _branch, cfg:) { [ merged ] }) do
            with_replaced_singleton_method(Hive::Gh, :push_branch!, ->(_worktree_path, _branch, cfg:) { flunk "merged recovery must not push" }) do
              with_replaced_singleton_method(Hive::Gh, :scan_pr_for_secrets, lambda { |state_file:, pr_url:, cfg:|
                scanned << [ state_file, pr_url ]
                scan
              }) do
                result = Hive::Stages::OpenPr.run!(task, cfg)

                assert_equal({ commit: "open_pr_already_merged", status: :complete }, result)
                assert_equal [ [ task.state_file, "https://example.com/pr/134" ] ], scanned
                marker = Hive::Markers.current(task.state_file)
                assert_equal :complete, marker.name
                assert_equal "https://example.com/pr/134", marker.attrs.fetch("pr_url")
                assert_equal "false", marker.attrs.fetch("is_draft")
                assert_equal "true", marker.attrs.fetch("merged")
                assert_includes File.read(task.state_file), "PR already merged for this task."
                assert_equal head_oid,
                             Hive::Gh.pr_frontmatter(task.state_file).fetch("head_oid")
                assert_includes File.read(File.join(task.folder, "summary.md")), "PR #134 was already merged"

                # Fix #142: merged recovery also lands terminal markers on
                # the downstream stage state files so 6-review and 7-artifacts
                # short-circuit instead of re-running against a merged PR.
                # Look up the file names via Hive::Task::STATE_FILES (the
                # same source production uses) so a future rename in
                # lib/hive/task.rb breaks this assertion instead of letting
                # the test silently pass while production diverges.
                review_file = File.join(task.folder, Hive::Task::STATE_FILES.fetch("review"))
                artifact_file = File.join(task.folder, Hive::Task::STATE_FILES.fetch("artifacts"))
                assert File.exist?(review_file), "review state file must be written"
                assert File.exist?(artifact_file), "artifacts state file must be written"
                review_marker = Hive::Markers.current(review_file)
                assert_equal :review_complete, review_marker.name
                assert_equal "true", review_marker.attrs.fetch("merged")
                artifact_marker = Hive::Markers.current(artifact_file)
                assert_equal :complete, artifact_marker.name
                assert_equal "true", artifact_marker.attrs.fetch("merged")
              end
            end
          end
        end
      end
    end
  end

  def test_run_lands_error_when_merged_pr_recovery_secret_scan_fetch_fails
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        head_oid = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
        write_pointer(task, worktree)
        merged = {
          "url" => "https://example.com/pr/144",
          "number" => 144,
          "state" => "MERGED",
          "isDraft" => false,
          "headRefOid" => head_oid
        }
        fetch_failed = Scan.new(fetch_failed: true, fetch_error: "simulated", hits: [])

        with_basic_open_pr_run_stubs(merged_pr: merged, scan: fetch_failed) do
          result = Hive::Stages::OpenPr.run!(task, cfg)

          assert_equal({ commit: "open_pr_secret_scan_failed", status: :error }, result)
          marker = Hive::Markers.current(task.state_file)
          assert_equal :error, marker.name
          assert_equal "secret_scan_fetch_failed", marker.attrs.fetch("reason")
          assert_equal "simulated", marker.attrs.fetch("detail")
          # Downstream markers must NOT be written when the scan failed;
          # the task should land in :error, not advance through merged
          # recovery's downstream short-circuit.
          refute File.exist?(File.join(task.folder, "task.md")),
                 "task.md must not be written when merged-recovery scan fetch fails"
          refute File.exist?(File.join(task.folder, "artifact.md")),
                 "artifact.md must not be written when merged-recovery scan fetch fails"
        end
      end
    end
  end

  def test_run_lands_error_when_merged_pr_recovery_secret_scan_hits
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        head_oid = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
        write_pointer(task, worktree)
        merged = {
          "url" => "https://example.com/pr/145",
          "number" => 145,
          "state" => "MERGED",
          "isDraft" => false,
          "headRefOid" => head_oid
        }
        hit_scan = Scan.new(fetch_failed: false, fetch_error: nil, hits: [ { name: :aws_key } ])
        remediated = []

        with_basic_open_pr_run_stubs(merged_pr: merged, scan: hit_scan) do
          with_replaced_singleton_method(Hive::Stages::OpenPr, :remediate_secret_leak!, ->(url) { remediated << url }) do
            result = Hive::Stages::OpenPr.run!(task, cfg)

            assert_equal({ commit: "open_pr_secret_blocked", status: :error }, result)
            marker = Hive::Markers.current(task.state_file)
            assert_equal :error, marker.name
            assert_equal "secret_in_pr_body", marker.attrs.fetch("reason")
            assert_equal "aws_key", marker.attrs.fetch("patterns")
            assert_equal [ "https://example.com/pr/145" ], remediated
            refute File.exist?(File.join(task.folder, "task.md"))
            refute File.exist?(File.join(task.folder, "artifact.md"))
          end
        end
      end
    end
  end

  # If a write between the scan success and the COMPLETE marker raises
  # (ENOSPC, EROFS, SIGTERM mid-write), pr.md must NOT be left with a
  # terminal :complete marker — otherwise the open-pr stage looks done
  # on disk while task.md / artifact.md are missing, and the user
  # advancing the folder will cascade exactly the way the merged-recovery
  # path was designed to prevent.
  def test_merged_recovery_leaves_pr_md_non_terminal_when_downstream_markers_fail
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        head_oid = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
        write_pointer(task, worktree)
        merged = {
          "url" => "https://example.com/pr/200",
          "number" => 200,
          "state" => "MERGED",
          "isDraft" => false,
          "headRefOid" => head_oid
        }
        clean_scan = Scan.new(fetch_failed: false, fetch_error: nil, hits: [])

        with_basic_open_pr_run_stubs(merged_pr: merged, scan: clean_scan) do
          with_replaced_singleton_method(Hive::Stages::OpenPr, :write_merged_downstream_markers, ->(_t) { raise Errno::ENOSPC, "simulated disk full" }) do
            assert_raises(Errno::ENOSPC) { Hive::Stages::OpenPr.run!(task, cfg) }

            marker = Hive::Markers.current(task.state_file)
            refute_equal :complete, marker.name,
                         "pr.md must NOT carry a terminal :complete marker after a downstream-markers write fails"
            refute File.exist?(File.join(task.folder, "task.md")),
                   "task.md should not exist when downstream-markers helper raised before writing it"
            refute File.exist?(File.join(task.folder, "artifact.md")),
                   "artifact.md should not exist when downstream-markers helper raised before writing it"
            refute File.exist?(File.join(task.folder, "summary.md")),
                   "summary.md should not exist when downstream-markers helper raised"
            assert_includes File.read(task.state_file), "PR already merged for this task.",
                            "pr.md body should still be written so a re-run finds expected content"
          end
        end
      end
    end
  end

  def test_run_ignores_merged_pr_when_head_oid_does_not_match_local_head
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        write_pointer(task, worktree)
        local_head = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
        # Historical merged PR on the same branch but a different HEAD —
        # must NOT be adopted as recovery. validate_complete_marker re-uses
        # `lookup_existing_pr` (still public) to confirm the freshly-opened
        # PR matches the marker; that helper still pulls from the same
        # `gh pr list` fixture via `lookup_prs_for_branch`.
        old_merged = {
          "url" => "https://github.com/acme/app/pull/133",
          "number" => 133,
          "state" => "MERGED",
          "isDraft" => false,
          "headRefOid" => "0" * 40
        }
        new_pr = {
          "url" => "https://github.com/acme/app/pull/135",
          "number" => 135,
          "state" => "OPEN",
          "isDraft" => true,
          "headRefOid" => local_head
        }
        list_calls = 0
        pushed = false
        scan = Scan.new(fetch_failed: false, fetch_error: nil, hits: [])

        with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, ->(_cfg) { }) do
          with_replaced_singleton_method(Hive::Gh, :lookup_prs_for_branch, lambda { |_worktree_path, _branch, cfg:|
            list_calls += 1
            # First call: only the stale historical merged PR exists.
            # Subsequent call (validate_complete_marker): the new OPEN PR
            # has been published by the simulated agent below.
            list_calls == 1 ? [ old_merged ] : [ new_pr ]
          }) do
            with_replaced_singleton_method(Hive::Gh, :push_branch!, ->(_worktree_path, _branch, cfg:) { pushed = true }) do
              with_replaced_singleton_method(Hive::Gh, :scan_pr_for_secrets, ->(state_file:, pr_url:, cfg:) { scan }) do
                with_replaced_singleton_method(Hive::Stages::Base, :stage_profile, ->(_cfg, _stage) { :profile }) do
                  with_replaced_singleton_method(Hive::Stages::Base, :render, ->(_template, _bindings) { "prompt" }) do
                    with_replaced_singleton_method(Hive::ProtectedFiles, :snapshot, ->(_folder) { Object.new }) do
                      with_replaced_singleton_method(Hive::ProtectedFiles, :diff, ->(_before, _after) { [] }) do
                        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |spawned_task, **_kwargs|
                          Hive::Markers.set(spawned_task.state_file, :complete,
                                            pr_url: new_pr.fetch("url"), is_draft: "true")
                        }) do
                          result = Hive::Stages::OpenPr.run!(task, cfg)

                          assert_equal({ commit: "pr_opened_draft", status: :complete }, result)
                          assert pushed, "mismatched historical merged PR must not skip the normal push/create path"
                          refute File.exist?(File.join(task.folder, "summary.md"))
                          marker = Hive::Markers.current(task.state_file)
                          assert_equal "https://github.com/acme/app/pull/135",
                                       marker.attrs.fetch("pr_url")
                          frontmatter = Hive::Gh.pr_frontmatter(task.state_file)
                          assert_equal local_head, frontmatter.fetch("head_oid")
                          assert_equal 135, frontmatter.fetch("pr_number")
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def test_run_ignores_open_pr_when_head_oid_does_not_match_local_head
    # Symmetric coverage to test_run_ignores_merged_pr_when_head_oid_does_not_match_local_head.
    # If a future cleanup pass drops the OPEN-arm headRefOid filter (assuming
    # `gh pr list --head <branch>` is "good enough" on its own), a stale OPEN
    # PR on a re-pushed branch could silently be adopted — this test catches
    # that regression.
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        write_pointer(task, worktree)
        local_head = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
        # Stale OPEN PR on the same branch but a different HEAD — must NOT
        # short-circuit into `open_pr_already_open`.
        stale_open = {
          "url" => "https://github.com/acme/app/pull/200",
          "number" => 200,
          "state" => "OPEN",
          "isDraft" => true,
          "headRefOid" => "0" * 40
        }
        new_pr = {
          "url" => "https://github.com/acme/app/pull/201",
          "number" => 201,
          "state" => "OPEN",
          "isDraft" => true,
          "headRefOid" => local_head
        }
        list_calls = 0
        pushed = false
        scan = Scan.new(fetch_failed: false, fetch_error: nil, hits: [])

        with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, ->(_cfg) { }) do
          with_replaced_singleton_method(Hive::Gh, :lookup_prs_for_branch, lambda { |_worktree_path, _branch, cfg:|
            list_calls += 1
            list_calls == 1 ? [ stale_open ] : [ new_pr ]
          }) do
            with_replaced_singleton_method(Hive::Gh, :push_branch!, ->(_worktree_path, _branch, cfg:) { pushed = true }) do
              with_replaced_singleton_method(Hive::Gh, :scan_pr_for_secrets, ->(state_file:, pr_url:, cfg:) { scan }) do
                with_replaced_singleton_method(Hive::Stages::Base, :stage_profile, ->(_cfg, _stage) { :profile }) do
                  with_replaced_singleton_method(Hive::Stages::Base, :render, ->(_template, _bindings) { "prompt" }) do
                    with_replaced_singleton_method(Hive::ProtectedFiles, :snapshot, ->(_folder) { Object.new }) do
                      with_replaced_singleton_method(Hive::ProtectedFiles, :diff, ->(_before, _after) { [] }) do
                        with_replaced_singleton_method(Hive::Gh, :lookup_existing_pr, lambda { |_worktree, _branch, cfg:| new_pr }) do
                          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |spawned_task, **_kwargs|
                            Hive::Markers.set(spawned_task.state_file, :complete,
                                              pr_url: new_pr.fetch("url"), is_draft: "true")
                          }) do
                            result = Hive::Stages::OpenPr.run!(task, cfg)

                            assert_equal({ commit: "pr_opened_draft", status: :complete }, result)
                            assert pushed, "stale OPEN PR with mismatched headRefOid must not skip the normal push/create path"
                            marker = Hive::Markers.current(task.state_file)
                            assert_equal :complete, marker.name
                            assert_equal "https://github.com/acme/app/pull/201",
                                         marker.attrs.fetch("pr_url"),
                                         "the freshly-opened PR's url must land on the marker, not the stale OPEN PR's"
                            assert_equal local_head,
                                         Hive::Gh.pr_frontmatter(task.state_file).fetch("head_oid")
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def test_render_prompt_includes_base_branch_when_supplied
    with_tmp_dir do |root|
      task = make_task(root)

      prompt = Hive::Stages::OpenPr.render_prompt(task, "/tmp/worktree", task.slug, base_branch: "base-task")

      assert_includes prompt, "gh pr create --draft"
      assert_includes prompt, "--head open-pr-task --base base-task"
      assert_includes prompt, "head_oid: <full git rev-parse HEAD>"
    end
  end

  def test_render_prompt_omits_base_branch_when_absent
    with_tmp_dir do |root|
      task = make_task(root)

      prompt = Hive::Stages::OpenPr.render_prompt(task, "/tmp/worktree", task.slug)

      assert_includes prompt, "--head open-pr-task"
      refute_includes prompt, "--base"
    end
  end

  def test_dependency_pr_base_branch_returns_dependency_when_origin_branch_exists
    with_tmp_dir do |root|
      task = make_task(root, depends_on: "base-task")
      write_dependency_meta(task)
      base_folder = File.join(root, ".hive-state", "stages", "8-finalize", "base-task")
      FileUtils.mkdir_p(base_folder)
      Hive::TaskMeta.write(base_folder, id: 1, slug: "base-task", display_name: nil)

      with_replaced_singleton_method(Hive::Worktree, :origin_branch_exists?, ->(_project_root, branch) { branch == "base-task" }) do
        assert_equal "base-task",
                     Hive::Stages::OpenPr.dependency_pr_base_branch(task, { "default_branch" => "master" })
      end
    end
  end

  def test_dependency_pr_base_branch_returns_nil_when_dependency_branch_missing
    with_tmp_dir do |root|
      task = make_task(root, depends_on: "base-task")
      write_dependency_meta(task)
      base_folder = File.join(root, ".hive-state", "stages", "8-finalize", "base-task")
      FileUtils.mkdir_p(base_folder)
      Hive::TaskMeta.write(base_folder, id: 1, slug: "base-task", display_name: nil)

      with_replaced_singleton_method(Hive::Worktree, :origin_branch_exists?, ->(_project_root, _branch) { false }) do
        assert_nil Hive::Stages::OpenPr.dependency_pr_base_branch(task, { "default_branch" => "master" })
      end
    end
  end

  def test_dependency_pr_base_branch_returns_nil_for_self_reference
    with_tmp_dir do |root|
      # A task whose depends_on points at its own slug resolves to no
      # stacked base (same_task? guard) and must fall back to the default —
      # never attempt to stack a PR onto its own branch.
      task = make_task(root, depends_on: "open-pr-task")
      write_dependency_meta(task)

      _out, err = capture_io do
        assert_nil Hive::Stages::OpenPr.dependency_pr_base_branch(task, { "default_branch" => "master" })
      end
      assert_match(/did not resolve to a stacked base/, err)
    end
  end

  def test_run_lands_error_when_open_pr_recovery_secret_scan_fetch_fails
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        head_oid = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
        write_pointer(task, worktree)
        existing = {
          "url" => "https://example.com/pr/300",
          "number" => 300,
          "state" => "OPEN",
          "isDraft" => true,
          "headRefOid" => head_oid
        }
        fetch_failed = Scan.new(fetch_failed: true, fetch_error: "simulated", hits: [])

        with_basic_open_pr_run_stubs(existing_pr: existing, scan: fetch_failed) do
          result = Hive::Stages::OpenPr.run!(task, cfg)

          assert_equal({ commit: "open_pr_secret_scan_failed", status: :error }, result)
          marker = Hive::Markers.current(task.state_file)
          assert_equal :error, marker.name
          assert_equal "secret_scan_fetch_failed", marker.attrs.fetch("reason")
          assert_equal "simulated", marker.attrs.fetch("detail")
        end
      end
    end
  end

  def test_run_lands_error_when_open_pr_recovery_secret_scan_hits
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        head_oid = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
        write_pointer(task, worktree)
        existing = {
          "url" => "https://example.com/pr/301",
          "number" => 301,
          "state" => "OPEN",
          "isDraft" => true,
          "headRefOid" => head_oid
        }
        hit_scan = Scan.new(fetch_failed: false, fetch_error: nil, hits: [ { name: :aws_key } ])
        remediated = []

        with_basic_open_pr_run_stubs(existing_pr: existing, scan: hit_scan) do
          with_replaced_singleton_method(Hive::Stages::OpenPr, :remediate_secret_leak!, ->(url) { remediated << url }) do
            result = Hive::Stages::OpenPr.run!(task, cfg)

            assert_equal({ commit: "open_pr_secret_blocked", status: :error }, result)
            marker = Hive::Markers.current(task.state_file)
            assert_equal :error, marker.name
            assert_equal "secret_in_pr_body", marker.attrs.fetch("reason")
            assert_equal "aws_key", marker.attrs.fetch("patterns")
            assert_equal [ "https://example.com/pr/301" ], remediated
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
        Hive::Stages::Base.worktree_pointer_or_exit(task)
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

  def test_validate_complete_marker_rejects_remote_head_that_is_not_local_head
    with_tmp_dir do |root|
      task = make_task(root)
      with_tmp_git_repo do |worktree|
        marker = Hive::Markers::State.new(
          name: :complete,
          attrs: { "pr_url" => "https://example.com/pr/4", "is_draft" => "true" },
          raw: nil
        )
        real = {
          "url" => "https://example.com/pr/4",
          "number" => 4,
          "isDraft" => true,
          "headRefOid" => "f" * 40
        }
        remediated = []

        with_replaced_singleton_method(
          Hive::Gh, :lookup_existing_pr,
          ->(_worktree, _branch, cfg:) { real }
        ) do
          with_replaced_singleton_method(
            Hive::Stages::OpenPr, :remediate_orphan_pr!,
            ->(url) { remediated << url }
          ) do
            result = Hive::Stages::OpenPr.validate_complete_marker(
              task, marker, worktree, task.slug, cfg
            )

            assert_equal({ commit: "open_pr_head_mismatch", status: :error }, result)
            assert_equal [ "https://example.com/pr/4" ], remediated
            error = Hive::Markers.current(task.state_file)
            assert_equal "open_pr_head_mismatch", error.attrs.fetch("reason")
          end
        end
      end
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
