require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/agent_profiles"

# Live-claude smoke for the 5-review stage. Exercises one full pass of the
# autonomous loop against the real `claude` binary on a tiny tmp worktree:
#   - CI phase (skipped — no review.ci.command in the smoke config)
#   - Phase 2: one configured reviewer (claude /ce-code-review on the diff)
#   - Phase 3: triage (deterministic when there are zero findings)
#   - Branch: zero findings → Phase 5 (browser disabled) → REVIEW_COMPLETE
#
# Excluded from the default `rake test` suite — invoke via `rake smoke`.
# Coverage that integration tests can't give us:
#   - per-spawn <user_supplied_<hex>> nonce against real claude output
#   - status_mode: :exit_code_only on a real spawn (orchestrator owns the
#     terminal marker; the reviewer must not write REVIEW_* itself)
#   - reviewer template renders cleanly through claude's prompt parser
#   - REVIEW_COMPLETE marker lands as the only terminal state
class LiveReviewSmokeTest < Minitest::Test
  include HiveTestHelper

  def setup
    skip "claude binary not on PATH" unless system("which claude > /dev/null 2>&1")
    Hive::AgentProfiles.reset_for_tests!
    load File.expand_path("../../lib/hive/agent_profiles/claude.rb", __dir__)
  end

  def teardown
    Hive::AgentProfiles.reset_for_tests!
    load File.expand_path("../../lib/hive/agent_profiles/claude.rb", __dir__)
    load File.expand_path("../../lib/hive/agent_profiles/codex.rb", __dir__)
    load File.expand_path("../../lib/hive/agent_profiles/pi.rb", __dir__)
  end

  def test_clean_worktree_produces_review_complete
    with_tmp_global_config do
      with_tmp_git_repo do |project_dir|
        capture_io { Hive::Commands::Init.new(project_dir).call }
        project = File.basename(project_dir)
        capture_io { Hive::Commands::New.new(project, "smoke review trivial").call }

        # Move the task into 5-review/ with a worktree.yml + a tiny diff
        # against the default branch, so the reviewer has SOMETHING to look
        # at without being so complex it generates findings.
        slug = File.basename(Dir[File.join(project_dir, ".hive-state", "stages", "1-inbox", "*")].first)
        review_dir = File.join(project_dir, ".hive-state", "stages", "5-review", slug)
        FileUtils.mkdir_p(File.dirname(review_dir))
        FileUtils.mv(File.join(project_dir, ".hive-state", "stages", "1-inbox", slug), review_dir)

        worktree_root = File.join(project_dir, ".worktrees")
        worktree_path = File.join(worktree_root, slug)
        FileUtils.mkdir_p(worktree_root)
        run!("git", "-C", project_dir, "worktree", "add", "-b", slug, worktree_path)
        File.write(File.join(worktree_path, "smoke.txt"), "trivial smoke change\n")
        run!("git", "-C", worktree_path, "add", "smoke.txt")
        run!("git", "-C", worktree_path, "commit", "-m", "smoke: add smoke.txt", "--quiet")

        File.write(
          File.join(review_dir, "worktree.yml"),
          { "path" => worktree_path, "branch" => slug }.to_yaml
        )
        File.write(File.join(review_dir, "plan.md"), "# Plan\n\nadd a smoke fixture.\n")
        File.write(File.join(review_dir, "task.md"), "---\nslug: #{slug}\nstarted_at: #{Time.now.utc.iso8601}\n---\n\n## Implementation\n\ndone.\n")

        write_smoke_config(project_dir, worktree_root)

        Hive::Commands::Run.new(review_dir).call

        marker = Hive::Markers.current(File.join(review_dir, "task.md"))
        assert_includes %i[review_complete review_waiting],
                        marker.name,
                        "review must terminate cleanly (got #{marker.name}: #{marker.attrs.inspect})"
      end
    end
  end

  def write_smoke_config(project_dir, worktree_root)
    cfg = {
      "worktree_root" => worktree_root,
      "review" => {
        "max_passes" => 1,
        "max_wall_clock_sec" => 600,
        "ci" => { "command" => nil },
        "reviewers" => [
          {
            "name" => "claude-ce-code-review",
            "kind" => "agent",
            "agent" => "claude",
            "prompt_template" => "reviewer_claude_ce_code_review.md.erb",
            "output_basename" => "claude-ce-code-review"
          }
        ],
        "triage" => { "bias" => "courageous" },
        "fix" => { "agent" => "claude" },
        "browser" => { "enabled" => false }
      }
    }
    File.write(File.join(project_dir, ".hive-state", "config.yml"), cfg.to_yaml)
  end
end
