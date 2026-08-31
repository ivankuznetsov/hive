require "test_helper"
require "base64"
require "digest"
require "json"
require "hive/commands/worktree"

class HiveCommandsWorktreeTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(
    :slug, :stage_index, :stage_name, :folder, :state_file, :project_root, :project_name,
    keyword_init: true
  )

  def setup
    @root = Dir.mktmpdir("hive-worktree-command")
    @worktree = File.join(@root, "worktree")
    FileUtils.mkdir_p(@worktree)
    run!("git", "-C", @worktree, "init", "-b", "main", "--quiet")
    run!("git", "-C", @worktree, "config", "user.email", "t@example.com")
    run!("git", "-C", @worktree, "config", "user.name", "T")
    run!("git", "-C", @worktree, "config", "commit.gpgsign", "false")
    File.write(File.join(@worktree, "seed.txt"), "seed\n")
    run!("git", "-C", @worktree, "add", ".")
    run!("git", "-C", @worktree, "commit", "-m", "seed", "--quiet")

    folder = File.join(@root, ".hive-state", "stages", "6-review", "demo-260813-abcd")
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: 42, slug: "demo-260813-abcd", display_name: nil)
    prepare_test_task_lease_repository(folder)
    @task = FakeTask.new(
      slug: "demo-260813-abcd", stage_index: 6, stage_name: "review",
      folder: folder, state_file: File.join(folder, "task.md"),
      project_root: @root, project_name: "demo"
    )
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed", residue_paths: "wiki/residue.md"
    )
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_status_emits_exact_machine_readable_residue
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")

    payload = run_command("status")

    assert_equal "hive-worktree", payload.fetch("schema")
    assert_equal "status", payload.fetch("action")
    assert_equal [ "wiki/residue.md" ], payload.fetch("residue_paths")
    assert_equal 1, payload.fetch("untracked_count")
    assert_equal "hive status --operational --json", payload.dig("next_action", "command")
  end

  def test_status_renders_human_readable_recovery_details
    out, = capture_io do
      with_resolved_task do
        Hive::Commands::Worktree.new(
          "status", @task.slug,
          pointer_resolver: ->(_task, _cfg) { @worktree }
        ).call
      end
    end

    assert_includes out, "demo-260813-abcd: status"
    assert_includes out, "worktree: #{@worktree}"
    assert_includes out, "branch: main"
    assert_match(/head: [0-9a-f]+/, out)
    assert_includes out, "residue: (clean)"
    assert_includes out, "next: hive status --operational --json"
  end

  def test_status_resolves_the_strict_owned_pointer_by_default
    canonical_input = nil
    canonical_config = nil
    pointer_args = nil
    worktree = @worktree
    canonical_root = "/canonical/worktrees"

    with_replaced_singleton_method(Hive::Worktree, :canonical_root, lambda { |path, config:|
      canonical_input = path
      canonical_config = config
      canonical_root
    }) do
      with_replaced_singleton_method(Hive::Worktree, :read_owned_pointer, lambda { |folder, **kwargs|
        pointer_args = [ folder, kwargs ]
        { "path" => worktree }
      }) do
        out, = capture_io do
          with_resolved_task do
            Hive::Commands::Worktree.new("status", @task.slug, json: true).call
          end
        end

        assert_equal @worktree, JSON.parse(out).fetch("worktree_path")
      end
    end

    assert_equal @task.project_root, canonical_input
    assert_same Hive::Config::DEFAULTS, canonical_config
    assert_equal(
      [
        @task.folder,
        {
          project_root: @task.project_root, slug: @task.slug,
          expected_root: canonical_root
        }
      ],
      pointer_args
    )
  end

  def test_status_honors_configured_root_with_real_resolver_and_owned_pointer
    project_root = File.join(@root, "configured-project")
    hive_home = File.join(@root, "hive-home")
    configured_root = File.join(@root, "custom-worktrees")
    slug = "configured-root-260824-abcd"
    task_folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
    worktree_path = File.join(configured_root, slug)
    FileUtils.mkdir_p(task_folder)

    run!("git", "-C", project_root, "init", "-b", "main", "--quiet")
    run!("git", "-C", project_root, "config", "user.email", "t@example.com")
    run!("git", "-C", project_root, "config", "user.name", "T")
    File.write(File.join(project_root, "seed.txt"), "seed\n")
    run!("git", "-C", project_root, "add", ".")
    run!("git", "-C", project_root, "commit", "-m", "seed", "--quiet")
    File.write(
      File.join(project_root, ".hive-state", "config.yml"),
      { "worktree_root" => configured_root }.to_yaml
    )
    run!("git", "-C", project_root, "worktree", "add", "-b", slug, worktree_path, "main")
    Hive::Worktree.new(project_root, slug, worktree_root: configured_root)
                  .write_pointer!(task_folder, slug)
    Hive::Markers.set(File.join(task_folder, "task.md"), :review_error, reason: "probe")

    with_env("HIVE_HOME" => hive_home) do
      Hive::Config.register_project(
        name: File.basename(project_root), path: project_root, repository_identity: nil
      )

      out, = capture_io do
        Hive::Commands::Worktree.new(
          "status", slug, project: File.basename(project_root), json: true
        ).call
      end
      payload = JSON.parse(out)

      assert_equal worktree_path, payload.fetch("worktree_path")
      refute_includes payload.fetch("worktree_path"), ".worktrees.worktrees"
    end
  end

  def test_error_envelope_kinds_preserve_resolution_and_lock_failures
    errors = {
      Hive::AmbiguousSlug.new("ambiguous", slug: @task.slug, candidates: []) => "ambiguous_slug",
      Hive::InvalidTaskPath.new("invalid") => "invalid_task_path",
      Hive::ConcurrentRunError.new("locked") => "task_locked",
      StandardError.new("unexpected") => "error"
    }

    errors.each do |error, expected|
      assert_equal expected, command("status").envelope_error_kind(error), error.class.name
    end
  end

  def test_commit_residue_uses_clean_exit_guards_and_keeps_marker_for_coordinator
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")

    payload = run_command("commit-residue")

    assert_equal "commit-residue", payload.fetch("action")
    assert_equal [ "wiki/residue.md" ], payload.fetch("committed_paths")
    assert payload.fetch("clean")
    assert_equal "ensure_clean_on_exit_failed",
                 Hive::Markers.current(@task.state_file).attrs.fetch("reason")
    assert_equal "chore(6-review): commit residual worktree changes",
                 `git -C #{@worktree} log -1 --pretty=%s`.strip
  end

  def test_commit_residue_accepts_error_dirty_worktree_from_execute
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "dirty_worktree", marker_id: "execute-dirty-1", attempt_id: "attempt-1"
    )
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")

    payload = run_command("commit-residue")

    assert_equal "commit-residue", payload.fetch("action")
    assert_equal [ "wiki/residue.md" ], payload.fetch("committed_paths")
    assert payload.fetch("clean")
    marker = Hive::Markers.current(@task.state_file)
    assert_equal :error, marker.name
    assert_equal "dirty_worktree", marker.attrs.fetch("reason")
    assert_equal "execute-dirty-1", marker.attrs.fetch("marker_id")
  end

  def test_commit_residue_can_complete_validated_execute_recovery
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "dirty_worktree", marker_id: "execute-dirty-2", attempt_id: "attempt-2"
    )
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")
    recovered = nil
    recovery = lambda do |task, cfg, worktree_path|
      recovered = [ task, cfg, worktree_path ]
      Hive::Markers.set(task.state_file, :execute_complete)
      { commit: "execute_complete", status: :execute_complete }
    end

    payload = with_replaced_singleton_method(
      Hive::Stages::Execute, :recover_committed_residue!, recovery
    ) do
      run_command("commit-residue", complete_execute: true)
    end

    assert_equal [ @task, Hive::Config::DEFAULTS, @worktree ], recovered
    assert payload.fetch("execute_completed")
    assert payload.fetch("clean")
    assert_equal :execute_complete, Hive::Markers.current(@task.state_file).name
  end

  def test_complete_execute_requires_the_dirty_worktree_error_marker
    @task.stage_index = 4
    @task.stage_name = "execute"
    Hive::Markers.set(@task.state_file, :error, reason: "ensure_clean_on_exit_failed")
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")

    out, error = run_command_error("commit-residue", complete_execute: true)

    payload = JSON.parse(out)
    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", payload.fetch("error_kind")
    assert_match(/requires ERROR reason=dirty_worktree/, payload.fetch("message"))
  end

  def test_complete_execute_recovery_preserves_out_of_scope_implementation_paths
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "dirty_worktree", marker_id: "execute-dirty-scope", attempt_id: "attempt-scope"
    )
    FileUtils.mkdir_p(File.join(@worktree, "web", "config"))
    File.write(File.join(@worktree, "web", "config", "routes.rb"), "# planned route\n")
    recovery = lambda do |task, _cfg, _worktree_path|
      Hive::Markers.set(task.state_file, :execute_complete)
    end

    payload = with_replaced_singleton_method(
      Hive::Stages::Execute, :recover_committed_residue!, recovery
    ) do
      run_command("commit-residue", complete_execute: true)
    end

    assert_equal [ "web/config/routes.rb" ], payload.fetch("committed_paths")
    assert payload.fetch("execute_completed")
    body = `git -C #{@worktree} log -1 --pretty=%B`
    assert_includes body, "Hive-Auto-Commit-Reason: execute_residue_recovery"
  end

  def test_complete_execute_recovery_keeps_secret_content_gate
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "dirty_worktree", marker_id: "execute-dirty-secret", attempt_id: "attempt-secret"
    )
    FileUtils.mkdir_p(File.join(@worktree, "web", "config"))
    secret = "AKIAABCDEFGHIJKLMNOP"
    File.write(File.join(@worktree, "web", "config", "routes.rb"), "#{secret}\n")
    recovered = false
    recovery = ->(*) { recovered = true }

    out, error = with_replaced_singleton_method(
      Hive::Stages::Execute, :recover_committed_residue!, recovery
    ) do
      run_command_error("commit-residue", complete_execute: true)
    end

    payload = JSON.parse(out)
    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", payload.fetch("error_kind")
    refute_includes payload.fetch("message"), secret
    refute recovered
    assert_equal "seed", `git -C #{@worktree} log -1 --pretty=%s`.strip
  end

  def test_commit_residue_rejects_secret_content_without_committing_or_leaking_it
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    secret = "AKIAABCDEFGHIJKLMNOP"
    File.write(File.join(@worktree, "wiki", "residue.md"), "#{secret}\n")

    out, error = run_command_error("commit-residue")
    payload = JSON.parse(out)

    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", payload.fetch("error_kind")
    refute_includes payload.fetch("message"), secret
    assert_equal "seed", `git -C #{@worktree} log -1 --pretty=%s`.strip
    assert File.exist?(File.join(@worktree, "wiki", "residue.md"))
  end

  def test_existing_secret_shaped_filename_is_redacted_from_status_and_commit_output
    secret = "AKIAABCDEFGHIJKLMNOP"
    path = "wiki/#{secret}.md"
    FileUtils.mkdir_p(File.dirname(File.join(@worktree, path)))
    File.write(File.join(@worktree, path), "baseline\n")
    run!("git", "-C", @worktree, "add", "--", path)
    run!("git", "-C", @worktree, "commit", "-m", "add legacy fixture", "--quiet")
    File.write(File.join(@worktree, path), "changed\n")

    status_payload = run_command("status")
    status_json = JSON.generate(status_payload)
    refute_includes status_json, secret
    assert_equal [ "wiki/[REDACTED:aws_access_key].md" ], status_payload.fetch("residue_paths")
    assert_equal "wiki/[REDACTED:aws_access_key].md",
                 status_payload.fetch("porcelain").fetch(0).fetch("path")

    commit_payload = run_command("commit-residue")
    commit_json = JSON.generate(commit_payload)
    refute_includes commit_json, secret
    assert_equal [ "wiki/[REDACTED:aws_access_key].md" ], commit_payload.fetch("committed_paths")
  end

  def test_discard_residue_removes_only_marker_recorded_paths
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    FileUtils.mkdir_p(File.join(@worktree, "lib"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "discard\n")
    File.write(File.join(@worktree, "lib", "keep.rb"), "keep\n")

    payload = run_command("discard-residue")

    assert_equal [ "wiki/residue.md" ], payload.fetch("discarded_paths")
    refute File.exist?(File.join(@worktree, "wiki", "residue.md"))
    assert File.exist?(File.join(@worktree, "lib", "keep.rb"))
    assert_equal [ "lib/keep.rb" ], payload.fetch("residue_paths")
  end

  def test_discard_residue_treats_pathspec_magic_as_a_literal_filename
    File.write(File.join(@worktree, "*"), "discard\n")
    File.write(File.join(@worktree, "operator-note"), "keep\n")
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed", residue_paths: "*"
    )

    payload = run_command("discard-residue")

    assert_equal [ "*" ], payload.fetch("discarded_paths")
    refute File.exist?(File.join(@worktree, "*"))
    assert File.exist?(File.join(@worktree, "operator-note"))
  end

  def test_discard_residue_preserves_comma_in_explicit_path
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "a,b.md"), "discard\n")

    payload = run_command("discard-residue", paths: [ "wiki/a,b.md" ])

    assert_equal [ "wiki/a,b.md" ], payload.fetch("discarded_paths")
    refute File.exist?(File.join(@worktree, "wiki", "a,b.md"))
  end

  def test_discard_residue_reads_large_lossless_marker_sidecar
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    paths = [ "wiki/a,b.md" ] + 24.times.map do |index|
      "wiki/#{format('%02d', index)}-#{'generated-baseline-' * 9}.md"
    end
    paths.each { |path| File.write(File.join(@worktree, path), "discard\n") }
    attrs = Hive::Stages::CleanExit.failure_marker_attrs(
      { status: :safety_violation, paths: paths, message: "generated baselines" },
      task_folder: @task.folder
    )
    Hive::Markers.set(
      @task.state_file, :error,
      **attrs
    )
    marker = Hive::Markers.current(@task.state_file)
    assert_equal Hive::Stages::CleanExit::RESIDUE_PATHS_FILE,
                 marker.attrs.fetch("residue_paths_file")
    refute marker.attrs.key?("residue_paths_b64")

    run_command("discard-residue")

    paths.each { |path| refute File.exist?(File.join(@worktree, path)), path }
  end

  def test_discard_residue_decodes_legacy_base64_marker_paths
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "a,b.md"), "discard\n")
    encoded = Base64.strict_encode64(JSON.generate([ "wiki/a,b.md" ]))
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed", residue_paths: "wiki/a,b.md",
      residue_paths_b64: encoded
    )

    payload = run_command("discard-residue")

    assert_equal [ "wiki/a,b.md" ], payload.fetch("discarded_paths")
    refute File.exist?(File.join(@worktree, "wiki", "a,b.md"))
  end

  def test_discard_residue_reads_canonical_inline_marker_paths
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    paths = [ "wiki/a,b.md", "wiki/small.md" ]
    paths.each { |path| File.write(File.join(@worktree, path), "discard\n") }
    attrs = Hive::Stages::CleanExit.failure_marker_attrs(
      { status: :safety_violation, paths: paths, message: "generated baselines" },
      task_folder: @task.folder
    )
    assert attrs.key?(:residue_paths_b64)
    assert_equal paths.length, attrs.fetch(:residue_paths_count)
    assert_match(/\A[0-9a-f]{64}\z/, attrs.fetch(:residue_paths_sha256))
    Hive::Markers.set(@task.state_file, :error, **attrs)

    run_command("discard-residue")

    paths.each { |path| refute File.exist?(File.join(@worktree, path)), path }
  end

  def test_discard_residue_recovers_large_list_from_matching_current_identity
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    paths = 25.times.map do |index|
      "wiki/#{format('%02d', index)}-#{'generated-baseline-' * 9}.md"
    end
    paths.each { |path| File.write(File.join(@worktree, path), "discard\n") }
    attrs = Hive::Stages::CleanExit.failure_marker_attrs(
      { status: :safety_violation, paths: paths, message: "generated baselines" }
    )
    refute attrs.key?(:residue_paths_b64)
    refute attrs.key?(:residue_paths_file)
    Hive::Markers.set(@task.state_file, :error, **attrs)

    run_command("discard-residue")

    paths.each { |path| refute File.exist?(File.join(@worktree, path)), path }
  end

  def test_discard_residue_falls_back_when_sidecar_identity_is_corrupt
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    paths = 25.times.map do |index|
      "wiki/#{format('%02d', index)}-#{'generated-baseline-' * 9}.md"
    end
    paths.each { |path| File.write(File.join(@worktree, path), "discard\n") }
    attrs = Hive::Stages::CleanExit.failure_marker_attrs(
      { status: :safety_violation, paths: paths, message: "generated baselines" },
      task_folder: @task.folder
    )
    File.write(
      File.join(@task.folder, Hive::Stages::CleanExit::RESIDUE_PATHS_FILE),
      JSON.generate([ "wiki/different.md" ])
    )
    Hive::Markers.set(@task.state_file, :error, **attrs)

    run_command("discard-residue")

    paths.each { |path| refute File.exist?(File.join(@worktree, path)), path }
  end

  def test_discard_residue_rejects_changed_current_identity_without_exact_payload
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "actual.md"), "keep\n")
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed",
      residue_paths_count: 1,
      residue_paths_sha256: Digest::SHA256.hexdigest(JSON.generate([ "wiki/other.md" ]))
    )

    out, error = run_command_error("discard-residue")

    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", JSON.parse(out).fetch("error_kind")
    assert_match(/identity does not match current residue/, error.message)
    assert File.exist?(File.join(@worktree, "wiki", "actual.md"))
  end

  def test_discard_residue_rejects_untrusted_sidecar_reference
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "actual.md"), "keep\n")
    paths = [ "wiki/actual.md" ]
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed",
      residue_paths_file: "../outside.json",
      residue_paths_count: paths.length,
      residue_paths_sha256: Digest::SHA256.hexdigest(JSON.generate(paths))
    )

    out, error = run_command_error("discard-residue")

    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", JSON.parse(out).fetch("error_kind")
    assert_match(/invalid path reference/, error.message)
    assert File.exist?(File.join(@worktree, "wiki", "actual.md"))
  end

  def test_discard_residue_round_trips_clean_exit_sign_policy_failure
    File.write(File.join(@worktree, "seed.txt"), "changed\n")
    run!("git", "-C", @worktree, "config", "commit.gpgsign", "true")
    cfg = JSON.parse(JSON.generate(Hive::Config::DEFAULTS))
    cfg["review"]["fix"]["auto_commit"]["sign_policy"] = "fail"
    result = Hive::Stages::CleanExit.run!(
      worktree_path: @worktree, stage: "6-review", task: @task, cfg: cfg,
      reason: :pre_fix_dirty_worktree
    )
    assert_equal :git_failed, result.fetch(:status)
    assert_equal [ "seed.txt" ], result.fetch(:recovery_paths)
    attrs = Hive::Stages::CleanExit.failure_marker_attrs(
      result, origin: :review_pre_fix, task_folder: @task.folder
    )
    Hive::Markers.set(@task.state_file, :error, **attrs)

    run_command("discard-residue")

    assert_equal "seed\n", File.read(File.join(@worktree, "seed.txt"))
  end

  def test_pre_safety_failure_redacts_full_path_before_bounding_diagnostic
    prefix = "p" * 105
    secret_name = "aws_secret_access_key=#{'A' * 40}.dat"
    FileUtils.mkdir_p(File.join(@worktree, prefix))
    path = File.join(prefix, secret_name)
    File.write(File.join(@worktree, path), "discard\n")
    run!("git", "-C", @worktree, "config", "commit.gpgsign", "true")
    cfg = JSON.parse(JSON.generate(Hive::Config::DEFAULTS))
    cfg["review"]["fix"]["auto_commit"]["sign_policy"] = "fail"
    result = Hive::Stages::CleanExit.run!(
      worktree_path: @worktree, stage: "6-review", task: @task, cfg: cfg,
      reason: :pre_fix_dirty_worktree
    )
    attrs = Hive::Stages::CleanExit.failure_marker_attrs(
      result, origin: :review_pre_fix, task_folder: @task.folder
    )
    assert_includes attrs.fetch(:residue_paths), "[REDACTED:"
    refute_includes attrs.fetch(:residue_paths), "aws_secret_access_key=#{'A' * 38}"
    refute attrs.key?(:residue_paths_b64)
    Hive::Markers.set(@task.state_file, :error, **attrs)

    run_command("discard-residue")

    refute File.exist?(File.join(@worktree, path))
  end

  def test_discard_residue_uses_private_exact_identity_for_redacted_filename
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    FileUtils.mkdir_p(File.join(@worktree, "lib"))
    secret_path = "wiki/AKIAABCDEFGHIJKLMNOP.md"
    meaningful_path = "lib/repair.rb"
    File.write(File.join(@worktree, secret_path), "generated baseline\n")
    File.write(File.join(@worktree, meaningful_path), "meaningful change\n")
    result = Hive::Stages::CleanExit.run!(
      worktree_path: @worktree, stage: "6-review", task: @task,
      cfg: Hive::Config::DEFAULTS, reason: :pre_fix_dirty_worktree
    )
    assert_equal :safety_violation, result.fetch(:status)
    assert_equal [ secret_path ], result.fetch(:recovery_paths)
    refute_includes result.fetch(:paths).join(","), "AKIAABCDEFGHIJKLMNOP"
    attrs = Hive::Stages::CleanExit.failure_marker_attrs(
      result, origin: :review_pre_fix, task_folder: @task.folder
    )
    refute attrs.key?(:residue_paths_b64)
    refute_includes attrs.fetch(:residue_paths), "AKIAABCDEFGHIJKLMNOP"
    assert_equal Hive::Stages::CleanExit::RESIDUE_PATHS_FILE,
                 attrs.fetch(:residue_paths_file)
    Hive::Markers.set(@task.state_file, :error, **attrs)

    run_command("discard-residue")

    refute File.exist?(File.join(@worktree, secret_path))
    assert File.exist?(File.join(@worktree, meaningful_path))
  end

  def test_discard_residue_round_trips_literal_backslash_path_on_posix
    skip "backslash is a path separator on this platform" if File::ALT_SEPARATOR

    path = "odd\\name.dat"
    File.write(File.join(@worktree, path), "discard\n")
    result = Hive::Stages::CleanExit.run!(
      worktree_path: @worktree, stage: "6-review", task: @task,
      cfg: Hive::Config::DEFAULTS
    )
    assert_equal :scope_violation, result.fetch(:status)
    assert_equal [ path ], result.fetch(:recovery_paths)
    attrs = Hive::Stages::CleanExit.failure_marker_attrs(
      result, task_folder: @task.folder
    )
    Hive::Markers.set(@task.state_file, :error, **attrs)

    run_command("discard-residue")

    refute File.exist?(File.join(@worktree, path))
  end

  def test_discard_residue_round_trips_whitespace_filename_bytes
    paths = [ "odd\nname.dat", "odd\tname.dat", " leading.dat", "trailing.dat " ]
    paths.each { |path| File.write(File.join(@worktree, path), "discard\n") }
    result = Hive::Stages::CleanExit.run!(
      worktree_path: @worktree, stage: "6-review", task: @task,
      cfg: Hive::Config::DEFAULTS
    )
    assert_equal :scope_violation, result.fetch(:status)
    assert_equal paths.sort, result.fetch(:recovery_paths).sort
    attrs = Hive::Stages::CleanExit.failure_marker_attrs(
      result, task_folder: @task.folder
    )
    Hive::Markers.set(@task.state_file, :error, **attrs)

    run_command("discard-residue")

    paths.each { |path| refute File.exist?(File.join(@worktree, path)), path.inspect }
  end

  def test_discard_residue_restores_a_tracked_path_from_head
    File.write(File.join(@worktree, "seed.txt"), "changed\n")

    payload = run_command("discard-residue", paths: [ "seed.txt" ])

    assert_equal [ "seed.txt" ], payload.fetch("discarded_paths")
    assert_equal "seed\n", File.read(File.join(@worktree, "seed.txt"))
    assert payload.fetch("clean")
  end

  def test_discard_residue_rejects_paths_that_are_not_currently_dirty
    out, error = run_command_error("discard-residue", paths: [ "not-dirty.txt" ])

    assert_instance_of Hive::UsageError, error
    assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
    assert_match(/not currently reported as residue/, error.message)
  end

  def test_discard_residue_rejects_non_normalized_paths
    out, error = run_command_error("discard-residue", paths: [ "../outside" ])

    assert_instance_of Hive::UsageError, error
    assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
    assert_match(/normalized repository-relative paths/, error.message)
  end

  def test_discard_residue_rejects_invalid_encoded_marker_paths
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed",
      residue_paths_b64: "not-base64"
    )

    out, error = run_command_error("discard-residue")

    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", JSON.parse(out).fetch("error_kind")
    assert_match(/invalid encoded paths/, error.message)
  end

  def test_discard_residue_rejects_legacy_base64_scalar
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed",
      residue_paths_b64: Base64.strict_encode64(JSON.generate("wiki/residue.md"))
    )

    out, error = run_command_error("discard-residue")

    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", JSON.parse(out).fetch("error_kind")
    assert_match(/invalid encoded paths/, error.message)
  end

  def test_mutation_requires_durable_residue_marker
    Hive::Markers.set(@task.state_file, :review_complete)
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")

    out, error = run_command_error("commit-residue")

    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", JSON.parse(out).fetch("error_kind")
    assert_equal "seed", `git -C #{@worktree} log -1 --pretty=%s`.strip
  end

  def test_repair_requires_an_explicit_strategy
    out, error = run_command_error("repair")

    assert_instance_of Hive::UsageError, error
    assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
  end

  def test_argument_validation_rejects_cross_action_options
    cases = [
      [ "future", {}, /unknown worktree subcommand/ ],
      [ "status", { paths: [ "wiki/a.md" ] }, /status does not accept/ ],
      [ "commit-residue", { strategy: "commit" }, /strategy applies only/ ],
      [ "commit-residue", { paths: [ "wiki/a.md" ] }, /paths applies only/ ],
      [ "discard-residue", { complete_execute: true }, /complete-execute applies only/ ],
      [ "discard-residue", { message: "commit this" }, /message applies only/ ]
    ]

    cases.each do |subcommand, options, expected_message|
      out, error = run_command_error(subcommand, **options)

      assert_instance_of Hive::UsageError, error
      assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
      assert_match expected_message, error.message
    end
  end

  def test_commit_message_rejects_control_characters
    out, error = run_command_error("commit-residue", message: "fix residue\rfor me")

    assert_instance_of Hive::UsageError, error
    assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
  end

  def test_status_rejects_malformed_porcelain_records
    captured_argv = nil
    capture = lambda do |argv, **_kwargs|
      captured_argv = argv
      { success: true, stdout: "M malformed\0" }
    end

    with_replaced_singleton_method(Hive::Stages::AutoCommit, :capture_git_with_timeout, capture) do
      error = assert_raises(Hive::WorktreeError) do
        command("status").send(:worktree_status, @worktree)
      end

      assert_match(/malformed porcelain data/, error.message)
    end
    assert_includes captured_argv, "status"
  end

  private

  def command(subcommand, **options)
    Hive::Commands::Worktree.new(
      subcommand,
      @task.slug,
      json: true,
      pointer_resolver: ->(_task, _cfg) { @worktree },
      **options
    )
  end

  def run_command(subcommand, **options)
    out, = capture_io do
      with_resolved_task { command(subcommand, **options).call }
    end
    JSON.parse(out)
  end

  def run_command_error(subcommand, **options)
    error = nil
    out, = capture_io do
      with_resolved_task do
        error = assert_raises(Hive::Error) { command(subcommand, **options).call }
      end
    end
    [ out, error ]
  end

  def with_resolved_task
    original_resolve = Hive::TaskResolver.instance_method(:resolve)
    original_load = Hive::Config.method(:load)
    task = @task
    Hive::TaskResolver.define_method(:resolve) { task }
    Hive::Config.define_singleton_method(:load) { |_root| Hive::Config::DEFAULTS }
    yield
  ensure
    Hive::TaskResolver.define_method(:resolve, original_resolve)
    Hive::Config.define_singleton_method(:load, original_load)
  end
end
