require "test_helper"
require "hive/agent"
require "hive/agent_profiles"
require "hive/model_routing"

class ModelRoutingSurfaceTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, :state_file, :log_dir, :stage_name, keyword_init: true)

  def test_every_registered_identity_reaches_the_profile_argv_seam
    with_tmp_dir do |dir|
      profiles = {
        codex: Hive::AgentProfiles.lookup(:codex),
        claude: Hive::AgentProfiles.lookup(:claude)
      }

      Hive::ModelRouting.entries.each_with_index do |entry, index|
        profile = profiles.fetch(index.even? ? :codex : :claude)
        models = {
          entry.key => {
            "model" => "surface-model",
            "effort" => profile.name == :codex ? "xhigh" : "high"
          }
        }
        resolution = Hive::ModelRouting.resolve(
          models: models, stage: entry.key, provider: profile.name
        )
        cmd = agent_cmd(dir, entry.key, profile, resolution)

        if profile.name == :codex
          assert_equal profile.bin, cmd.fetch(0), entry.key
          assert_equal "--model", cmd.fetch(1), entry.key
          assert_equal "surface-model", cmd.fetch(2), entry.key
          assert_equal "-c", cmd.fetch(3), entry.key
          assert_equal "model_reasoning_effort=xhigh", cmd.fetch(4), entry.key
          assert_equal "exec", cmd.fetch(5), entry.key
        else
          assert_operator cmd.index("--model"), :<, cmd.index("--effort"), entry.key
          assert_equal "surface-model", cmd.fetch(cmd.index("--model") + 1), entry.key
          assert_equal "high", cmd.fetch(cmd.index("--effort") + 1), entry.key
        end
      end
    end
  end

  def test_recognized_stage_fallback_and_unscoped_legacy_argv
    with_tmp_dir do |dir|
      profile = Hive::AgentProfiles.lookup(:codex)
      fallback = Hive::ModelRouting.resolve(
        models: { "review" => { "effort" => "xhigh" } },
        stage: "review_fix",
        current: { model: "current-model", effort: "low" },
        provider: :codex
      )
      routed = agent_cmd(dir, "review_fix", profile, fallback)
      assert_equal [
        profile.bin,
        "--model", "current-model",
        "-c", "model_reasoning_effort=xhigh",
        "exec"
      ], routed.first(6)

      legacy = Hive::Agent.new(
        task: make_task(dir, "legacy"),
        prompt: "legacy",
        max_budget_usd: nil,
        timeout_sec: 5,
        profile: profile,
        identity_arguments: [
          "--model", "legacy-model",
          "-c", "model_reasoning_effort=medium"
        ]
      ).send(:build_cmd)
      assert_equal [
        profile.bin,
        "exec",
        "--dangerously-bypass-approvals-and-sandbox",
        "--model", "legacy-model",
        "-c", "model_reasoning_effort=medium",
        "--json",
        "-"
      ], legacy
    end
  end

  def test_registry_vocabulary_is_published_in_operator_docs_and_templates
    project_template = File.read(
      File.expand_path("../../templates/project_config.yml.erb", __dir__)
    )
    global_template = File.read(
      File.expand_path("../../templates/hive_config.yml.erb", __dir__)
    )
    architecture = File.read(
      File.expand_path("../../docs/architecture.md", __dir__)
    )

    Hive::ModelRouting.entries.each do |entry|
      template = entry.owner == Hive::ModelRouting::GLOBAL_DIGEST_OWNER ?
        global_template : project_template
      assert_includes template, entry.key, "template omits #{entry.key}"
      assert_includes architecture, entry.key, "architecture docs omit #{entry.key}"
    end
  end

  private

  def agent_cmd(dir, stage, profile, resolution)
    Hive::Agent.new(
      task: make_task(dir, stage),
      prompt: "surface",
      max_budget_usd: nil,
      timeout_sec: 5,
      profile: profile,
      routing_arguments: profile.routing_arguments(resolution)
    ).send(:build_cmd)
  end

  def make_task(dir, stage)
    folder = File.join(dir, stage)
    FileUtils.mkdir_p(folder)
    Task.new(
      folder: folder,
      state_file: File.join(folder, "state.md"),
      log_dir: File.join(folder, "logs"),
      stage_name: stage
    )
  end
end
