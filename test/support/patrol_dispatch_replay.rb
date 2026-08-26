require "date"
require "digest"
require "json"
require "time"
require "hive/errors"
require "hive/secret_patterns"

module HiveTestSupport
  class PatrolDispatchReplay
    SCHEMA = "hive-patrol-dispatch-incident-replay".freeze
    SCHEMA_VERSION = 1
    MAX_BYTES = 256 * 1024
    FORBIDDEN_KEYS = %w[
      credential credentials host_path prompt prompts provider_output
      raw_provider_output secret_bytes
    ].freeze

    class InvalidFixture < StandardError; end

    Result = Data.define(:attempts, :metrics, :failure_counts, :digest)

    attr_reader :document

    def initialize(path)
      bytes = File.binread(path)
      raise InvalidFixture, "fixture exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES

      utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
      raise InvalidFixture, "fixture must be valid UTF-8" unless utf8.valid_encoding?
      raise InvalidFixture, "fixture is secret-bearing" if Hive::SecretPatterns.match?(utf8)
      if %r{(?:\A|["'\s])/(?:home|Users)/|[A-Za-z]:\\\\}.match?(utf8)
        raise InvalidFixture, "fixture contains a host-specific path"
      end

      @document = JSON.parse(utf8)
      validate!
    rescue JSON::ParserError => e
      raise InvalidFixture, "fixture contains malformed JSON: #{e.message}"
    end

    def replay
      attempts = build_attempts.freeze
      metrics = metrics_for(attempts).freeze
      expected = document.fetch("expected_metrics")
      unless metrics == expected
        raise InvalidFixture, "replayed metrics differ from expected metrics"
      end

      failure_counts = attempts.filter_map { |attempt| attempt["failure_code"] }
                               .tally.sort.to_h.freeze
      expected_failures = failure_cohorts.to_h do |cohort|
        [ cohort.fetch("expected_normalized_code"), cohort.fetch("count") ]
      end.sort.to_h
      unless failure_counts == expected_failures
        raise InvalidFixture, "replayed failure counts differ from expected cohorts"
      end

      canonical = canonicalize("attempts" => attempts, "metrics" => metrics)
      Result.new(
        attempts: attempts,
        metrics: metrics,
        failure_counts: failure_counts,
        digest: Digest::SHA256.hexdigest(JSON.generate(canonical))
      )
    end

    def failure_cohorts = document.fetch("failure_cohorts")
    def operational = document.fetch("operational")
    def non_patrol_demand = document.fetch("non_patrol_demand")

    def accounting_results
      document.fetch("accounting_cases").to_h do |entry|
        charged = entry.fetch("accepted") &&
                  !(entry.fetch("state") == "lost" && entry["started_at"].nil?) &&
                  entry["exit_status"] != Hive::ExitCodes::TEMPFAIL
        unless charged == entry.fetch("expected_charged")
          raise InvalidFixture, "accounting case #{entry.fetch('name')} differs from its expected charge"
        end
        [ entry.fetch("name"), charged ]
      end
    end

    def current_pool_at(cap:)
      remaining = [ Integer(cap) - document.dig("expected_metrics", "charged_attempts"), 0 ].max
      candidates = document.fetch("pending_candidates").sort_by do |candidate|
        candidate.fetch("current_priority")
      end.each_with_index.map do |candidate, index|
        candidate.merge("admitted" => index < remaining)
      end
      {
        "cap" => cap,
        "remaining" => remaining,
        "candidates" => candidates,
        "starved_classes" => candidates.reject { |candidate| candidate.fetch("admitted") }
                                       .map { |candidate| candidate.fetch("class") }
      }
    end

    def future_containment_violations(cap:)
      starved = current_pool_at(cap: cap).fetch("starved_classes")
      violations = []
      if starved.include?("non_patrol_first_attempt")
        violations << "non-Patrol work is starved by the current undifferentiated pool"
      end
      if starved.any? { |entry| entry.start_with?("patrol_progress") }
        violations << "healthy Patrol progress is starved by the current undifferentiated pool"
      end
      violations
    end

    private

    def validate!
      unless document.is_a?(Hash) && document["schema"] == SCHEMA &&
             document["schema_version"] == SCHEMA_VERSION
        raise InvalidFixture, "fixture schema identity must be #{SCHEMA} v#{SCHEMA_VERSION}"
      end
      %w[
        incident sanitization expected_metrics identity_multiplicity stage_outcomes
        failure_cohorts accounting_cases pending_candidates operational non_patrol_demand
      ].each do |key|
        raise InvalidFixture, "fixture missing #{key}" unless document.key?(key)
      end
      reject_forbidden_keys!(document)
      validate_aggregate_contract!
      validate_envelopes!
      true
    end

    def validate_aggregate_contract!
      expected = document.fetch("expected_metrics")
      raise InvalidFixture, "accepted and charged totals differ" unless
        expected.fetch("accepted_attempts") == 600 && expected.fetch("charged_attempts") == 600
      raise InvalidFixture, "workflow totals differ" unless
        expected.fetch("patrol_fix_attempts") + expected.fetch("coding_attempts") == 600
      raise InvalidFixture, "outcome totals differ" unless
        expected.fetch("failed_attempts") + expected.fetch("succeeded_attempts") == 600

      identity = document.fetch("identity_multiplicity")
      identities = identity.sum { |entry| entry.fetch("identities") }
      attempts = identity.sum { |entry| entry.fetch("attempts") * entry.fetch("identities") }
      repeated = identity.sum { |entry| entry.fetch("attempts") > 1 ? entry.fetch("identities") : 0 }
      repeat_launches = identity.sum do |entry|
        (entry.fetch("attempts") - 1) * entry.fetch("identities")
      end
      unless identities == expected.fetch("unique_generation_stage_identities") &&
             attempts == 600 && repeated == expected.fetch("repeated_generation_stage_identities") &&
             repeat_launches == expected.fetch("repeat_launches") &&
             identity.map { |entry| entry.fetch("attempts") }.max == expected.fetch("max_attempts_for_identity")
        raise InvalidFixture, "identity multiplicity differs from expected metrics"
      end

      stage_attempts = document.fetch("stage_outcomes").sum do |entry|
        entry.fetch("failed") + entry.fetch("succeeded")
      end
      failures = failure_cohorts.sum { |cohort| cohort.fetch("count") }
      unless stage_attempts == 600 && failures == expected.fetch("failed_attempts")
        raise InvalidFixture, "stage or failure cohort totals differ"
      end
      demand = non_patrol_demand
      unless demand["available"] == false && !demand.fetch("uncertainty").to_s.empty?
        raise InvalidFixture, "unavailable non-Patrol demand must retain its uncertainty"
      end
    end

    def validate_envelopes!
      failure_cohorts.each do |cohort|
        envelope = cohort.fetch("terminal_envelope")
        unless envelope.is_a?(Hash) && !envelope.empty? &&
               !envelope.key?("failure_code") && !envelope.key?("expected_normalized_code")
          raise InvalidFixture, "terminal envelope must remain pre-normalization"
        end
        code = cohort.fetch("expected_normalized_code")
        unless /\A[a-z][a-z0-9_]*\z/.match?(code)
          raise InvalidFixture, "invalid expected normalized code"
        end
      end
    end

    def reject_forbidden_keys!(value)
      case value
      when Hash
        forbidden = value.keys & FORBIDDEN_KEYS
        raise InvalidFixture, "fixture contains forbidden evidence key #{forbidden.first}" unless forbidden.empty?
        value.each_value { |child| reject_forbidden_keys!(child) }
      when Array
        value.each { |child| reject_forbidden_keys!(child) }
      end
    end

    def build_attempts
      stage_remaining = document.fetch("stage_outcomes").to_h do |entry|
        [ entry.fetch("stage"), entry.fetch("failed") + entry.fetch("succeeded") ]
      end
      multiplicities = document.fetch("identity_multiplicity").flat_map do |entry|
        [ entry.fetch("attempts") ] * entry.fetch("identities")
      end.sort.reverse
      groups = multiplicities.each_with_index.map do |count, index|
        stage = stage_remaining.select { |_, remaining| remaining >= count }
                               .max_by { |name, remaining| [ remaining, name ] }&.first
        raise InvalidFixture, "identity multiplicity cannot fit stage totals" unless stage

        stage_remaining[stage] -= count
        { "identity" => format("generation-%03d:%s", index + 1, stage), "stage" => stage, "count" => count }
      end
      raise InvalidFixture, "identity allocation left stage attempts" unless stage_remaining.values.all?(&:zero?)

      failed_remaining = document.fetch("stage_outcomes").to_h do |entry|
        [ entry.fetch("stage"), entry.fetch("failed") ]
      end
      failure_codes = failure_cohorts.flat_map do |cohort|
        [ cohort.fetch("expected_normalized_code") ] * cohort.fetch("count")
      end
      sequence = 0
      groups.flat_map do |group|
        group.fetch("count").times.map do |launch_index|
          sequence += 1
          stage = group.fetch("stage")
          failed = failed_remaining.fetch(stage).positive?
          failed_remaining[stage] -= 1 if failed
          {
            "attempt_id" => format("attempt-%03d", sequence),
            "generation_stage_identity" => group.fetch("identity"),
            "launch_index" => launch_index + 1,
            "repeat_launch" => launch_index.positive?,
            "workflow" => stage == "2-brainstorm" ? "coding" : "patrol_fix",
            "stage" => stage,
            "outcome" => failed ? "failed" : "succeeded",
            "failure_code" => failed ? failure_codes.shift : nil,
            "charged" => true,
            "accepted_at" => (Time.utc(2026, 8, 26) + sequence).iso8601
          }
        end
      end
    end

    def metrics_for(attempts)
      identities = attempts.group_by { |attempt| attempt.fetch("generation_stage_identity") }
      {
        "accepted_attempts" => attempts.length,
        "charged_attempts" => attempts.count { |attempt| attempt.fetch("charged") },
        "patrol_fix_attempts" => attempts.count { |attempt| attempt.fetch("workflow") == "patrol_fix" },
        "coding_attempts" => attempts.count { |attempt| attempt.fetch("workflow") == "coding" },
        "failed_attempts" => attempts.count { |attempt| attempt.fetch("outcome") == "failed" },
        "succeeded_attempts" => attempts.count { |attempt| attempt.fetch("outcome") == "succeeded" },
        "repeat_launches" => attempts.count { |attempt| attempt.fetch("repeat_launch") },
        "unique_generation_stage_identities" => identities.length,
        "repeated_generation_stage_identities" => identities.count { |_, entries| entries.length > 1 },
        "max_attempts_for_identity" => identities.values.map(&:length).max
      }
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [ key, canonicalize(value.fetch(key)) ] }
      when Array
        value.map { |entry| canonicalize(entry) }
      else
        value
      end
    end
  end
end
