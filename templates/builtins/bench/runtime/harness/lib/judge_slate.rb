# frozen_string_literal: true

require "json"
require "lib/campaign_contract"

module HiveBench
  # Owns the configured judge-slate contract shared by the judge stage's
  # pre-deliberation admission gate and final transcript validation. Rejudge
  # failure events are keyed to the exact cell/judge so an unrelated quota
  # failure cannot excuse a structural or non-quota incomplete judge.
  module JudgeSlate
    FAILURE_PREFIX = "HIVE_BENCH_JUDGE_FAILURE ".freeze

    Validation = Data.define(
      :expected,
      :by_key,
      :judge_slate,
      :expected_efforts,
      :manual,
      :retryable,
      :incomplete_keys
    ) do
      def problems = manual + retryable
    end

    module_function

    def validate(data:, campaign:)
      exclusions = campaign.fetch("exclusions", []).map do |item|
        [ item.fetch("task").to_s, item.fetch("candidate").to_s ]
      end
      expected = campaign.fetch("tasks").flat_map do |task|
        campaign.fetch("candidates").map { |candidate| [ task.to_s, candidate.to_s ] }
      end - exclusions
      expected_lookup = expected.to_h { |key| [ key, true ] }
      cells = data.fetch("cells", [])
      by_key = cells.to_h { |cell| [ [ cell["task_id"].to_s, cell["agent_id"].to_s ], cell ] }
      judge_configs = campaign.fetch("judges").reject { |_backend, config| config.nil? || config == false }
      judge_slate = judge_configs.map do |backend, config|
        CampaignContract.judge_name(backend, config)
      end
      expected_efforts = judge_configs.to_h do |backend, config|
        [ CampaignContract.judge_name(backend, config),
          backend == "codex" ? config.fetch("reasoning_effort") : "unspecified" ]
      end
      manual = []
      retryable = []
      incomplete_keys = []

      expected.each do |task, candidate|
        cell = by_key[[ task, candidate ]]
        unless cell
          manual << "MISSING_CELL #{candidate} #{task}"
          next
        end
        if campaign["require_successful_execution"] == true &&
           !%w[generated empty_diff].include?(cell["run_status"])
          manual << "INVALID_RUN_STATUS #{candidate} #{task} #{cell["run_status"]} " \
                    "(campaign requires generated or empty_diff)"
          next
        end
        next if cell["run_status"] == "empty_diff"

        records = cell.fetch("judges", {})
        missing_judges = judge_slate - records.keys
        unless missing_judges.empty?
          retryable << "MISSING_JUDGES #{candidate} #{task} " \
                       "(missing: #{missing_judges.join(",")}; have: #{records.keys.sort.join(",")})"
          missing_judges.each { |judge| incomplete_keys << [ task, candidate, judge ] }
        end
        judge_slate.each do |judge|
          next unless records.key?(judge)

          record = records.fetch(judge)
          samples = record["sample_count"] || Array(record["scores"]).size
          samples = 1 if samples.to_i.zero? && record.key?("mean")
          if samples.to_i < campaign.fetch("seeds")
            retryable << "UNDERSAMPLED_JUDGE #{candidate} #{task} #{judge} " \
                         "(have #{samples}, need #{campaign.fetch("seeds")})"
            incomplete_keys << [ task, candidate, judge ]
          end
          effort = record.fetch("reasoning_effort", "unspecified")
          unless effort == expected_efforts.fetch(judge)
            manual << "JUDGE_EFFORT_MISMATCH #{candidate} #{task} #{judge} " \
                      "(have #{effort}, need #{expected_efforts.fetch(judge)})"
          end
        end
      end
      by_key.each_key do |task, candidate|
        next if expected_lookup.key?([ task, candidate ])

        manual << "UNEXPECTED_CELL #{candidate} #{task} (not in the pre-registered campaign matrix)"
      end

      Validation.new(
        expected: expected,
        by_key: by_key,
        judge_slate: judge_slate,
        expected_efforts: expected_efforts,
        manual: manual,
        retryable: retryable,
        incomplete_keys: incomplete_keys
      )
    end

    def failure_event(task_id:, agent_id:, judge:, limits_reached:, detail:)
      FAILURE_PREFIX + JSON.generate(
        "task_id" => task_id.to_s,
        "agent_id" => agent_id.to_s,
        "judge" => judge.to_s,
        "limits_reached" => limits_reached == true,
        "detail" => detail.to_s.scrub[0, 80]
      )
    end

    def failure_limits(text)
      text.to_s.each_line.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |line, failures|
        next unless line.start_with?(FAILURE_PREFIX)

        event = JSON.parse(line.delete_prefix(FAILURE_PREFIX))
        next unless event.is_a?(Hash)

        key = %w[task_id agent_id judge].map { |field| event.fetch(field).to_s }
        next if key.any?(&:empty?)

        failures[key] << (event["limits_reached"] == true)
      rescue JSON::ParserError, KeyError, TypeError
        # Malformed or partial diagnostics are not quota proof. Ignoring the
        # event leaves the matching incomplete judge operator-owned.
        next
      end
    end

    def quota_only?(validation, failure_limits)
      return false if validation.incomplete_keys.empty?

      validation.incomplete_keys.all? do |key|
        limits = failure_limits.fetch(key, [])
        !limits.empty? && limits.all?
      end
    end
  end
end
