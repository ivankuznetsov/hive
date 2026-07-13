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

    def metadata(judge_name, efforts: {})
      name = judge_name.to_s
      effort = efforts.transform_keys(&:to_s).fetch(name, EXPLICIT_REASONING_EFFORTS[name])
      effort = nil if effort.to_s == "unspecified"
      {
        "reasoning_effort" => effort || "unspecified",
        "reasoning_effort_explicit" => !effort.nil?
      }
    end

    def annotate_document!(document, efforts: {})
      Array(document["cells"]).each do |cell|
        (cell["judges"] || {}).each do |judge_name, record|
          next unless record.is_a?(Hash)

          record.merge!(metadata(judge_name, efforts: efforts))
        end
      end
      document
    end
  end
end
