require "json_schemer"
require "hive/patrol/feature"

# Canonical "checkout" thesis fixtures shared by the reviewer and
# thesis-normalizer tests so the example agent payload has one home.
module RefactorPatrolThesisFixtures
  def materialize_thesis_evidence(project_root, raw_theses:, feature:)
    documents = Array(raw_theses).select { |item| item.is_a?(Hash) }
    evidence = documents.flat_map { |item| Array(item["evidence"]) }
                        .select { |item| item.is_a?(Hash) }
    paths = evidence.flat_map do |item|
      [ item["file"], *Array(item["files"] || item["paths"] || item["path"]) ]
    end
    paths.concat(Array(feature.owned_files) + Array(feature.entrypoints) + Array(feature.context_files) + Array(feature.tests))
    snippets = evidence.filter_map { |item| item["snippet"].to_s unless item["snippet"].to_s.empty? }
    max_line = evidence.filter_map { |item| Integer(item["line"], exception: false) }.max.to_i
    content = ([ "fixture evidence line" ] * [ max_line, 1 ].max + snippets).join("\n") + "\n"

    paths.compact.map(&:to_s).uniq.each do |path|
      relative = Pathname.new(path)
      next if relative.absolute? || relative.cleanpath.to_s != path || path == "."

      full = File.join(project_root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content) unless File.exist?(full)
    end
  end

  def thesis_schemer
    @thesis_schemer ||= JSONSchemer.schema(Pathname.new(Hive::Schemas.schema_path("hive-refactor-patrol-thesis")))
  end

  def feature(tests: [])
    Hive::Patrol::Feature.new(
      id: "checkout",
      kind: "command",
      entrypoints: [ "lib/checkout.rb" ],
      owned_files: [ "lib/checkout.rb" ],
      context_files: [ "README.md" ],
      tests: tests
    )
  end

  # The measured leverage for one feature, as ThesisNormalizer consumes it.
  # Reviewer tests key it by feature id via +leverage_by_feature+.
  def feature_leverage
    {
      "scope" => "feature",
      "score" => 0.8,
      "breakdown" => { "churn" => 0.5, "fan_in" => 0.3 },
      "signals" => { "churn" => 10, "fan_in" => 4 },
      "normalized" => { "churn" => 1.0, "fan_in" => 0.2 }
    }
  end

  def leverage_by_feature
    { "checkout" => feature_leverage }
  end

  def valid_raw_thesis
    {
      "feature" => "Checkout",
      "problem" => "Checkout mixes validation and payment orchestration",
      "cost" => "Frequent changes touch the same file and its callers",
      "evidence" => [
        {
          "file" => "lib/checkout.rb",
          "line" => 12,
          "snippet" => "def charge_and_validate",
          "claim" => "validation and payment orchestration share one method"
        }
      ],
      "proposed_refactor" => "Extract payment orchestration behind a checkout boundary",
      "expected_leverage" => {
        "drivers" => [
          {
            "signal" => "churn",
            "relief" => 0.5,
            "mechanism" => "isolate payment edits from validation code"
          },
          {
            "signal" => "fan_in",
            "relief" => 0.5,
            "mechanism" => "give callers one stable checkout boundary"
          }
        ]
      },
      "confidence" => "medium",
      "risk" => {
        "caps" => { "est_files" => 3, "est_diff_lines" => 120, "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => []
      },
      "required_validation" => { "commands" => [ "test" ], "characterization_first" => false, "notes" => "Run checkout tests" },
      "follow_up_approval_state" => "pending"
    }
  end
end
