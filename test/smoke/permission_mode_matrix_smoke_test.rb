require "test_helper"
require "yaml"
require "hive/config"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"

# Live-claude smoke for the claude.permission_mode change. Spawns the real
# `claude` binary and asserts a brainstorm round completes end-to-end across
# the (launch mode x permission mode) matrix, proving the flags Hive emits are
# accepted by the installed CLI on BOTH paths:
#
#   - tmux     + bypassPermissions -> wrapper passes --dangerously-skip-permissions
#   - tmux     + acceptEdits       -> wrapper passes --permission-mode acceptEdits
#   - headless + bypassPermissions -> `claude -p --dangerously-skip-permissions`
#   - headless + acceptEdits       -> `claude -p --permission-mode acceptEdits`
#
# Excluded from the default `rake test` suite — invoke via `rake smoke`.
# Each case is one real claude run (~$0.25); headless `-p` may bill API tokens.
class PermissionModeMatrixSmokeTest < Minitest::Test
  include HiveTestHelper

  NON_DEFAULT_MODE = "acceptEdits".freeze

  def setup
    skip "claude binary not on PATH" unless system("which claude > /dev/null 2>&1")
  end

  def test_tmux_bypass_permissions_completes_brainstorm
    assert_brainstorm_completes(mode: "tmux", permission_mode: "bypassPermissions")
  end

  def test_tmux_non_default_permission_mode_completes_brainstorm
    assert_brainstorm_completes(mode: "tmux", permission_mode: NON_DEFAULT_MODE)
  end

  def test_headless_bypass_permissions_completes_brainstorm
    assert_brainstorm_completes(mode: "headless", permission_mode: "bypassPermissions")
  end

  def test_headless_non_default_permission_mode_completes_brainstorm
    assert_brainstorm_completes(mode: "headless", permission_mode: NON_DEFAULT_MODE)
  end

  private

  def assert_brainstorm_completes(mode:, permission_mode:)
    label = "claude.mode=#{mode} claude.permission_mode=#{permission_mode}"
    # Keep the real HOME so the spawned claude reuses the operator's
    # logged-in session credentials (~/.claude); only HIVE_HOME is isolated.
    # Without this the tmux/headless claude drops to the login screen.
    real_home = ENV.fetch("HOME")
    with_tmp_global_config(home: real_home) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        patch_claude_config(dir, mode: mode, permission_mode: permission_mode)

        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "add a contributing note").call }

        brainstorm_dir = move_inbox_task_to_brainstorm(dir)
        Hive::Commands::Run.new(brainstorm_dir).call

        brainstorm_md = File.join(brainstorm_dir, "brainstorm.md")
        assert File.exist?(brainstorm_md),
               "brainstorm.md must exist after live claude run (#{label})"

        marker = Hive::Markers.current(brainstorm_md)
        assert_equal :waiting, marker.name,
                     "brainstorm Round 1 must end with WAITING for #{label} " \
                     "(got #{marker.name}: #{marker.attrs.inspect})"
        assert_match(/##\s+Round\s+1/i, File.read(brainstorm_md),
                     "brainstorm.md must contain '## Round 1' for #{label}")
      end
    end
  end

  # Rewrites the claude block of the rendered config.yml. YAML round-trip drops
  # the template comments, which is fine for a throwaway smoke project; the
  # subsequent Config.load validates the result.
  def patch_claude_config(dir, mode:, permission_mode:)
    path = File.join(dir, ".hive-state", "config.yml")
    cfg = YAML.safe_load(File.read(path))
    cfg["claude"] ||= {}
    cfg["claude"]["mode"] = mode
    cfg["claude"]["permission_mode"] = permission_mode
    File.write(path, YAML.dump(cfg))

    loaded = Hive::Config.load(dir)
    assert_equal mode, loaded.dig("claude", "mode")
    assert_equal permission_mode, loaded.dig("claude", "permission_mode")
  end

  def move_inbox_task_to_brainstorm(dir)
    slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
    brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
    FileUtils.mkdir_p(File.dirname(brainstorm_dir))
    FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)
    brainstorm_dir
  end
end
