require "time"
require "hive/attempts/output_reference"

module Hive
  module Attempts
    class InvalidRecord < Hive::Error; end
    class InvalidReceipt < InvalidRecord; end

    # Immutable in-memory view of the one mutable JSON record for a durable
    # task-stage attempt. Mutation is constructed by Store while holding the
    # generation lock; callers can only observe snapshots.
    class Record
      SCHEMA = "hive-attempt"
      SCHEMA_VERSION = 1
      STATES = %w[launching running terminal lost].freeze
      TERMINAL_OUTCOMES = %w[succeeded failed cancelled].freeze
      FINAL_STATES = %w[terminal lost].freeze
      IMMUTABLE_KEYS = %w[
        schema schema_version attempt_id request_id predecessor_attempt_id
        task_id project task_slug intended_stage task_generation progress_token
        provider starting_revision retry_charge compatibility created_at accepted_at
      ].freeze
      REQUIRED_KEYS = (IMMUTABLE_KEYS + %w[
        state outcome lease_version claim_deadline first_heartbeat_deadline
        heartbeat_deadline wrapper worker heartbeat_at started_at ended_at
        latest_revision checkpoint log_reference inherited_outputs current_outputs
        receipt loss diagnostics
      ]).uniq.freeze

      attr_reader :data

      def self.launching(attempt_id:, request_id:, predecessor_attempt_id:, task_id:, project:,
                         task_slug:, intended_stage:, task_generation:, progress_token:, provider:,
                         starting_revision:, retry_charge:, inherited_outputs:, now:,
                         launch_timeout_sec:, compatibility: false)
        timestamp = iso8601(now)
        new(
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "attempt_id" => attempt_id,
          "request_id" => request_id,
          "predecessor_attempt_id" => predecessor_attempt_id,
          "task_id" => task_id,
          "project" => project,
          "task_slug" => task_slug,
          "intended_stage" => intended_stage,
          "task_generation" => task_generation,
          "progress_token" => progress_token,
          "provider" => provider,
          "starting_revision" => starting_revision,
          "retry_charge" => retry_charge,
          "compatibility" => compatibility,
          "created_at" => timestamp,
          "accepted_at" => timestamp,
          "state" => "launching",
          "outcome" => nil,
          "lease_version" => 0,
          "claim_deadline" => iso8601(now + launch_timeout_sec),
          "first_heartbeat_deadline" => nil,
          "heartbeat_deadline" => nil,
          "wrapper" => nil,
          "worker" => nil,
          "heartbeat_at" => nil,
          "started_at" => nil,
          "ended_at" => nil,
          "latest_revision" => starting_revision,
          "checkpoint" => { "revision" => starting_revision, "progress_token" => progress_token },
          "log_reference" => nil,
          "inherited_outputs" => deep_copy(inherited_outputs),
          "current_outputs" => [],
          "receipt" => nil,
          "loss" => nil,
          "diagnostics" => {}
        )
      end

      def self.compatibility_running(attempt_id:, task_id:, project:, task_slug:,
                                     intended_stage:, task_generation:, progress_token:,
                                     owner:, provider:, starting_revision:, now:)
        record = launching(
          attempt_id: attempt_id,
          request_id: "legacy-backfill:#{attempt_id}",
          predecessor_attempt_id: nil,
          task_id: task_id,
          project: project,
          task_slug: task_slug,
          intended_stage: intended_stage,
          task_generation: task_generation,
          progress_token: progress_token,
          provider: provider,
          starting_revision: starting_revision,
          retry_charge: 0,
          inherited_outputs: [],
          now: now,
          launch_timeout_sec: 1,
          compatibility: true
        ).to_h
        timestamp = iso8601(now)
        new(record.merge(
          "state" => "running",
          "lease_version" => 1,
          "claim_deadline" => nil,
          "wrapper" => deep_copy(owner),
          "started_at" => timestamp,
          "diagnostics" => { "legacy_backfilled_at" => timestamp }
        ))
      end

      def self.validate_receipt!(receipt, attempt_id:, task_generation:)
        unless receipt.is_a?(Hash)
          raise InvalidReceipt, "terminal receipt must be an object"
        end
        required = %w[
          attempt_id task_generation outcome exit_status started_at ended_at
          final_checkpoint output_references log_reference
        ]
        missing = required.reject { |key| receipt.key?(key) }
        raise InvalidReceipt, "terminal receipt missing #{missing.join(', ')}" unless missing.empty?
        raise InvalidReceipt, "terminal receipt attempt mismatch" unless receipt["attempt_id"] == attempt_id
        unless receipt["task_generation"] == task_generation
          raise InvalidReceipt, "terminal receipt task generation mismatch"
        end
        unless TERMINAL_OUTCOMES.include?(receipt["outcome"])
          raise InvalidReceipt, "terminal receipt has invalid outcome"
        end
        unless receipt["exit_status"].is_a?(Integer)
          raise InvalidReceipt, "terminal receipt exit_status must be an integer"
        end
        unless receipt["final_checkpoint"].is_a?(Hash) && !receipt["final_checkpoint"].empty?
          raise InvalidReceipt, "terminal receipt final_checkpoint must be present"
        end

        started_at = parse_time(receipt["started_at"], label: "started_at", error_class: InvalidReceipt)
        ended_at = parse_time(receipt["ended_at"], label: "ended_at", error_class: InvalidReceipt)
        raise InvalidReceipt, "terminal receipt ends before it starts" if ended_at < started_at

        outputs = receipt["output_references"]
        unless outputs.is_a?(Array)
          raise InvalidReceipt, "terminal receipt output_references must be an array"
        end
        (outputs + [ receipt["log_reference"] ]).each do |reference|
          OutputReference.validate_shape!(reference)
        rescue InvalidOutputReference => e
          raise InvalidReceipt, e.message
        end
        true
      end

      def initialize(data)
        @data = self.class.deep_copy(data)
        validate!
        @data.freeze
      end

      def to_h
        self.class.deep_copy(@data)
      end

      def with(changes)
        self.class.new(to_h.merge(changes))
      end

      def state = @data.fetch("state")
      def outcome = @data["outcome"]
      def attempt_id = @data.fetch("attempt_id")
      def task_generation = @data.fetch("task_generation")
      def lease_version = @data.fetch("lease_version")
      def receipt = self.class.deep_copy(@data["receipt"])
      def wrapper = self.class.deep_copy(@data["wrapper"])
      def worker = self.class.deep_copy(@data["worker"])
      def checkpoint = self.class.deep_copy(@data["checkpoint"])
      def compatibility? = @data.fetch("compatibility")
      def live? = %w[launching running].include?(state)
      def final? = FINAL_STATES.include?(state)
      def claimed? = state == "launching" && !@data["wrapper"].nil?

      def active_deadline_value
        case state
        when "launching"
          claimed? ? @data["first_heartbeat_deadline"] : @data["claim_deadline"]
        when "running" then @data["heartbeat_deadline"]
        end
      end

      def active_deadline
        value = active_deadline_value
        value && self.class.parse_time(value, label: "active deadline", error_class: InvalidRecord)
      end

      def transition_allowed?(target)
        return false if final?

        case state
        when "launching" then %w[launching running lost].include?(target)
        when "running" then %w[running terminal lost].include?(target)
        else false
        end
      end

      def [](key) = @data[key]

      def validate!
        missing = REQUIRED_KEYS - @data.keys
        raise InvalidRecord, "attempt record missing #{missing.join(', ')}" unless missing.empty?
        raise InvalidRecord, "attempt record has invalid schema" unless @data["schema"] == SCHEMA
        unless @data["schema_version"] == SCHEMA_VERSION
          raise InvalidRecord, "attempt record has unsupported schema_version #{@data['schema_version'].inspect}"
        end
        raise InvalidRecord, "attempt record has invalid state" unless STATES.include?(state)
        unless @data["lease_version"].is_a?(Integer) && @data["lease_version"] >= 0
          raise InvalidRecord, "attempt record lease_version must be non-negative"
        end
        %w[attempt_id project task_slug intended_stage task_generation progress_token provider].each do |key|
          value = @data[key]
          raise InvalidRecord, "attempt record #{key} must be non-empty" unless value.is_a?(String) && !value.empty?
        end
        unless @data["retry_charge"].is_a?(Integer) && @data["retry_charge"] >= 0
          raise InvalidRecord, "attempt record retry_charge must be non-negative"
        end
        unless @data["inherited_outputs"].is_a?(Array) && @data["current_outputs"].is_a?(Array)
          raise InvalidRecord, "attempt output references must be arrays"
        end
        (@data["inherited_outputs"] + @data["current_outputs"]).each do |reference|
          OutputReference.validate_shape!(reference)
        end
        validate_state_fields!
        %w[created_at accepted_at claim_deadline first_heartbeat_deadline heartbeat_deadline heartbeat_at started_at ended_at].each do |key|
          value = @data[key]
          self.class.parse_time(value, label: key, error_class: InvalidRecord) if value
        end
        true
      rescue InvalidOutputReference => e
        raise InvalidRecord, e.message
      end

      def validate_state_fields!
        if state == "terminal"
          raise InvalidRecord, "terminal attempt requires an outcome" unless TERMINAL_OUTCOMES.include?(outcome)
          self.class.validate_receipt!(@data["receipt"], attempt_id: attempt_id, task_generation: task_generation)
          raise InvalidRecord, "terminal outcome and receipt disagree" unless @data["receipt"]["outcome"] == outcome
        elsif !outcome.nil? || !@data["receipt"].nil?
          raise InvalidRecord, "non-terminal attempt cannot have terminal fields"
        end

        if state == "lost"
          loss = @data["loss"]
          unless loss.is_a?(Hash) && loss["reason"].is_a?(String) && loss["at"].is_a?(String)
            raise InvalidRecord, "lost attempt requires loss reason and timestamp"
          end
        elsif !@data["loss"].nil?
          raise InvalidRecord, "only a lost attempt may have loss fields"
        end

        if state == "launching"
          deadline = claimed? ? @data["first_heartbeat_deadline"] : @data["claim_deadline"]
          raise InvalidRecord, "launching attempt requires its active deadline" if deadline.nil?
        end
        if state == "running"
          raise InvalidRecord, "running attempt requires wrapper identity" unless @data["wrapper"].is_a?(Hash)
          if @data["heartbeat_deadline"].nil? && !compatibility?
            raise InvalidRecord, "running attempt requires heartbeat deadline"
          end
        end
      end

      class << self
        def iso8601(time)
          time.utc.iso8601(6)
        end

        def parse_time(value, label:, error_class:)
          Time.iso8601(value)
        rescue ArgumentError, TypeError
          raise error_class, "#{label} must be an ISO 8601 timestamp"
        end

        def deep_copy(value)
          case value
          when Hash then value.to_h { |key, child| [ key.to_s, deep_copy(child) ] }
          when Array then value.map { |child| deep_copy(child) }
          else value
          end
        end
      end
    end
  end
end
