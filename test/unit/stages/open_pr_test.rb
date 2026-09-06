require "test_helper"
require "hive/stages/open_pr"

class HiveStagesOpenPrTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(
    :folder, :state_file, :project_root, :slug, :depends_on, :id,
    keyword_init: true
  )

  class FakeGitGateway
    def repository_identity(**)
      { "host" => "github.com", "repository" => "acme/demo" }
    end
  end

  class FakeController
    attr_reader :request, :phases
    attr_accessor :creation_base_oid

    def initialize(publication)
      @publication = publication
      @phases = []
    end

    def publish!(request, revalidate:)
      @request = request
      %i[prepare before_push before_create final].each do |phase|
        @phases << phase
        raise "stale request" unless revalidate.call(phase)
      end
      @publication.merge(
        "publication_id" => request.publication_id,
        "head_oid" => request.head_oid
      )
    end
  end

  def cfg
    { "default_branch" => "master", "budget_usd" => {}, "timeout_sec" => {} }
  end

  def with_task
    with_tmp_dir do |root|
      repo = File.join(root, "repo")
      FileUtils.mkdir_p(repo)
      run!("git", "-C", repo, "init", "-b", "master", "--quiet")
      run!("git", "-C", repo, "config", "user.email", "test@example.com")
      run!("git", "-C", repo, "config", "user.name", "Test")
      File.write(File.join(repo, "README.md"), "base\n")
      run!("git", "-C", repo, "add", "README.md")
      run!("git", "-C", repo, "commit", "-m", "base", "--quiet")
      base_oid = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      run!("git", "-C", repo, "checkout", "-b", "open-pr-task", "--quiet")
      File.write(File.join(repo, "feature.rb"), "puts :feature\n")
      run!("git", "-C", repo, "add", "feature.rb")
      run!("git", "-C", repo, "commit", "-m", "Add feature", "--quiet")

      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      task = Task.new(
        folder: folder,
        state_file: File.join(folder, "pr.md"),
        project_root: repo,
        slug: "open-pr-task",
        id: 2
      )
      File.write(
        File.join(folder, "worktree.yml"),
        {
          "path" => repo, "branch" => task.slug,
          "base_branch" => "master", "base_oid" => base_oid
        }.to_yaml
      )
      write_authoring(task)
      yield task, repo, base_oid
    end
  end

  def write_authoring(task, title: "Add the feature", body: "## Summary\n\nAdds the feature.\n")
    File.write(
      File.join(task.folder, Hive::Stages::OpenPr::AUTHORING_FILE),
      JSON.generate("title" => title, "body" => body)
    )
  end

  def publication(state: "draft")
    {
      "number" => 42,
      "url" => "https://github.com/acme/demo/pull/42",
      "hosted_state" => state
    }
  end

  def test_run_delegates_every_remote_phase_to_shared_publication_controller
    with_task do |task, _repo, base_oid|
      controller = FakeController.new(publication)

      result = Hive::Stages::OpenPr.run!(
        task, cfg, git_gateway: FakeGitGateway.new, controller: controller
      )

      assert_equal({ commit: "pr_opened_draft", status: :complete }, result)
      assert_equal %i[prepare before_push before_create final], controller.phases
      assert_instance_of Hive::GithubPublication::Request, controller.request
      assert_equal base_oid, controller.request.creation_base_oid
      assert_equal "open-pr-task", controller.request.branch
      assert_equal "master", controller.request.base_branch
      assert_equal "Add the feature", controller.request.title
      diff = Hive::AgentGitGate.read(_repo, :diff, base_oid: base_oid, head_oid: controller.request.head_oid).stdout
      assert_equal Digest::SHA256.hexdigest(diff),
                   controller.request.diff_digest
      assert_includes diff, "feature.rb"
      assert_equal :complete, Hive::Markers.current(task.state_file).name
      assert_includes File.read(task.state_file), "publication_id: #{controller.request.publication_id}"
    end
  end

  def test_run_recovers_controller_owned_merged_publication
    with_task do |task, repo, _base_oid|
      run!("git", "-C", repo, "branch", "-f", "master", "HEAD")
      result = Hive::Stages::OpenPr.run!(
        task, cfg,
        git_gateway: FakeGitGateway.new,
        controller: FakeController.new(publication(state: "merged"))
      )

      assert_equal({ commit: "open_pr_already_merged", status: :complete }, result)
      marker = Hive::Markers.current(task.state_file)
      assert_equal :complete, marker.name
      assert_equal "true", marker.attrs.fetch("merged")
      assert_equal :review_complete,
                   Hive::Markers.current(File.join(task.folder, "task.md")).name
      assert_equal :complete,
                   Hive::Markers.current(File.join(task.folder, "artifact.md")).name
      assert_includes File.read(File.join(task.folder, "summary.md")), "PR #42"
    end
  end

  def test_publication_excludes_upstream_changes_since_task_creation
    with_task do |task, repo, original_base|
      run!("git", "-C", repo, "checkout", "master", "--quiet")
      File.write(File.join(repo, "upstream.txt"), "upstream changes\n" * 300_000)
      run!("git", "-C", repo, "add", "upstream.txt")
      run!("git", "-C", repo, "commit", "-m", "Advance upstream", "--quiet")
      run!("git", "-C", repo, "checkout", task.slug, "--quiet")
      run!("git", "-C", repo, "rebase", "master", "--quiet")
      controller = FakeController.new(publication)

      result = Hive::Stages::OpenPr.run!(task, cfg, git_gateway: FakeGitGateway.new, controller: controller)

      assert_equal :complete, result.fetch(:status)
      assert_equal original_base, controller.request.creation_base_oid
      diff = Hive::AgentGitGate.read(repo, :diff, base_oid: controller.request.scan_base_oid, head_oid: controller.request.head_oid).stdout
      refute_includes diff, "upstream.txt"
      assert_includes diff, "feature.rb"
    end
  end

  def test_publication_accepts_a_legitimate_patch_larger_than_four_megabytes
    with_task do |task, repo, _base|
      File.write(File.join(repo, "large.txt"), "ordinary content\n" * 300_000)
      run!("git", "-C", repo, "add", "large.txt")
      run!("git", "-C", repo, "commit", "-m", "Large change", "--quiet")
      controller = FakeController.new(publication)

      result = Hive::Stages::OpenPr.run!(task, cfg, git_gateway: FakeGitGateway.new, controller: controller)

      assert_equal :complete, result.fetch(:status)
      diff = Hive::AgentGitGate.read(repo, :diff, base_oid: controller.request.scan_base_oid, head_oid: controller.request.head_oid).stdout
      assert_operator diff.bytesize, :>, 4 * 1024 * 1024
      assert_equal Digest::SHA256.hexdigest(diff), controller.request.diff_digest
    end
  end

  def test_closed_publication_is_not_recreated
    with_task do |task, _repo, _base_oid|
      result = Hive::Stages::OpenPr.run!(
        task, cfg,
        git_gateway: FakeGitGateway.new,
        controller: FakeController.new(publication(state: "closed"))
      )

      assert_equal({ commit: "open_pr_closed", status: :error }, result)
      assert_equal "open_pr_closed", Hive::Markers.current(task.state_file).attrs.fetch("reason")
    end
  end

  def test_legacy_pointer_without_a_creation_base_uses_the_verified_pr_base
    with_task do |task, _repo, base_oid|
      path = File.join(task.folder, "worktree.yml")
      pointer = YAML.safe_load(File.read(path))
      pointer.delete("base_oid")
      File.write(path, pointer.to_yaml)
      controller = FakeController.new(publication)

      result = Hive::Stages::OpenPr.run!(task, cfg, git_gateway: FakeGitGateway.new, controller: controller)

      assert_equal :complete, result.fetch(:status)
      assert_equal base_oid, controller.request.creation_base_oid
      refute YAML.safe_load(File.read(path)).key?("base_oid")

      controller.creation_base_oid = base_oid
      replay = Hive::Stages::OpenPr.run!(task, cfg, git_gateway: FakeGitGateway.new, controller: controller)
      assert_equal :complete, replay.fetch(:status)
      assert_equal base_oid, controller.request.creation_base_oid
    end
  end

  def test_controller_block_is_attributed_without_a_second_publication_path
    with_task do |task, _repo, _base_oid|
      controller = Object.new
      controller.define_singleton_method(:publish!) do |*_args, **_kwargs|
        raise Hive::GithubPublication::Blocked.new("remote_branch_conflict", "branch moved")
      end

      result = Hive::Stages::OpenPr.run!(
        task, cfg, git_gateway: FakeGitGateway.new, controller: controller
      )

      assert_equal({ commit: "open_pr_remote_branch_conflict", status: :error }, result)
      marker = Hive::Markers.current(task.state_file)
      assert_equal "github_publication_remote_branch_conflict", marker.attrs.fetch("reason")
      assert_equal "branch moved", marker.attrs.fetch("detail")
    end
  end

  def test_authoring_report_is_bounded_strict_and_cannot_spoof_controller_markers
    with_task do |task, _repo, _base_oid|
      path = File.join(task.folder, Hive::Stages::OpenPr::AUTHORING_FILE)
      assert_equal "Add the feature", Hive::Stages::OpenPr.read_authoring(path).title

      File.write(path, JSON.generate("title" => "Title", "body" => "<!-- COMPLETE -->"))
      error = assert_raises(Hive::StageError) do
        Hive::Stages::OpenPr.read_authoring(path)
      end
      assert_includes error.message, "reserved controller marker"

      File.write(path, JSON.generate("title" => "Title", "body" => "Body", "url" => "remote"))
      error = assert_raises(Hive::StageError) do
        Hive::Stages::OpenPr.read_authoring(path)
      end
      assert_includes error.message, "only string title and body"
    end
  end

  def test_dirty_worktree_is_rejected_before_controller
    with_task do |task, repo, _base_oid|
      File.write(File.join(repo, "dirty.txt"), "dirty\n")
      controller = FakeController.new(publication)

      result = Hive::Stages::OpenPr.run!(
        task, cfg, git_gateway: FakeGitGateway.new, controller: controller
      )

      assert_equal({ commit: "open_pr_invalid_authoring", status: :error }, result)
      assert_nil controller.request
      assert_includes Hive::Markers.current(task.state_file).attrs.fetch("detail"), "dirty"
    end
  end

  def test_agent_spawn_produces_an_output_file_without_owning_the_stage_marker
    with_task do |task, _repo, _base_oid|
      FileUtils.rm_f(File.join(task.folder, Hive::Stages::OpenPr::AUTHORING_FILE))
      profile = Struct.new(:name).new(:opencode)
      scope = {
        add_dirs: [ task.folder ], permission_mode: "read-only",
        allowed_tools: nil, disallowed_tools: nil, runtime_policy: nil,
        additional_read_roots: [ task.folder ], additional_write_roots: []
      }
      captured = nil
      with_replaced_singleton_method(
        Hive::Stages::Base, :stage_permission_scope_or_mark!, ->(*, **) { scope }
      ) do
        with_replaced_singleton_method(
          Hive::Stages::Base, :spawn_agent,
          lambda do |*_args, **kwargs|
            captured = kwargs
            kwargs.fetch(:agent_custody).call do
              File.write(
                kwargs.fetch(:expected_output),
                JSON.generate("title" => "Title", "body" => "Body")
              )
            end
            { status: :ok }
          end
        ) do
          result = Hive::Stages::OpenPr.spawn_open_pr_agent(
            task, cfg, "prompt", profile, task.folder,
            launch_arguments: { identity_arguments: [] },
            agent_custody: Hive::ArtifactFirewall::AgentCustody.new(
              Hive::ArtifactFirewall::Manifest.new(
                root: task.folder,
                protected_anchors: {},
                permitted_writable_roots: [ task.folder ]
              )
            ),
            expected_output: File.join(task.folder, Hive::Stages::OpenPr::AUTHORING_FILE)
          )
          assert_equal({ status: :ok }, result)
        end
      end

      assert_equal :output_file_exists, captured.fetch(:status_mode)
      assert_equal task.folder, captured.fetch(:cwd)
      assert_equal "open_pr", captured.fetch(:implementation_stage)
      assert captured.fetch(:defer_implementation_observation)
    end
  end

  def test_rendered_prompt_explicitly_forbids_remote_mutation
    with_task do |task, repo, _base_oid|
      prompt = Hive::Stages::OpenPr.render_prompt(
        task, repo, task.slug,
        authoring_path: File.join(task.folder, Hive::Stages::OpenPr::AUTHORING_FILE),
        base_branch: "master"
      )

      assert_includes prompt, "Do not run `git push`, `gh`"
      assert_includes prompt, "publication controller exclusively owns"
      assert_includes prompt, '"title"'
      refute_includes prompt, "gh pr create"
    end
  end

  def test_authoring_agent_failures_are_durable_stage_errors
    with_task do |task, repo, base_oid|
      FileUtils.rm_f(File.join(task.folder, Hive::Stages::OpenPr::AUTHORING_FILE))
      pointer = { "path" => repo, "branch" => task.slug, "base_oid" => base_oid }
      profile = Struct.new(:name).new(:codex)
      custody = Object.new
      custody.define_singleton_method(:report) { nil }

      with_replaced_singleton_method(Hive::ArtifactFirewall::AgentCustody, :new, ->(*) { custody }) do
        with_replaced_singleton_method(
          Hive::Stages::OpenPr, :spawn_open_pr_agent, ->(*) { { status: :ok } }
        ) do
          result = Hive::Stages::OpenPr.authoring_for(
            task, cfg, pointer, nil, profile, {}
          )
          assert_equal({ commit: "open_pr_custody_missing", status: :error }, result)
        end

        with_replaced_singleton_method(
          Hive::Stages::OpenPr, :spawn_open_pr_agent,
          ->(*) { { status: :error, error_message: "provider failed" } }
        ) do
          result = Hive::Stages::OpenPr.authoring_for(
            task, cfg, pointer, nil, profile, {}
          )
          assert_equal({ commit: "open_pr_authoring_failed", status: :error }, result)
          assert_equal "provider failed", Hive::Markers.current(task.state_file).attrs.fetch("detail")
        end
      end
    end
  end

  def test_tampered_authoring_custody_is_rejected
    with_task do |task, repo, base_oid|
      FileUtils.rm_f(File.join(task.folder, Hive::Stages::OpenPr::AUTHORING_FILE))
      pointer = { "path" => repo, "branch" => task.slug, "base_oid" => base_oid }
      profile = Struct.new(:name).new(:codex)
      report = Object.new
      report.define_singleton_method(:tampered?) { true }
      report.define_singleton_method(:tampered_labels) { [ "task metadata" ] }
      report.define_singleton_method(:restored?) { false }
      report.define_singleton_method(:restore_diagnostic) { "restore failed" }
      custody = Object.new
      custody.define_singleton_method(:report) { report }

      with_replaced_singleton_method(Hive::ArtifactFirewall::AgentCustody, :new, ->(*) { custody }) do
        with_replaced_singleton_method(
          Hive::Stages::OpenPr, :spawn_open_pr_agent, ->(*) { { status: :ok } }
        ) do
          result = Hive::Stages::OpenPr.authoring_for(
            task, cfg, pointer, nil, profile, {}
          )
          assert_equal({ commit: "open_pr_tampered", status: :error }, result)
        end
      end
    end
  end

  def test_publication_request_rejects_non_descendant_and_invalid_identity
    task = Task.new(folder: Dir.pwd, state_file: "/tmp/pr.md", project_root: Dir.pwd,
                    slug: "feature", id: 2)
    pointer = { "path" => Dir.pwd, "branch" => "feature", "base_oid" => "a" * 40 }
    authoring = Hive::Stages::OpenPr::Authoring.new(title: "Title", body: "Body")
    result = Struct.new(:stdout, :stderr, :exitstatus, :overflow) do
      def success? = exitstatus.zero?
    end
    reads = {
      head_oid: result.new("#{'b' * 40}\n", "", 0, false),
      current_branch: result.new("feature\n", "", 0, false),
      status: result.new("", "", 0, false),
      ancestor: result.new("", "", 1, false)
    }
    with_replaced_singleton_method(
      Hive::Stages::OpenPr, :git_read!, ->(_path, operation, **) { reads.fetch(operation) }
    ) do
      error = assert_raises(Hive::StageError) do
        Hive::Stages::OpenPr.publication_request(
          task, cfg, pointer, authoring, git_gateway: FakeGitGateway.new
        )
      end
      assert_match(/not descended/, error.message)
    end

    assert_raises(Hive::StageError) do
      Hive::Stages::OpenPr.publication_request(
        task, cfg, {}, authoring, git_gateway: FakeGitGateway.new
      )
    end
  end

  def test_git_read_failure_reports_bounded_reason
    result = Struct.new(:stdout, :stderr, :exitstatus, :overflow) do
      def success? = exitstatus.zero?
    end
    [
      [ result.new("", "denied", 2, false), "denied" ],
      [ result.new("", "", 2, false), "git exited 2" ],
      [ result.new("", "", 2, true), "output exceeded its safe bound" ]
    ].each do |failure, expected|
      with_replaced_singleton_method(Hive::AgentGitGate, :read, ->(*) { failure }) do
        error = assert_raises(Hive::StageError) do
          Hive::Stages::OpenPr.git_read!(Dir.pwd, :status)
        end
        assert_includes error.message, expected
      end
    end
  end

  def test_authoring_file_missing_and_symlink_are_rejected
    with_tmp_dir do |dir|
      missing = File.join(dir, "missing.json")
      error = assert_raises(Hive::StageError) do
        Hive::Stages::OpenPr.read_authoring(missing)
      end
      assert_match(/is missing/, error.message)

      target = File.join(dir, "target.json")
      link = File.join(dir, "link.json")
      File.write(target, JSON.generate("title" => "Title", "body" => "Body"))
      File.symlink(target, link)
      error = assert_raises(Hive::StageError) do
        Hive::Stages::OpenPr.read_authoring(link)
      end
      assert_match(/not a symlink/, error.message)

      with_replaced_singleton_method(File, :open, ->(*) { raise Errno::EACCES, "denied" }) do
        error = assert_raises(Hive::StageError) do
          Hive::Stages::OpenPr.read_authoring(target)
        end
        assert_match(/is unreadable: Errno::EACCES/, error.message)
      end
    end
  end

  def test_publication_agent_uses_the_bound_implementation_profile
    identity = Struct.new(:provider).new(:codex)
    profile = Object.new
    expected_cfg = cfg
    test_case = self
    task = Task.new(folder: "/tmp/task", project_root: "/tmp/project", slug: "task")
    with_replaced_singleton_method(
      Hive::Stages::Base, :implementation_stage_identity, ->(*) { identity }
    ) do
      with_replaced_singleton_method(
        Hive::AgentProfiles, :lookup,
        lambda do |provider, cfg:|
          test_case.assert_equal :codex, provider
          test_case.assert_equal expected_cfg, cfg
          profile
        end
      ) do
        with_replaced_singleton_method(
          Hive::Stages::Base, :implementation_launch_arguments,
          ->(seen_identity, seen_profile) { { identity: seen_identity, profile: seen_profile } }
        ) do
          assert_equal [ identity, profile, { identity: identity, profile: profile } ],
                       Hive::Stages::OpenPr.publication_agent(task, cfg)
        end
      end
    end
  end

  def test_pr_observation_records_attempt_bound_activity
    task = Task.new(folder: "/tmp/task", project_root: "/tmp/project", slug: "task")
    context = Struct.new(:attempt_id).new("attempt-1")
    captured = nil
    with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
      with_replaced_singleton_method(
        Hive::Stages::Base, :record_task_activity,
        lambda { |seen_task, **kwargs| captured = [ seen_task, kwargs ]; true }
      ) do
        assert Hive::Stages::OpenPr.record_pr_observation(
          task,
          { "number" => 42, "head_oid" => "a" * 40 },
          "merged"
        )
      end
    end

    assert_same task, captured.first
    assert_equal "merge_observed", captured.last.fetch(:kind)
    assert_equal "publication:attempt-1:merged:42", captured.last.fetch(:operation_id)
  end

  def test_default_git_gateway_and_existing_dependency_branch
    with_task do |task, _repo, _base_oid|
      gateway = Hive::Stages::OpenPr.default_git_gateway(
        cfg.merge("agent_git_gate" => { "allow_local_transport" => true })
      )
      assert_instance_of Hive::GithubPublication::GitGateway, gateway

      with_replaced_singleton_method(
        Hive::DependencySnapshot, :stacked_base, ->(*) { "dependency" }
      ) do
        with_replaced_singleton_method(
          Hive::Worktree, :origin_branch_exists?, ->(*) { true }
        ) do
          assert_equal "dependency",
                       Hive::Stages::OpenPr.dependency_pr_base_branch(task, cfg)
        end
      end
    end
  end
end
