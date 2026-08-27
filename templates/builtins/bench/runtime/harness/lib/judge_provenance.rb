# frozen_string_literal: true

module HiveBench
  # Adds invocation provenance to the per-judge records in results.json.
  # A missing effort flag is recorded as "unspecified", never guessed from a
  # provider/model default that may change independently of the benchmark.
  module JudgeProvenance
    EXPLICIT_REASONING_EFFORTS = {
      "gpt-5.6-sol" => "xhigh"
    }.freeze

    module_function

    def metadata(judge_name, efforts: {}, routes: {})
      name = judge_name.to_s
      effort = efforts.transform_keys(&:to_s).fetch(name, EXPLICIT_REASONING_EFFORTS[name])
      effort = nil if effort.to_s == "unspecified"
      metadata = {
        "reasoning_effort" => effort || "unspecified",
        "reasoning_effort_explicit" => !effort.nil?
      }
      route = routes.transform_keys(&:to_s)[name]
      if route
        route = route.transform_keys(&:to_s)
        metadata["judge_provider"] = route.fetch("provider").to_s
        metadata["judge_provider_model"] = route.fetch("provider_model").to_s
      end
      metadata
    end

    def annotate_document!(document, efforts: {}, routes: {})
      Array(document["cells"]).each do |cell|
        (cell["judges"] || {}).each do |judge_name, record|
          next unless record.is_a?(Hash)

          record.merge!(metadata(judge_name, efforts: efforts, routes: routes))
        end
      end
      document
    end
  end
end
