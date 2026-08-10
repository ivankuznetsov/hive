require "test_helper"
require "hive/agent"
require "hive/agent_profiles"
require "hive/model_routing"

class ModelRoutingSurfaceTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, :state_file, :log_dir, :stage_name, keyword_init: true)
  INHERITANCE_ONLY_KEYS = %w[execute review patrol].freeze
  ROUTE_LAUNCH_SOURCES = {
    "brainstorm" => %w[
      lib/hive/stages/brainstorm.rb
      lib/hive/stages/brainstorm_tmux.rb
    ],
    "plan" => %w[lib/hive/stages/plan.rb],
    "execute_implementation" => %w[lib/hive/implementation_identity/resolver.rb],
    "rebase" => %w[lib/hive/rebase.rb],
    "diagnose" => %w[lib/hive/diagnosis_agent.rb],
    "babysitter" => %w[lib/hive/babysitter/pr_fixer.rb],
    "review_ci" => %w[lib/hive/implementation_identity/resolver.rb],
    "review_reviewers" => %w[
      lib/hive/reviewers/agent.rb
      lib/hive/reviewers/codex_review.rb
      lib/hive/stages/review.rb
    ],
    "review_triage" => %w[lib/hive/stages/review/triage.rb],
    "review_fix" => %w[lib/hive/implementation_identity/resolver.rb],
    "review_browser" => %w[lib/hive/stages/review/browser_test.rb],
    "patrol_review" => %w[
      lib/hive/patrol/reviewer.rb
      lib/hive/refactor_patrol/agent_identity.rb
    ],
    "patrol_fix" => %w[
      lib/hive/patrol/fixer.rb
      lib/hive/refactor_patrol/agent_identity.rb
    ],
    "open_pr" => %w[lib/hive/implementation_identity/resolver.rb],
    "artifacts" => %w[lib/hive/stages/artifacts.rb],
    "finalize" => %w[lib/hive/stages/finalize.rb]
  }.freeze

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

  def test_every_leaf_route_has_an_explicit_launch_surface
    parent_keys = Hive::ModelRouting.entries.filter_map(&:parent).uniq
    assert_equal INHERITANCE_ONLY_KEYS.sort, parent_keys.sort

    leaf_keys = Hive::ModelRouting.keys - parent_keys
    assert_equal leaf_keys.sort, ROUTE_LAUNCH_SOURCES.keys.sort

    root = File.expand_path("../..", __dir__)
    ROUTE_LAUNCH_SOURCES.each do |key, relative_paths|
      relative_paths.each do |relative_path|
        source = File.read(File.join(root, relative_path))
        assert_includes source, %("#{key}"), "#{relative_path} does not declare #{key}"
      end
    end
  end

  def test_registry_vocabulary_is_published_in_operator_docs_and_templates
    project_template = File.read(
      File.expand_path("../../templates/project_config.yml.erb", __dir__)
    )
    architecture = File.read(
      File.expand_path("../../docs/architecture.md", __dir__)
    )

    Hive::ModelRouting.entries.each do |entry|
      assert_includes project_template, entry.key, "template omits #{entry.key}"
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
