require "test_helper"

class AgentCliRuntimeReleaseContractTest < Minitest::Test
  WORKFLOW =
    File.expand_path("../../.github/workflows/agent-cli-runtime-release.yml", __dir__)
  ROOT_RELEASE =
    File.expand_path("../../.github/workflows/release.yml", __dir__)

  def test_component_and_hive_release_tags_are_disjoint
    component = File.read(WORKFLOW)
    hive = File.read(ROOT_RELEASE)

    assert_includes component, '"components/agent-cli-runtime/v*.*.*"'
    refute_includes component, '- "v*.*.*"'
    assert_includes hive, '- "v*.*.*"'
    refute_includes hive, "components/agent-cli-runtime/"
  end

  def test_only_publish_job_has_oidc_and_environment_authority
    workflow = YAML.safe_load_file(WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")

    jobs.each do |name, job|
      permissions = job.fetch("permissions", {})
      if name == "publish"
        assert_equal "write", permissions.fetch("id-token")
        assert_equal "agent-cli-runtime-release", job.fetch("environment")
      else
        refute_equal "write", permissions["id-token"], name
        refute job.key?("environment"), name
      end
    end
  end

  def test_every_job_is_bounded_and_candidate_survives_approval_delay
    workflow = YAML.safe_load_file(WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")

    assert jobs.values.all? { |job| job.fetch("timeout-minutes") == 15 }
    candidate = jobs.fetch("candidate")
    upload = candidate.fetch("steps").find do |step|
      step.fetch("uses", "").start_with?("actions/upload-artifact@")
    end

    assert_equal 30, upload.fetch("with").fetch("retention-days")
  end

  def test_publish_uses_pinned_oidc_action_and_does_not_rebuild
    content = File.read(WORKFLOW)

    assert_includes content,
                    "rubygems/configure-rubygems-credentials@" \
                    "dc5a8d8553e6ee01fc26761a49e99e733d17954a"
    publish = content.split(/^  publish:\n/, 2).fetch(1)
    assert_includes publish, "gem push \"$gem_file\""
    refute_includes publish, "gem build"
    refute_includes publish, "build-candidate"
  end

  def test_every_action_is_pinned_to_a_commit
    uses = File.readlines(WORKFLOW).filter_map do |line|
      line[/uses:\s+([^\s#]+)/, 1]
    end

    refute_empty uses
    uses.each do |action|
      assert_match(/@[0-9a-f]{40}\z/, action, action)
    end
  end
end
