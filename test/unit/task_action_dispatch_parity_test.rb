require "test_helper"
require "fileutils"
require "hive/markers"
require "hive/task_action"
require "hive/workflows/coding"

class TaskActionDispatchParityTest < Minitest::Test
  include HiveTestHelper

  Marker = Hive::Markers::State
  FakeTask = Struct.new(
    :stage_name, :stage_index, :slug, :project_root, :project_name, :folder,
    :state_file, :log_dir, :workflow,
    keyword_init: true
  )

  class LegacyCaseTaskAction < Hive::TaskAction
    private

      def action
        override = universal_action
        return override if override

        case task.stage_name
        when "inbox"
          ACTIONS.fetch(:inbox)
        when "brainstorm"
          brainstorm_action
        when "plan"
          plan_action
        when "execute"
          execute_action
        when "open-pr"
          marker.name == :complete ? ACTIONS.fetch(:open_pr_complete) : ACTIONS.fetch(:open_pr_ready)
        when "review"
          review_action
        when "artifacts"
          artifacts_action
        when "finalize"
          finalize_action
        when "done"
          ACTIONS.fetch(:done)
        else
          ACTIONS.fetch(:error)
        end
      end
  end

  def test_case_and_kind_dispatch_match_for_coding_matrix
    with_tmp_dir do |root|
      parity_scenarios.each_with_index do |scenario, index|
        task = build_task(root, scenario, index)
        marker_state = marker(scenario.fetch(:marker), scenario.fetch(:attrs, {}))
        scenario[:setup]&.call(task, marker_state)
        kwargs = scenario.fetch(:kwargs, {})

        legacy = LegacyCaseTaskAction.new(task, marker_state, **kwargs)
        kind = Hive::TaskAction.for(task, marker_state, **kwargs)

        assert_value_equal legacy.key, kind.key, failure_label(scenario, "key")
        assert_value_equal legacy.label, kind.label, failure_label(scenario, "label")
        # NOTE: this `command` column is NOT independent coverage of the unified
        # `#command` builder. `LegacyCaseTaskAction` overrides only `#action`, so
        # both sides compute `command` through the *same* production builder; a
        # regression in the `generic_command`->unified-`command` refactor itself
        # would change both columns identically and pass here. The builder's
        # exact command strings are pinned in task_action_test.rb (coding) and
        # task_action_generic_test.rb (generic) — this column only proves the two
        # dispatch paths agree on which ACTIONS row to emit.
        assert_value_equal legacy.command, kind.command, failure_label(scenario, "command")
        assert_value_equal legacy.next_action, kind.next_action, failure_label(scenario, "next_action")

        legacy_diagnostic = legacy.diagnostic
        kind_diagnostic = kind.diagnostic
        assert_value_equal diagnostic_summary(legacy_diagnostic), diagnostic_summary(kind_diagnostic),
                           failure_label(scenario, "diagnostic.summary")
        assert_value_equal suggested_next_action(legacy_diagnostic), suggested_next_action(kind_diagnostic),
                           failure_label(scenario, "diagnostic.suggested_next_action")
      end
    end
  end

  private

    def marker(name, attrs = {})
      Marker.new(name: name, attrs: attrs, raw: nil)
    end

    def build_task(root, scenario, index)
      stage_name = scenario.fetch(:stage)
      stage_index = Hive::Stages::NAMES.index(stage_name) + 1
      slug = scenario.fetch(:slug, format("demo-%02d-260622", index))
      folder = File.join(root, ".hive-state", "stages", "#{stage_index}-#{stage_name}", slug)
      FileUtils.mkdir_p(folder)
      workflow = Hive::Workflows::Coding::DESCRIPTOR
      state_file = File.join(folder, workflow.state_file_for(stage_name))

      FakeTask.new(
        stage_name: stage_name,
        stage_index: stage_index,
        slug: slug,
        project_root: root,
        project_name: File.basename(root),
        folder: folder,
        state_file: state_file,
        log_dir: File.join(root, ".hive-state", "logs", slug),
        workflow: workflow
      )
    end

    def parity_scenarios
      [
        *common_stage_scenarios,
        *universal_override_scenarios,
        *execute_scenarios,
        *review_scenarios,
        *plan_scenarios,
        *open_pr_scenarios,
        *finalize_scenarios,
        *command_shape_scenarios
      ]
    end

    def common_stage_scenarios
      %w[inbox done brainstorm artifacts].flat_map do |stage|
        [
          { name: "#{stage} none", stage: stage, marker: :none },
          { name: "#{stage} waiting", stage: stage, marker: :waiting },
          { name: "#{stage} complete", stage: stage, marker: :complete }
        ]
      end
    end

    def universal_override_scenarios
      [
        { name: "live task lock", stage: "execute", marker: :execute_complete, kwargs: { live_task_lock: true } },
        { name: "agent working live", stage: "plan", marker: :agent_working, attrs: { "pid" => "12345" }, kwargs: { pid_alive: true } },
        { name: "agent working dead pid", stage: "execute", marker: :agent_working, attrs: { "pid" => "12345" }, kwargs: { pid_alive: false } },
        {
          name: "agent working orphaned",
          stage: "execute",
          marker: :agent_working,
          kwargs: { pid_alive: nil, state_file_mtime: Time.now - 600, agent_marker_grace_sec: 300 }
        },
        { name: "explicit error", stage: "review", marker: :error, attrs: { "reason" => "agent_failed", "exit_code" => "70" } },
        { name: "manual steering", stage: "brainstorm", marker: :manual_steering, attrs: { "agent" => "codex" } }
      ]
    end

    def execute_scenarios
      [
        { name: "execute waiting", stage: "execute", marker: :execute_waiting },
        { name: "execute waiting findings", stage: "execute", marker: :execute_waiting, attrs: { "findings_count" => "2" } },
        { name: "execute waiting next action", stage: "execute", marker: :execute_waiting, attrs: { "reason" => "no_worktree_changes" } },
        { name: "execute complete", stage: "execute", marker: :execute_complete },
        { name: "execute stale", stage: "execute", marker: :execute_stale, attrs: { "pass" => "3" } }
      ]
    end

    def review_scenarios
      [
        # Fall-through marker: exercises the `else -> review_ready`
        # (READY_FOR_REVIEW) arm of `review_action`, the one coding
        # (stage x marker) cell the rest of this matrix never compares across
        # the two dispatch paths (independently pinned in task_action_test.rb).
        { name: "review ready", stage: "review", marker: :none },
        { name: "review working", stage: "review", marker: :review_working, attrs: { "phase" => "reviewers" } },
        { name: "review waiting", stage: "review", marker: :review_waiting, attrs: { "pass" => "1" } },
        { name: "review complete", stage: "review", marker: :review_complete },
        { name: "review stale", stage: "review", marker: :review_stale, attrs: { "pass" => "2", "reason" => "wall_clock" } },
        { name: "review ci stale", stage: "review", marker: :review_ci_stale, attrs: { "attempts" => "3" } },
        { name: "review error", stage: "review", marker: :review_error, attrs: { "phase" => "fix", "pass" => "1", "reason" => "timeout" } }
      ]
    end

    def plan_scenarios
      [
        { name: "plan none fresh missing", stage: "plan", marker: :none },
        {
          name: "plan none missing after run",
          stage: "plan",
          marker: :none,
          setup: lambda do |task, _marker|
            FileUtils.mkdir_p(task.log_dir)
            File.write(File.join(task.log_dir, "plan-20260622T010203Z.log"), "spawned\n")
          end
        },
        {
          name: "plan none empty artifact",
          stage: "plan",
          marker: :none,
          setup: ->(task, _marker) { File.write(task.state_file, "") }
        },
        { name: "plan waiting", stage: "plan", marker: :waiting },
        { name: "plan complete", stage: "plan", marker: :complete }
      ]
    end

    def open_pr_scenarios
      [
        { name: "open-pr none", stage: "open-pr", marker: :none },
        { name: "open-pr waiting", stage: "open-pr", marker: :waiting },
        { name: "open-pr complete draft", stage: "open-pr", marker: :complete, attrs: { "is_draft" => "true" } },
        { name: "open-pr complete ready", stage: "open-pr", marker: :complete, attrs: { "is_draft" => "false" } }
      ]
    end

    def finalize_scenarios
      [
        { name: "finalize none missing pr", stage: "finalize", marker: :none },
        {
          name: "finalize none pr present",
          stage: "finalize",
          marker: :none,
          setup: ->(task, _marker) { File.write(task.state_file, "---\npr_url: https://example.com/pr/9\n---\n") }
        },
        {
          name: "finalize complete archive",
          stage: "finalize",
          marker: :complete,
          attrs: { "pr_url" => "https://example.com/pr/9", "is_draft" => "false" },
          setup: ->(task, _marker) { write_pr_frontmatter(task, "https://example.com/pr/9") }
        },
        {
          name: "finalize complete draft fallback",
          stage: "finalize",
          marker: :complete,
          attrs: { "pr_url" => "https://example.com/pr/9", "is_draft" => "true" },
          setup: ->(task, _marker) { write_pr_frontmatter(task, "https://example.com/pr/9") }
        },
        {
          name: "finalize complete missing url",
          stage: "finalize",
          marker: :complete,
          attrs: { "is_draft" => "false" },
          setup: ->(task, _marker) { File.write(task.state_file, "<!-- COMPLETE is_draft=false -->\n") }
        },
        {
          name: "finalize complete url mismatch",
          stage: "finalize",
          marker: :complete,
          attrs: { "pr_url" => "https://example.com/pr/other", "is_draft" => "false" },
          setup: ->(task, _marker) { write_pr_frontmatter(task, "https://example.com/pr/9") }
        },
        {
          name: "finalize complete invalid frontmatter",
          stage: "finalize",
          marker: :complete,
          attrs: { "pr_url" => "https://example.com/pr/9", "is_draft" => "false" },
          setup: ->(task, _marker) { File.write(task.state_file, "---\n: bad\n---\n") }
        }
      ]
    end

    def command_shape_scenarios
      [
        {
          name: "stage collision findings",
          stage: "execute",
          marker: :execute_stale,
          kwargs: { stage_collision: true }
        },
        {
          name: "multi-project command",
          stage: "plan",
          marker: :complete,
          kwargs: { project_name: "proj-a", project_count: 3 }
        },
        {
          name: "shellescaped slug",
          stage: "brainstorm",
          marker: :complete,
          slug: "weird slug"
        }
      ]
    end

    def write_pr_frontmatter(task, url)
      File.write(task.state_file, <<~MD)
        ---
        pr_url: #{url}
        ---

        <!-- COMPLETE pr_url=#{url} is_draft=false -->
      MD
    end

    def diagnostic_summary(diagnostic)
      diagnostic && diagnostic["summary"]
    end

    def suggested_next_action(diagnostic)
      diagnostic && diagnostic["suggested_next_action"]
    end

    def assert_value_equal(expected, actual, message)
      if expected.nil?
        assert_nil actual, message
      else
        assert_equal expected, actual, message
      end
    end

    def failure_label(scenario, field)
      "scenario=#{scenario.fetch(:name)} field=#{field}"
    end
end
