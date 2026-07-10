require "test_helper"
require "hive/honeycomb/permission_summary"

class HoneycombPermissionSummaryTest < Minitest::Test
  def test_summarizes_stage_reviewer_and_revise_shell_declarations
    workflow = Hive::Workflow.new(
      id: :review,
      stages: [
        Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
        Hive::Workflow::Stage.new(
          name: "draft", index: 2, state_file: "draft.md", kind: :agent, skill: "/draft",
          permissions: "read-only"
        ),
        Hive::Workflow::Stage.new(
          name: "review", index: 3, state_file: "review.md", kind: :council,
          permissions: "yolo",
          reviewers: [
            Hive::Workflow::Reviewer.new(
              name: "shell", skill: "/review",
              permissions: {
                "preset" => "scoped", "tools" => %w[Read Bash],
                "dirs" => [ "./fixtures" ],
                "shell_justification" => "Runs repository checks"
              }
            ),
            Hive::Workflow::Reviewer.new(name: "inherited", prompt: "Review.")
          ],
          council: Hive::Workflow::Council.new(
            quorum: 2,
            revise: Hive::Workflow::Revise.new(
              skill: "/revise",
              permissions: { "preset" => "scoped", "bash" => false }
            )
          )
        )
      ]
    )

    summary = Hive::Honeycomb::PermissionSummary.build(workflow)
    contexts = summary.fetch("contexts").to_h { |row| [ row.fetch("context"), row ] }

    assert_equal "not_applicable", contexts.fetch("stage:inbox").fetch("preset")
    assert_equal "disabled", contexts.fetch("stage:draft").fetch("shell_exposure")
    assert_equal "unrestricted", contexts.fetch("stage:review").fetch("shell_exposure")
    shell = contexts.fetch("stage:review/reviewer:shell")
    assert_equal "explicit_bash", shell.fetch("shell_exposure")
    assert_equal "Runs repository checks", shell.fetch("shell_justification")
    assert_equal %w[Read Bash], shell.fetch("tools")
    assert_equal [ "./fixtures" ], shell.fetch("dirs")
    assert_equal "inherit", contexts.fetch("stage:review/reviewer:inherited").fetch("preset")
    assert_equal "disabled", contexts.fetch("stage:review/revise").fetch("shell_exposure")

    aggregate = summary.fetch("aggregate")
    assert_equal aggregate.fetch("presets").sort, aggregate.fetch("presets")
    assert_equal %w[Bash Read], aggregate.fetch("tools")
    assert_includes aggregate.fetch("shell_exposures"), "explicit_bash"
    assert_includes aggregate.fetch("shell_exposures"), "unrestricted"
  end
end
