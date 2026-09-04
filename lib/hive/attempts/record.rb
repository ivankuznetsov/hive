require "digest"
require "json"
require "time"
require "hive/attempts/capability"
require "hive/output_reference"
require "hive/billing_evidence"
require "hive/stringify_keys"

module Hive
  module Attempts
    class InvalidRecord < Hive::Error; end
    class InvalidReceipt < InvalidRecord; end

    # Immutable in-memory view of the one mutable JSON record for a durable
    # task-stage attempt. Mutation is constructed by Store while holding the
    # generation lock; callers can only observe snapshots.
    class Record
      SCHEMA = "hive-attempt"
      SCHEMA_VERSION = 4
      RECEIPT_VERSION = 1
      MAX_IDENTIFIER_BYTES = 128
      MAX_DETAIL_BYTES = 240
      MAX_EVIDENCE_REFERENCE_PATH = 512
      MAX_RESET_HINT_SECONDS = 7 * 24 * 60 * 60
      SHA256_PATTERN = /\A[0-9a-f]{64}\z/
      PROVIDER_FAILURE_CLASSES = %w[
        authentication billing_configuration exhausted_credits account_quota
        provider_rate_limit provider_outage
      ].freeze
      MODEL_FAILURE_CLASSES = %w[
        unavailable disabled deprecated model_quota model_rate model_capacity
      ].freeze
      TRUSTED_PROVENANCE = %w[
        claude_stream_json_transport codex_jsonl_transport
        grok_streaming_json_transport pi_json_transport provider_diagnostic
      ].freeze
      RECEIPT_KEYS = %w[
        receipt_version terminal_lease_version attempt_id task_generation
        ownership_generation task_input_epoch outcome exit_status started_at ended_at
        final_checkpoint output_references log_reference provider_evidence
      ].freeze
      EXPLICIT_ROUTING_KEYS = %w[mode route].freeze
      ROUTE_KEYS = %w[
        route_id provider_account_id adapter launch_binding_id model effort
      ].freeze
      ROUTE_BILLING_KEYS = %w[billing_route billing_evidence_source].freeze
      BILLING_ROUTES = Hive::BillingEvidence::ROUTES
      BILLING_EVIDENCE_SOURCES = Hive::BillingEvidence::SOURCES
      SCOPE_KEYS = %w[kind provider_account_id model].freeze
      PROVIDER_EVIDENCE_KEYS = %w[
        failure_class scope provenance route_id reset_hint_seconds fingerprint
        source_reference
      ].freeze
      SUBJECT_KINDS = %w[task_stage module_hook].freeze
      STATES = %w[launching running terminal lost].freeze
      TERMINAL_OUTCOMES = %w[succeeded failed cancelled].freeze
      FINAL_STATES = %w[terminal lost].freeze
      IMMUTABLE_KEYS = %w[
        schema schema_version attempt_id request_id
        task_id project task_slug intended_stage task_generation progress_token
        ownership_generation task_input_epoch
        provider routing worker_argv claim_capability_digest starting_revision retry_charge
        subject created_at accepted_at
      ].freeze
      REQUIRED_KEYS = (IMMUTABLE_KEYS + %w[
        state outcome lease_version claim_deadline first_heartbeat_deadline
        heartbeat_deadline wrapper worker heartbeat_at started_at ended_at
        latest_revision checkpoint log_reference inherited_outputs current_outputs
        receipt loss diagnostics
      ]).uniq.freeze

      attr_reader :data

      def self.launching(attempt_id:, request_id:, task_id:, project:,
                         task_slug:, intended_stage:, task_generation:, progress_token:, provider:,
                         worker_argv:, claim_capability_digest:, starting_revision:, retry_charge:,
                         inherited_outputs:, now:,
                         launch_timeout_sec:, ownership_generation: nil,
                         task_input_epoch: 0, subject: nil, routing: { "mode" => "legacy" })
        timestamp = iso8601(now)
        subject ||= task_stage_subject(
          task_id: task_id, task_slug: task_slug, intended_stage: intended_stage
        )
        new(
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "attempt_id" => attempt_id,
          "request_id" => request_id,
          "task_id" => task_id,
          "project" => project,
          "task_slug" => task_slug,
          "intended_stage" => intended_stage,
          "task_generation" => task_generation,
          "ownership_generation" => ownership_generation || task_generation,
          "task_input_epoch" => task_input_epoch,
          "progress_token" => progress_token,
          "provider" => provider,
          "routing" => Hive::StringifyKeys.call(routing),
          "worker_argv" => Hive::StringifyKeys.call(worker_argv),
          "claim_capability_digest" => claim_capability_digest,
          "starting_revision" => starting_revision,
          "retry_charge" => retry_charge,
          "subject" => Hive::StringifyKeys.call(subject),
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
          "inherited_outputs" => Hive::StringifyKeys.call(inherited_outputs),
          "current_outputs" => [],
          "receipt" => nil,
          "loss" => nil,
          "diagnostics" => {}
        )
      end

      def self.task_stage_subject(task_id:, task_slug:, intended_stage:)
        {
          "kind" => "task_stage", "task_id" => task_id,
          "task_slug" => task_slug, "intended_stage" => intended_stage
        }
      end

      def self.validate_receipt!(receipt, attempt_id:, task_generation:, task_input_epoch: nil,
                                 ownership_generation: nil, terminal_lease_version: nil,
                                 routing: { "mode" => "legacy" })
        unless receipt.is_a?(Hash)
          raise InvalidReceipt, "terminal receipt must be an object"
        end
        validate_exact_keys!(receipt, RECEIPT_KEYS, "terminal receipt", InvalidReceipt)
        unless receipt["receipt_version"] == RECEIPT_VERSION
          raise InvalidReceipt, "terminal receipt has unsupported receipt_version"
        end
        validate_nonnegative_integer!(
          receipt["terminal_lease_version"], "terminal receipt lease version", InvalidReceipt
        )
        if !terminal_lease_version.nil? &&
           receipt["terminal_lease_version"] != terminal_lease_version
          raise InvalidReceipt, "terminal receipt lease version mismatch"
        end
        raise InvalidReceipt, "terminal receipt attempt mismatch" unless receipt["attempt_id"] == attempt_id
        unless receipt["task_generation"] == task_generation
          raise InvalidReceipt, "terminal receipt task generation mismatch"
        end
        validate_identifier!(receipt["attempt_id"], "terminal receipt attempt", InvalidReceipt)
        validate_identifier!(
          receipt["task_generation"], "terminal receipt task generation", InvalidReceipt
        )
        validate_identifier!(
          receipt["ownership_generation"], "terminal receipt ownership generation", InvalidReceipt
        )
        validate_nonnegative_integer!(
          receipt["task_input_epoch"], "terminal receipt task input epoch", InvalidReceipt
        )
        if !task_input_epoch.nil? && receipt["task_input_epoch"] != task_input_epoch
          raise InvalidReceipt, "terminal receipt task input epoch mismatch"
        end
        if !ownership_generation.nil? && receipt["ownership_generation"] != ownership_generation
          raise InvalidReceipt, "terminal receipt ownership generation mismatch"
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
        validate_provider_evidence!(
          receipt["provider_evidence"],
          routing: routing,
          protected_references: outputs + [ receipt["log_reference"] ]
        )
        if receipt["provider_evidence"] && receipt["outcome"] != "failed"
          raise InvalidReceipt, "provider evidence requires a failed terminal outcome"
        end
        true
      end

      def initialize(data)
        @data = Hive::StringifyKeys.call(data)
        validate_source_schema!
        validate!
        self.class.deep_freeze(@data.fetch("routing"))
        self.class.deep_freeze(@data["receipt"]) if @data["receipt"]
        @data.freeze
      end

      def to_h
        Hive::StringifyKeys.call(@data)
      end

      def with(changes)
        self.class.new(to_h.merge(changes))
      end

      def state = @data.fetch("state")
      def outcome = @data["outcome"]
      def attempt_id = @data.fetch("attempt_id")
      def task_generation = @data.fetch("task_generation")
      def ownership_generation = @data.fetch("ownership_generation")
      def task_input_epoch = @data.fetch("task_input_epoch")
      def lease_version = @data.fetch("lease_version")
      def receipt = Hive::StringifyKeys.call(@data["receipt"])
      def explicit_routing? = @data.dig("routing", "mode") == "explicit"
      def wrapper = Hive::StringifyKeys.call(@data["wrapper"])
      def worker = Hive::StringifyKeys.call(@data["worker"])
      def checkpoint = Hive::StringifyKeys.call(@data["checkpoint"])
      def subject = Hive::StringifyKeys.call(@data["subject"])
      def subject_kind = @data.dig("subject", "kind")
      def module_hook? = subject_kind == "module_hook"
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

      def [](key) = @data[key]

      def validate!
        missing = REQUIRED_KEYS - @data.keys
        raise InvalidRecord, "attempt record missing #{missing.join(', ')}" unless missing.empty?
        unexpected = @data.keys - REQUIRED_KEYS
        unless unexpected.empty?
          raise InvalidRecord, "attempt record has unexpected fields #{unexpected.join(', ')}"
        end
        raise InvalidRecord, "attempt record has invalid schema" unless @data["schema"] == SCHEMA
        raise InvalidRecord, "attempt record has invalid state" unless STATES.include?(state)
        unless @data["lease_version"].is_a?(Integer) && @data["lease_version"] >= 0
          raise InvalidRecord, "attempt record lease_version must be non-negative"
        end
        %w[attempt_id project task_slug intended_stage task_generation progress_token provider].each do |key|
          value = @data[key]
          raise InvalidRecord, "attempt record #{key} must be non-empty" unless value.is_a?(String) && !value.empty?
        end
        unless @data["ownership_generation"].is_a?(String) && !@data["ownership_generation"].empty?
          raise InvalidRecord, "attempt record ownership_generation must be non-empty"
        end
        unless @data["task_input_epoch"].is_a?(Integer) && @data["task_input_epoch"] >= 0
          raise InvalidRecord, "attempt record task_input_epoch must be non-negative"
        end
        unless @data["retry_charge"].is_a?(Integer) && @data["retry_charge"] >= 0
          raise InvalidRecord, "attempt record retry_charge must be non-negative"
        end
        self.class.validate_routing!(
          @data["routing"],
          provider: @data["provider"],
          attempt_id: attempt_id,
          task_generation: task_generation,
          ownership_generation: ownership_generation
        )
        validate_subject!
        worker_argv = @data["worker_argv"]
        unless worker_argv.is_a?(Array) && worker_argv.all? { |value| value.is_a?(String) && !value.empty? }
          raise InvalidRecord, "attempt record worker_argv must contain only non-empty strings"
        end
        if worker_argv.empty? || !Capability.valid_digest?(@data["claim_capability_digest"])
          raise InvalidRecord, "durable attempt requires worker argv and a capability digest"
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

      def validate_source_schema!
        raise InvalidRecord, "attempt record has invalid schema" unless @data["schema"] == SCHEMA
        return if @data["schema_version"] == SCHEMA_VERSION

        raise InvalidRecord,
              "attempt record has unsupported schema_version #{@data['schema_version'].inspect}"
      end

      def validate_state_fields!
        if state == "terminal"
          raise InvalidRecord, "terminal attempt requires an outcome" unless TERMINAL_OUTCOMES.include?(outcome)
          self.class.validate_receipt!(
            @data["receipt"], attempt_id: attempt_id, task_generation: task_generation,
            task_input_epoch: task_input_epoch, ownership_generation: ownership_generation,
            terminal_lease_version: lease_version, routing: @data["routing"]
          )
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
          raise InvalidRecord, "running attempt requires heartbeat deadline" if @data["heartbeat_deadline"].nil?
        end
      end

      def validate_subject!
        value = @data["subject"]
        unless value.is_a?(Hash) && SUBJECT_KINDS.include?(value["kind"])
          raise InvalidRecord, "attempt record subject is malformed"
        end
        case value.fetch("kind")
        when "task_stage"
          expected = %w[intended_stage kind task_id task_slug]
          unless value.keys.sort == expected && value["task_id"] == @data["task_id"] &&
                 value["task_slug"] == @data["task_slug"] && value["intended_stage"] == @data["intended_stage"]
            raise InvalidRecord, "attempt task subject has incompatible identity with legacy fields"
          end
        when "module_hook"
          expected = %w[
            configuration_digest event_id event_name grant_digest hook kind module
            module_generation occurrence_id project_id
          ]
          unless value.keys.sort == expected &&
                 %w[project_id module hook event_id occurrence_id event_name module_generation].all? do |key|
                   value[key].is_a?(String) && !value[key].empty?
                 end &&
                 %w[configuration_digest grant_digest].all? do |key|
                   /\A[0-9a-f]{64}\z/.match?(value[key].to_s)
                 end
            raise InvalidRecord, "attempt module hook subject is malformed"
          end
        end
      end

      class << self
        def validate_routing!(routing, provider:, attempt_id:, task_generation:, ownership_generation:)
          unless routing.is_a?(Hash)
            raise InvalidRecord, "attempt routing must be an object"
          end

          case routing["mode"]
          when "legacy"
            validate_exact_keys!(routing, %w[mode], "legacy attempt routing", InvalidRecord)
          when "explicit"
            validate_explicit_routing!(
              routing,
              provider: provider,
              attempt_id: attempt_id,
              task_generation: task_generation,
              ownership_generation: ownership_generation
            )
          else
            raise InvalidRecord, "attempt routing mode must be legacy or explicit"
          end
          true
        end

        def validate_explicit_routing!(routing, provider:, attempt_id:, task_generation:,
                                       ownership_generation:)
          validate_exact_keys!(
            routing, EXPLICIT_ROUTING_KEYS, "explicit attempt routing", InvalidRecord
          )
          route = validate_route!(routing["route"])
          unless route["adapter"] == provider
            raise InvalidRecord, "explicit routing adapter must match the attempt provider"
          end
        end

        def validate_route!(route, error_class: InvalidRecord)
          unless route.is_a?(Hash) && (ROUTE_KEYS - route.keys).empty? &&
                 (route.keys - ROUTE_KEYS - ROUTE_BILLING_KEYS).empty?
            raise error_class, "provider route has invalid fields"
          end
          %w[route_id provider_account_id adapter launch_binding_id model].each do |key|
            validate_identifier!(route[key], "provider route #{key.tr('_', ' ')}", error_class)
          end
          unless route["effort"].nil?
            validate_identifier!(route["effort"], "provider route effort", error_class)
          end
          billing_values = ROUTE_BILLING_KEYS.map { |key| route[key] }
          unless billing_values.all?(&:nil?) || billing_values.none?(&:nil?)
            raise error_class, "provider route billing evidence must be complete"
          end
          if billing_values.none?(&:nil?)
            unless BILLING_ROUTES.include?(route["billing_route"])
              raise error_class, "provider route billing route is invalid"
            end
            unless BILLING_EVIDENCE_SOURCES.include?(
              route["billing_evidence_source"]
            )
              raise error_class, "provider route billing evidence source is invalid"
            end
          end
          route
        end

        def validate_provider_evidence!(evidence, routing:, protected_references:)
          return true if evidence.nil?
          unless routing.is_a?(Hash) && routing["mode"] == "explicit"
            raise InvalidReceipt, "provider evidence requires an explicit admitted route"
          end

          validate_exact_keys!(
            evidence, PROVIDER_EVIDENCE_KEYS, "provider evidence", InvalidReceipt
          )
          route = validate_route!(routing["route"], error_class: InvalidReceipt)
          scope = validate_scope!(evidence["scope"], "provider evidence scope", InvalidReceipt)
          allowed_classes = scope["kind"] == "provider_account" ?
            PROVIDER_FAILURE_CLASSES : MODEL_FAILURE_CLASSES
          unless allowed_classes.include?(evidence["failure_class"])
            raise InvalidReceipt, "provider evidence failure class is invalid for its scope"
          end
          unless TRUSTED_PROVENANCE.include?(evidence["provenance"])
            raise InvalidReceipt, "provider evidence provenance is not allowlisted"
          end
          validate_identifier!(evidence["route_id"], "provider evidence route", InvalidReceipt)
          unless evidence["route_id"] == route["route_id"]
            raise InvalidReceipt, "provider evidence route does not match the admitted route"
          end
          unless scope["provider_account_id"] == route["provider_account_id"] &&
                 (scope["kind"] == "provider_account" || scope["model"] == route["model"])
            raise InvalidReceipt, "provider evidence scope does not match the admitted route"
          end

          reset_hint = evidence["reset_hint_seconds"]
          unless reset_hint.nil? ||
                 (reset_hint.is_a?(Integer) && reset_hint.between?(0, MAX_RESET_HINT_SECONDS))
            raise InvalidReceipt, "provider evidence reset hint is outside the allowed bound"
          end
          validate_sha256!(evidence["fingerprint"], "provider evidence fingerprint", InvalidReceipt)
          reference = evidence["source_reference"]
          OutputReference.validate_shape!(reference)
          if reference["path"].bytesize > MAX_EVIDENCE_REFERENCE_PATH
            raise InvalidReceipt, "provider evidence source reference path is too long"
          end
          unless protected_references.include?(reference)
            raise InvalidReceipt, "provider evidence source reference is not terminal output"
          end

          safe_fields = {
            "failure_class" => evidence["failure_class"],
            "scope" => scope,
            "provenance" => evidence["provenance"],
            "route_id" => evidence["route_id"],
            "reset_hint_seconds" => reset_hint
          }
          expected = Digest::SHA256.hexdigest(JSON.generate(canonical_value(safe_fields)))
          unless evidence["fingerprint"] == expected
            raise InvalidReceipt, "provider evidence fingerprint does not match safe fields"
          end
          true
        rescue InvalidOutputReference => e
          raise InvalidReceipt, e.message
        end

        def validate_scope!(scope, label, error_class)
          validate_exact_keys!(scope, SCOPE_KEYS, label, error_class)
          unless %w[provider_account model].include?(scope["kind"])
            raise error_class, "#{label} kind must be provider_account or model"
          end
          validate_identifier!(scope["provider_account_id"], "#{label} provider account", error_class)
          if scope["kind"] == "provider_account"
            raise error_class, "#{label} provider account must not include a model" unless scope["model"].nil?
          else
            validate_identifier!(scope["model"], "#{label} model", error_class)
          end
          scope
        end

        def validate_exact_keys!(value, expected, label, error_class)
          unless value.is_a?(Hash) && value.keys.all?(String) && value.keys.sort == expected.sort
            raise error_class, "#{label} has unexpected or missing fields"
          end
          true
        end

        def validate_identifier!(value, label, error_class)
          unless value.is_a?(String) && !value.empty? && value.bytesize <= MAX_IDENTIFIER_BYTES &&
                 value.valid_encoding? && !value.match?(/[\u0000-\u001f\u007f]/)
            raise error_class, "#{label} identity is invalid"
          end
          true
        end

        def validate_optional_detail!(value, label, error_class)
          return true if value.nil?
          unless value.is_a?(String) && !value.empty? && value.bytesize <= MAX_DETAIL_BYTES &&
                 value.valid_encoding? && !value.match?(/[\u0000-\u001f\u007f]/)
            raise error_class, "#{label} is invalid"
          end
          true
        end

        def validate_nonnegative_integer!(value, label, error_class)
          unless value.is_a?(Integer) && value >= 0
            raise error_class, "#{label} must be a non-negative integer"
          end
          true
        end

        def validate_sha256!(value, label, error_class)
          unless value.is_a?(String) && SHA256_PATTERN.match?(value)
            raise error_class, "#{label} must be lowercase SHA-256"
          end
          true
        end

        def scope_identity(scope)
          [ scope["kind"], scope["provider_account_id"], scope["model"] ]
        end

        def canonical_value(value)
          case value
          when Hash
            value.keys.sort.to_h { |key| [ key, canonical_value(value.fetch(key)) ] }
          when Array
            value.map { |child| canonical_value(child) }
          else
            value
          end
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, child| key.freeze; deep_freeze(child) }
          when Array
            value.each { |child| deep_freeze(child) }
          when String
            value.freeze
          end
          value&.freeze
        end

        def iso8601(time)
          time.utc.iso8601(6)
        end

        def parse_time(value, label:, error_class:)
          Time.iso8601(value)
        rescue ArgumentError, TypeError
          raise error_class, "#{label} must be an ISO 8601 timestamp"
        end
      end
    end
  end
end
