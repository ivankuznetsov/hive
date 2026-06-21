require "test_helper"
require "open3"
require "timeout"
require "hive/agent_profiles"
require "hive/permission_scope"
require "hive/stages/base"
require "hive/task"

# Live-claude smoke for per-stage permission scopes. Spawns the real `claude`
# binary in headless mode and proves a read-only scope denies a write without
# hanging, while yolo still permits the same write. Excluded from the default
# `rake test` suite — invoke via `rake smoke`.
class PermissionScopeHeadlessSmokeTest < Minitest::Test
  include HiveTestHelper

  SPAWN_TIMEOUT_SEC = 120
  OUTER_TIMEOUT_SEC = SPAWN_TIMEOUT_SEC + 20

  def setup
    @claude_bin = real_claude_bin
    skip "claude binary not on PATH" unless @claude_bin

    @previous_claude_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = @claude_bin
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    if defined?(@previous_claude_bin)
      if @previous_claude_bin.nil?
        ENV.delete("HIVE_CLAUDE_BIN")
      else
        ENV["HIVE_CLAUDE_BIN"] = @previous_claude_bin
      end
    end
    Hive::AgentProfile.reset_version_cache!
  end

  def test_read_only_headless_denies_write_without_hanging
    with_tmp_dir do |dir|
      task = make_task(dir, "read-only-smoke-260621-aaaa")
      target = File.join(task.folder, "read-only-write.txt")
      result = run_scoped_write(task, target, permissions: "read-only")

      assert_equal :ok, result.fetch(:status)
      assert_equal 0, result.fetch(:exit_code)
      refute result.fetch(:timed_out), "read-only write attempt must finish without timeout"
      refute_path_exists target, "read-only scope must not create #{target}"
    end
  end

  def test_yolo_headless_allows_same_write
    with_tmp_dir do |dir|
      task = make_task(dir, "yolo-smoke-260621-aaaa")
      target = File.join(task.folder, "yolo-write.txt")
      result = run_scoped_write(task, target, permissions: "yolo")

      assert_equal :ok, result.fetch(:status)
      assert_equal 0, result.fetch(:exit_code)
      refute result.fetch(:timed_out), "yolo write attempt must finish without timeout"
      assert_path_exists target, "yolo control must create #{target}"
      assert_equal smoke_content, File.read(target)
    end
  end

  private

  def real_claude_bin
    out, status = Open3.capture2("which", "claude")
    return nil unless status.success?

    out.strip
  end

  def make_task(dir, slug)
    folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "task.md"), "# Smoke task\n")
    Hive::Task.new(folder)
  end

  def run_scoped_write(task, target, permissions:)
    profile = Hive::AgentProfiles.lookup(:claude)
    scope = Hive::PermissionScope.resolve(
      permissions,
      task_folder: task.folder,
      profile: profile,
      stage: "execute"
    )

    Timeout.timeout(OUTER_TIMEOUT_SEC) do
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: write_prompt(target),
        add_dirs: [ task.folder ] + scope.add_dirs_extra,
        cwd: task.folder,
        max_budget_usd: 1,
        timeout_sec: SPAWN_TIMEOUT_SEC,
        log_label: "permission-scope-smoke-#{permissions}",
        profile: profile,
        permission_mode: scope.permission_mode,
        allowed_tools: scope.allowed_tools,
        disallowed_tools: scope.disallowed_tools,
        status_mode: :exit_code_only
      )
    end
  end

  def write_prompt(target)
    <<~PROMPT
      You are running a Hive permission-scope smoke test.
      Use the Write tool exactly once to create this file:
      #{target}

      The file content must be exactly:
      #{smoke_content}

      After the write succeeds or is denied, finish without asking follow-up questions.
    PROMPT
  end

  def smoke_content
    "hive permission scope smoke\n"
  end
end
