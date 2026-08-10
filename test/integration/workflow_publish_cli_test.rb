require "test_helper"
require "hive/commands/workflow/publish"

class WorkflowPublishCliTest < Minitest::Test
  include HiveTestHelper

  def test_dry_run_builds_full_package_without_remote_or_durable_publish_state
    with_authored_project do |project, state_home|
      stdout = StringIO.new
      payload = Hive::Commands::Workflow::Publish.new(
        "demo", project_root: project, version: "1.0.0", json: true,
        dry_run: true, stdout: stdout,
        clock: -> { Time.iso8601("2026-07-21T12:00:00Z") }
      ).call!

      assert_equal "validated", payload.fetch("state")
      assert_equal "not_checked", payload.fetch("freshness")
      assert_match(/\A[0-9a-f]{64}\z/, payload.fetch("package_digest"))
      assert_match(/\A[0-9a-f]{64}\z/, payload.fetch("release_digest"))
      assert_equal payload, JSON.parse(stdout.string)
      refute File.exist?(File.join(state_home, "workflow-publish"))
    end
  end

  def test_digest_mismatch_fails_before_registry_or_receipt_setup
    with_authored_project do |project, state_home|
      error = assert_raises(Hive::Commands::Workflow::Publish::ValidationError) do
        Hive::Commands::Workflow::Publish.new(
          "demo", project_root: project, version: "1.0.0", json: true,
          expected_release_digest: "0" * 64, stdout: StringIO.new
        ).call!
      end
      assert_match(/digest changed/, error.message)
      refute File.exist?(File.join(state_home, "workflow-publish"))
    end
  end

  private

  def with_authored_project
    with_tmp_dir do |project|
      state_home = File.join(project, "state-home")
      with_env("XDG_STATE_HOME" => state_home, "HIVE_HOME" => nil) do
        workflows = File.join(project, ".hive-state", "workflows")
        authored = File.join(workflows, "demo")
        FileUtils.mkdir_p(authored)
        File.write(File.join(workflows, "demo.yml"), <<~YAML)
          id: demo
          stages:
            - name: inbox
              kind: terminal
              state_file: idea.md
            - name: work
              kind: agent
              state_file: work.md
              advance_verb: work
              instruction: ./demo/work.md
              mapping_role: development
              mapping_contract: demo-work-v1
              permissions: read-only
            - name: done
              kind: terminal
              state_file: done.md
        YAML
        File.write(File.join(authored, "work.md"), "Read the task and produce the requested result.\n")
        File.write(File.join(authored, "README.md"), <<~MARKDOWN)
          # Demo

          ## Behavior
          Produces a concise result from the task.
          ## Prerequisites
          Requires readable task and repository files.
          ## Inputs
          Reads the authored task brief.
          ## Outputs
          Produces a concise work result.
          ## Permissions and Risks
          Uses read-only access and changes no external systems.
          ## Recovery
          Retry with the same immutable inputs after a local failure.
        MARKDOWN
        File.write(File.join(authored, "honeycomb.yml"), <<~YAML)
          description: Produce a concise result from the task
          author:
            name: Test Author
            url: https://example.test/authors/test
          license: MIT
          hive_min_version: #{Hive::VERSION}
          source:
            url: https://example.test/source/demo
            revision: #{"a" * 40}
          assets: []
        YAML
        yield project, state_home
      end
    end
  end
end
