require "test_helper"
require "json"
require "yaml"
require "hive/config"
require "hive/module_package/configuration"
require "hive/module_package/validator"
require "hive/modules/migration/qualification_architecture_scenario"
require "hive/refactor_patrol/fixer"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/pr_manifest"

class QualificationArchitectureScenarioTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 31, 12, 0, 0)
  Generation = Data.define(
    :name, :version, :catalog_commit, :source_commit,
    :manifest_digest
  )

  class ReviewAgent
    attr_reader :features

    def initialize(theses)
      @theses = theses
      @features = []
    end

    def call(feature:, output_path:, **)
      @features << feature
      FileUtils.mkdir_p(File.dirname(output_path))
      File.write(
        output_path,
        JSON.generate(
          "theses" =>
            @theses.respond_to?(:call) ?
              @theses.call(feature) : @theses
        )
      )
      {}
    end
  end

  class NoDiffFixer
    attr_reader :attempts

    def initialize
      @attempts = []
    end

    def attempt(**options)
      @attempts << options
      Hive::RefactorPatrol::Fixer::Result.new(
        outcome: "no_diff",
        terminal: true,
        analysis_sha: options.fetch(:analysis_sha),
        details: { "reason" => "qualification_no_diff" }
      )
    end
  end

  def test_clean_scenario_closes_from_discovery_and_records_matching_shadow_evidence
    with_scenario do |scenario|
      reviewer = ReviewAgent.new([])
      fixer = NoDiffFixer.new

      result = build_subject(
        scenario,
        reviewer: reviewer,
        fixer: fixer
      ).call

      assert_equal [ "discovery" ],
                   result.runs.map { |run| run.fetch("phase") }
      assert_equal [ "closed" ],
                   result.runs.map { |run| run.fetch("status") }
      assert result.aggregate.fetch("complete")
      assert_equal "complete", result.aggregate.fetch("state")
      assert_equal "no_theses", result.aggregate.fetch("zero_reason")
      assert_empty result.aggregate.dig("dispositions", "accepted")
      assert_empty result.aggregate.fetch("actions")
      assert_empty fixer.attempts
      assert_equal 1, reviewer.features.length
      assert_equal "complete",
                   result.occurrence.fetch("outcome_class")
      assert result.occurrence.dig("outcome", "complete")
      assert_equal "scheduled-discovery",
                   result.event.dig("payload", "target_hook")
      assert_matching_comparison(result.comparison)
      assert_durable_result(scenario, result)
    end
  end

  def test_positive_scenario_runs_real_action_lifecycle_before_shadow_comparison
    with_scenario do |scenario|
      reviewer = ReviewAgent.new([ raw_thesis ])
      fixer = NoDiffFixer.new

      result = build_subject(
        scenario,
        reviewer: reviewer,
        fixer: fixer
      ).call

      assert_equal %w[discovery action],
                   result.runs.map { |run| run.fetch("phase") }
      assert_equal %w[classified closed],
                   result.runs.map { |run| run.fetch("status") }
      assert result.aggregate.fetch("complete")
      assert_equal 1,
                   result.aggregate.dig("dispositions", "accepted").length
      action = result.aggregate.fetch("actions").fetch(0)
      assert action.fetch("terminal")
      assert_equal "no_diff", action.fetch("outcome")
      assert_equal 1, fixer.attempts.length
      assert_equal result.aggregate.fetch("analysis_sha"),
                   fixer.attempts.fetch(0).fetch(:analysis_sha)
      assert_equal "actions", result.event.dig("payload", "target_hook")
      assert_matching_comparison(result.comparison)
      assert_durable_result(scenario, result)
    end
  end

  private

  def build_subject(scenario, reviewer:, fixer:)
    Hive::Modules::Migration::QualificationArchitectureScenario.new(
      project: scenario.fetch(:project),
      manifest: scenario.fetch(:manifest),
      configuration: module_configuration,
      review_agent_runner: reviewer,
      fixer: fixer,
      repository_identity_resolver: lambda do |_entry, _cfg|
        {
          "repository" => "acme/demo",
          "host" => "github.com"
        }
      end,
      clock: -> { NOW }
    )
  end

  def with_scenario
    with_tmp_global_config do
      with_tmp_git_repo do |repo|
        base_sha =
          run!("git", "-C", repo, "rev-parse", "HEAD").strip
        write_checkout_fixture(repo)
        run!("git", "-C", repo, "add", "lib", "test")
        run!(
          "git", "-C", repo, "commit", "-m",
          "add checkout boundary", "--quiet"
        )
        merge_sha =
          run!("git", "-C", repo, "rev-parse", "HEAD").strip
        state = File.join(repo, ".hive-state")
        FileUtils.mkdir_p(state)
        File.write(
          File.join(state, "config.yml"),
          project_config.to_yaml
        )
        project = {
          "name" => "demo",
          "project_id" => "project-demo",
          "path" => repo,
          "hive_state_path" => state,
          "repository_identity" => "github.com/acme/demo"
        }
        manifest = Hive::RefactorPatrol::PrManifest.build(
          source: {
            "url" =>
              "https://github.com/acme/demo/pull/7",
            "number" => 7,
            "repository" => "acme/demo",
            "registration" => "demo",
            "base_branch" => "master",
            "base_sha" => base_sha,
            "merge_sha" => merge_sha,
            "merged_at" => NOW.iso8601
          },
          files: [
            {
              "path" => "lib/checkout.rb",
              "status" => "added"
            }
          ]
        )

        yield(
          project: project,
          manifest: manifest,
          state: state
        )
      end
    end
  end

  def write_checkout_fixture(repo)
    source = <<~RUBY
      module Checkout
        class Processor
          def initialize(gateway)
            @gateway = gateway
          end

          def ready?
            true
          end

          # Payment and validation currently share one boundary.
          def charge_and_validate
            return false unless ready?

            @gateway.charge
          end
        end
      end
    RUBY
    test_source = <<~RUBY
      require "minitest/autorun"
      require_relative "../lib/checkout"

      class CheckoutTest < Minitest::Test
        def test_processor_is_ready
          assert Checkout::Processor.allocate
        end
      end
    RUBY
    FileUtils.mkdir_p(File.join(repo, "lib"))
    FileUtils.mkdir_p(File.join(repo, "test"))
    File.write(File.join(repo, "lib", "checkout.rb"), source)
    File.write(
      File.join(repo, "test", "checkout_test.rb"),
      test_source
    )
  end

  def project_config
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      {
        "project_name" => "demo",
        "default_branch" => "master",
        "daemon" => { "enabled" => true },
        "execute" => {
          "agent" => "codex",
          "model" => "gpt-5.6-sol",
          "effort" => "high"
        },
        "refactor_patrol" => {
          "enabled" => true,
          "min_leverage_score" => 0.0,
          "auto_fix" => {
            "enabled" => true,
            "agent" => "codex",
            "model" => "gpt-5.6-sol",
            "effort" => "high"
          },
          "issue_filing" => { "enabled" => false },
          "commands" => { "test" => "true" }
        }
      }
    )
  end

  def module_configuration
    package = File.expand_path(
      "../../../../modules/architecture-patrol",
      __dir__
    )
    validation =
      Hive::ModulePackage::Validator.validate!(
        package,
        catalog_commit: "f" * 40
      )
    descriptor = validation.descriptor
    generation = Generation.new(
      name: descriptor.name,
      version: descriptor.version,
      catalog_commit: "f" * 40,
      source_commit: descriptor.source.fetch("revision"),
      manifest_digest: validation.manifest.digest
    )
    Hive::ModulePackage::Configuration.build(
      descriptor,
      generation: generation,
      settings: {
        "shadow_mode" => true,
        "dry_run" => false
      },
      hooks: descriptor.hooks.to_h do |hook|
        [ hook.fetch("id"), true ]
      end,
      grants: descriptor.permissions
    )
  end

  def raw_thesis
    {
      "feature" => "Checkout",
      "problem" =>
        "Checkout mixes validation and payment orchestration",
      "cost" =>
        "Frequent changes touch the same file and its callers",
      "evidence" => [
        {
          "file" => "lib/checkout.rb",
          "line" => 12,
          "snippet" => "def charge_and_validate",
          "claim" =>
            "validation and payment orchestration share one method"
        }
      ],
      "proposed_refactor" =>
        "Extract payment orchestration behind a checkout boundary",
      "expected_leverage" => {
        "drivers" => [
          {
            "signal" => "churn",
            "relief" => 0.5,
            "mechanism" =>
              "isolate payment edits from validation code"
          }
        ]
      },
      "confidence" => "medium",
      "risk" => {
        "caps" => { "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => []
      },
      "required_validation" => {
        "commands" => [ "test" ],
        "characterization_first" => false,
        "notes" => "Run checkout tests"
      },
      "follow_up_approval_state" => "pending"
    }
  end

  def assert_matching_comparison(comparison)
    assert comparison.fetch("comparable")
    assert_empty comparison.fetch("unexplained_differences")
    assert_empty comparison.fetch("duplicate_effects")
    assert_empty comparison.fetch("module_effects")
    refute_empty comparison.fetch("legacy_effects")
  end

  def assert_durable_result(scenario, result)
    fresh_store = Hive::RefactorPatrol::JobStore.new(
      scenario.fetch(:project).fetch("path"),
      hive_state_path: scenario.fetch(:state),
      project: scenario.fetch(:project)
    )
    assert_equal result.aggregate,
                 fresh_store.read_job(result.job_id)
    assert_equal result.occurrence.fetch("occurrence_id"),
                 result.aggregate.fetch("occurrence_id")
    assert_equal NOW.iso8601(6),
                 result.event.fetch("recorded_at")
    assert_equal result.occurrence.fetch("recorded_at"),
                 result.event.fetch("recorded_at")
    assert_equal result.occurrence.fetch("occurred_at"),
                 result.event.fetch("occurred_at")
    assert_nil fresh_store.occurrence_for_job(result.job_id),
               "fully published terminal occurrences retire from the live journal"
  end
end
