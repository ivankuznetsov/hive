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
      assert_equal Digest::SHA256.hexdigest(controller.request.diff),
                   controller.request.diff_digest
      assert_includes controller.request.diff, "feature.rb"
      assert_equal :complete, Hive::Markers.current(task.state_file).name
      assert_includes File.read(task.state_file), "publication_id: #{controller.request.publication_id}"
    end
  end

  def test_run_recovers_controller_owned_merged_publication
    with_task do |task, _repo, _base_oid|
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
end
