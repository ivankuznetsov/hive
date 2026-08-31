require "test_helper"
require "hive/commands/init"
require "hive/commands/run"
require "hive/stages/open_pr"

class RunOpenPrTest < Minitest::Test
  include HiveTestHelper

  class FakeGitGateway
    def repository_identity(**)
      { "host" => "github.com", "repository" => "acme/app" }
    end
  end

  class FakeController
    attr_reader :requests

    def initialize(state: "draft")
      @state = state
      @requests = []
    end

    def publish!(request, revalidate:)
      @requests << request
      raise "request changed" unless revalidate.call(:before_push)
      raise "request changed" unless revalidate.call(:before_create)

      {
        "publication_id" => request.publication_id,
        "number" => 9,
        "url" => "https://github.com/acme/app/pull/9",
        "hosted_state" => @state,
        "head_oid" => request.head_oid
      }
    end
  end

  def setup
    @previous_claude = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_CLAUDE_FIXTURE
    @worktree_roots = []
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @previous_claude
    ENV.delete("HIVE_FAKE_CLAUDE_WRITE_FILE")
    ENV.delete("HIVE_FAKE_CLAUDE_WRITE_CONTENT")
    @worktree_roots.each { |path| FileUtils.rm_rf(path) }
  end

  def setup_open_pr_task(project_root)
    capture_io { Hive::Commands::Init.new(project_root).call }
    set_project_claude_mode(project_root, "headless")
    slug = "fix-bug-260424-aaaa"
    task_dir = File.join(project_root, ".hive-state", "stages", "5-open-pr", slug)
    FileUtils.mkdir_p(task_dir)
    ensure_test_task_identity(task_dir)
    File.write(File.join(task_dir, "plan.md"), "## Plan\nImplement the fix.\n")
    File.write(File.join(task_dir, "task.md"), "## Execute Output\nImplemented and tested.\n")

    base_oid = run!("git", "-C", project_root, "rev-parse", "HEAD").strip
    worktree_root = Hive::Worktree.default_worktree_root(File.basename(project_root))
    worktree_path = File.join(worktree_root, slug)
    FileUtils.mkdir_p(worktree_root)
    @worktree_roots << worktree_root
    run!(
      "git", "-C", project_root, "worktree", "add", "-b", slug,
      worktree_path, "master", "--quiet"
    )
    run!("git", "-C", worktree_path, "config", "commit.gpgsign", "false")
    File.write(File.join(worktree_path, "fix.rb"), "puts :fixed\n")
    run!("git", "-C", worktree_path, "add", "fix.rb")
    run!("git", "-C", worktree_path, "commit", "-m", "Fix bug", "--quiet")
    File.write(
      File.join(task_dir, "worktree.yml"),
      {
        "path" => worktree_path, "branch" => slug,
        "base_branch" => "master", "base_oid" => base_oid
      }.to_yaml
    )
    [ task_dir, worktree_path ]
  end

  def with_publication_controller(controller)
    with_replaced_singleton_method(
      Hive::Stages::OpenPr, :default_git_gateway, ->(_cfg) { FakeGitGateway.new }
    ) do
      with_replaced_singleton_method(
        Hive::GithubPublication::Controller, :new, ->(**_kwargs) { controller }
      ) do
        yield
      end
    end
  end

  def test_open_pr_command_authors_locally_then_delegates_publication
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        task_dir, _worktree_path = setup_open_pr_task(project_root)
        draft_path = File.join(task_dir, Hive::Stages::OpenPr::AUTHORING_FILE)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = draft_path
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = JSON.generate(
          "title" => "Fix the bug",
          "body" => "## Summary\n\nFixes the bug and records validation.\n"
        )
        controller = FakeController.new

        with_publication_controller(controller) do
          capture_io { Hive::Commands::Run.new(task_dir).call }
        end

        assert_equal 1, controller.requests.length
        request = controller.requests.first
        assert_equal "Fix the bug", request.title
        assert_includes request.diff, "fix.rb"
        pr_md = File.read(File.join(task_dir, "pr.md"))
        assert_includes pr_md, "https://github.com/acme/app/pull/9"
        assert_includes pr_md, "publication_id: #{request.publication_id}"
        marker = Hive::Markers.current(File.join(task_dir, "pr.md"))
        assert_equal :complete, marker.name
        assert_equal "true", marker.attrs.fetch("is_draft")
      end
    end
  end

  def test_invalid_authoring_json_stops_before_publication
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        task_dir, _worktree_path = setup_open_pr_task(project_root)
        draft_path = File.join(task_dir, Hive::Stages::OpenPr::AUTHORING_FILE)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = draft_path
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = JSON.generate(
          "title" => "Fix", "body" => "Body", "pr_url" => "untrusted"
        )
        controller = FakeController.new

        _out, err, status = with_publication_controller(controller) do
          with_captured_exit { Hive::Commands::Run.new(task_dir).call }
        end

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status, err
        assert_empty controller.requests
        marker = Hive::Markers.current(File.join(task_dir, "pr.md"))
        assert_equal :error, marker.name
        assert_equal "open_pr_invalid_authoring", marker.attrs.fetch("reason")
      end
    end
  end

  def test_open_pr_without_worktree_pointer_exits_one
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        task_dir, _worktree_path = setup_open_pr_task(project_root)
        FileUtils.rm_f(File.join(task_dir, "worktree.yml"))

        _out, err, status = with_captured_exit do
          Hive::Commands::Run.new(task_dir).call
        end

        assert_equal 1, status
        assert_match(/worktree ownership validation failed: worktree\.yml is missing/, err)
        assert_match(/4-execute/, err)
      end
    end
  end
end
