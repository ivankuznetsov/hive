require "digest"
require "hive/errors"
require "hive/modules/migration/qualification_checkpoint_evidence"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/qualification_scenario_process"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Trusted host supervisor for a closed sequence of full candidate
      # processes. Exit 76 is accepted only at the checkpoint named by the
      # host's generation plan; every other nonterminal outcome fails closed.
      #
      # This class deliberately has no durable scheduler or retry state. A
      # host interruption abandons the in-memory run and a later invocation
      # starts a fresh scenario sandbox.
      class QualificationScenarioOrchestrator
        ERROR =
          "patrol qualification process generations are malformed".freeze
        RESULT_SCHEMA =
          "hive-patrol-qualification-process-generations".freeze
        RECEIPT_SCHEMA =
          "hive-patrol-qualification-generation-receipt".freeze
        SCHEMA_VERSION = 1
        CHECKPOINT_EXIT = 76
        MAX_TIMEOUT_SECONDS = 3_600
        CASE_ID = QualificationRunDescriptor::SAFE_ID
        DIGEST = /\A[0-9a-f]{64}\z/
        TWO_GENERATION_CHECKPOINTS = %w[
          after_effect_intent
          after_legacy_capture
          after_legacy_decision
          after_module_decision
        ].freeze
        PUBLIC_CHECKPOINTS = (
          TWO_GENERATION_CHECKPOINTS + [ "during_reconciliation" ]
        ).freeze
        PLANS = {
          nil => [ nil ].freeze,
          "after_effect_intent" =>
            [ "after_effect_intent", nil ].freeze,
          "after_legacy_capture" =>
            [ "after_legacy_capture", nil ].freeze,
          "after_legacy_decision" =>
            [ "after_legacy_decision", nil ].freeze,
          "after_module_decision" =>
            [ "after_module_decision", nil ].freeze,
          "during_reconciliation" => [
            "before_effect_settlement",
            "during_reconciliation",
            nil
          ].freeze,
          "reconciliation_failure" => [
            "before_effect_settlement",
            "reconciliation_failure",
            nil
          ].freeze
        }.freeze
        PROCESS_ARGUMENT_KEYS = %i[
          argv case_root credentials executable hive_home installed_root
          network request_ref scenario_ref source_root workspace
        ].freeze
        PROCESS_KEYS = %w[
          attempt_count custody_count duration_seconds executable_sha256
          exit_status installed_inventory_sha256 network_isolated
          ruby_sha256 sandbox_profile_sha256 signal source_inventory_sha256
          status stderr stdout teardown timed_out
        ].freeze
        STREAM_KEYS = %w[bytes sha256 truncated].freeze
        TEARDOWN_KEYS = %w[
          attempt_count custody_count kill_authority live_processes status
        ].freeze
        RECEIPT_KEYS = %w[
          case_id checkpoint_evidence_sha256 generation kind output_sha256
          planned_checkpoint predecessor_receipt_sha256 process
          receipt_sha256 request_sha256 schema schema_version
          state_after_sha256 state_before_sha256
        ].freeze
        RESULT_KEYS = %w[
          case_id final_output_sha256 generation_count generations
          recovery_plan restart_count result_sha256 schema schema_version
        ].freeze
        GENERATION_KEYS = %w[
          after_snapshot before_snapshot checkpoint_evidence generation
          planned_checkpoint receipt
        ].freeze
        PROCESS_IDENTITY_KEYS = %w[
          executable_sha256 installed_inventory_sha256 network_isolated
          ruby_sha256 sandbox_profile_sha256 source_inventory_sha256
        ].freeze
        private_constant :CHECKPOINT_EXIT, :PLANS

        Receipt = Data.define(:payload) do
          def self.from_h(value)
            QualificationScenarioOrchestrator.receipt_from_h(value)
          end

          def to_h = payload
          def sha256 = payload.fetch("receipt_sha256")
          def kind = payload.fetch("kind")
          def generation = payload.fetch("generation")
          def planned_checkpoint = payload.fetch("planned_checkpoint")
          def predecessor_sha256 =
            payload.fetch("predecessor_receipt_sha256")
          def output_sha256 = payload.fetch("output_sha256")
          def process = payload.fetch("process")
        end

        Generation = Data.define(
          :generation, :planned_checkpoint,
          :before_snapshot, :after_snapshot,
          :checkpoint_evidence, :receipt
        ) do
          def to_h
            {
              "generation" => generation,
              "planned_checkpoint" => planned_checkpoint,
              "before_snapshot" => before_snapshot.to_h,
              "after_snapshot" => after_snapshot.to_h,
              "checkpoint_evidence" =>
                checkpoint_evidence&.to_h,
              "receipt" => receipt.to_h
            }.freeze
          end
        end

        class Result
          attr_reader :payload, :generations, :receipts

          def self.from_h(value)
            QualificationScenarioOrchestrator.result_from_h(value)
          end

          def initialize(payload:, generations:)
            @payload = payload
            @generations = generations.freeze
            @receipts =
              @generations.map(&:receipt).freeze
            freeze
          end

          def to_h = payload
          def case_id = payload.fetch("case_id")
          def recovery_plan = payload.fetch("recovery_plan")
          def generation_count = payload.fetch("generation_count")
          def restart_count = payload.fetch("restart_count")
          def final_output_sha256 =
            payload.fetch("final_output_sha256")
          def sha256 = payload.fetch("result_sha256")
        end

        class << self
          def receipt_from_h(value)
            allocate.__send__(:receipt_from_h, value)
          end

          def result_from_h(value)
            allocate.__send__(:result_from_h, value)
          end
        end

        def initialize(
          process: QualificationScenarioProcess.new,
          checkpoint_evidence: QualificationCheckpointEvidence.new,
          monotonic: lambda {
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          }
        )
          malformed! unless process.respond_to?(:call) &&
                            checkpoint_evidence.respond_to?(:capture) &&
                            checkpoint_evidence.respond_to?(:verify!) &&
                            monotonic.respond_to?(:call)
          @process = process
          @checkpoint_evidence = checkpoint_evidence
          @monotonic = monotonic
        end

        def call(
          case_id:, recovery_plan:, sandbox_root:, state_roots:,
          timeout_seconds:, prepare_generation:, verify_checkpoint:,
          final_output_sha256:, record_process: ->(**) { }
        )
          case_id = validated_case_id(case_id)
          plan = validated_plan(recovery_plan)
          timeout = validated_timeout(timeout_seconds)
          malformed! unless prepare_generation.respond_to?(:call) &&
                            verify_checkpoint.respond_to?(:call) &&
                            final_output_sha256.respond_to?(:call) &&
                            record_process.respond_to?(:call)
          started = monotonic_now
          generations = []
          predecessor = nil
          previous_state = nil
          process_identity = nil
          plan.each_with_index do |checkpoint, offset|
            generation = offset + 1
            invocation = prepare_generation.call(
              generation: generation,
              stop_after: checkpoint
            )
            request_sha256, arguments =
              validated_invocation(invocation)
            before_snapshot = capture_state(
              sandbox_root,
              state_roots
            )
            malformed! if previous_state &&
                          previous_state != before_snapshot.sha256
            process =
              begin
                @process.call(
                  **arguments,
                  timeout_seconds:
                    remaining_timeout(started, timeout)
                )
              rescue QualificationScenarioProcess::
                       PostSpawnFailure => error
                record_process.call(
                  case_id: case_id,
                  generation: generation,
                  planned_checkpoint: checkpoint,
                  process: error.evidence
                )
                raise
              end
            record_process.call(
              case_id: case_id,
              generation: generation,
              planned_checkpoint: checkpoint,
              process: process
            )
            process_projection =
              validated_process(process, checkpoint: checkpoint)
            identity = process_projection.slice(
              *PROCESS_IDENTITY_KEYS
            )
            process_identity ||= identity
            malformed! unless identity == process_identity
            after_snapshot = capture_state(
              sandbox_root,
              state_roots
            )
            checkpoint_evidence =
              if checkpoint
                candidate = verify_checkpoint.call(
                  case_id: case_id,
                  generation: generation,
                  checkpoint: checkpoint,
                  before_snapshot: before_snapshot,
                  after_snapshot: after_snapshot,
                  process: process
                )
                @checkpoint_evidence.verify!(
                  candidate,
                  checkpoint: checkpoint,
                  snapshot: after_snapshot
                ).tap do
                  confirmed = capture_state(
                    sandbox_root,
                    state_roots
                  )
                  malformed! unless
                    confirmed.sha256 == after_snapshot.sha256
                end
              end
            output_sha256 =
              unless checkpoint
                validated_digest(
                  final_output_sha256.call(
                    case_id: case_id,
                    generation: generation,
                    after_snapshot: after_snapshot,
                    process: process
                  )
                )
              end
            receipt = build_receipt(
              case_id: case_id,
              generation: generation,
              checkpoint: checkpoint,
              request_sha256: request_sha256,
              predecessor: predecessor,
              before_snapshot: before_snapshot,
              after_snapshot: after_snapshot,
              checkpoint_evidence: checkpoint_evidence,
              output_sha256: output_sha256,
              process: process_projection
            )
            generations << Generation.new(
              generation: generation,
              planned_checkpoint: checkpoint,
              before_snapshot: before_snapshot,
              after_snapshot: after_snapshot,
              checkpoint_evidence: checkpoint_evidence,
              receipt: receipt
            ).freeze
            predecessor = receipt.sha256
            previous_state = after_snapshot.sha256
          end
          build_result(
            case_id: case_id,
            recovery_plan: recovery_plan,
            generations: generations.freeze
          )
        rescue QualificationScenarioProcess::PostSpawnFailure
          raise
        rescue Hive::ConfigError => error
          raise error if error.message == ERROR

          malformed!
        rescue ArgumentError, EncodingError, KeyError, NoMethodError,
               TypeError, SystemCallError
          malformed!
        end

        private

        def validated_case_id(value)
          malformed! unless value.is_a?(String) &&
                            CASE_ID.match?(value)

          value.dup.freeze
        end

        def validated_plan(recovery_plan)
          malformed! unless recovery_plan.nil? ||
                            recovery_plan.is_a?(String)
          plan = PLANS[recovery_plan]
          malformed! unless plan

          plan
        end

        def validated_timeout(value)
          timeout = Float(value)
          malformed! unless timeout.positive? &&
                            timeout <= MAX_TIMEOUT_SECONDS

          timeout
        rescue ArgumentError, TypeError
          malformed!
        end

        def monotonic_now
          value = Float(@monotonic.call)
          malformed! unless value.finite?

          value
        rescue ArgumentError, TypeError
          malformed!
        end

        def remaining_timeout(started, timeout)
          remaining = timeout - (monotonic_now - started)
          malformed! unless remaining.positive? &&
                            remaining <= MAX_TIMEOUT_SECONDS

          remaining
        end

        def validated_invocation(value)
          malformed! unless value.is_a?(Hash) &&
                            value.keys.sort ==
                              %i[process_arguments request_sha256]
          request_sha256 =
            validated_digest(value.fetch(:request_sha256))
          arguments = value.fetch(:process_arguments)
          malformed! unless arguments.is_a?(Hash) &&
                            arguments.keys.sort ==
                              PROCESS_ARGUMENT_KEYS.sort

          [ request_sha256, arguments.dup.freeze ].freeze
        end

        def capture_state(sandbox_root, state_roots)
          roots =
            state_roots.respond_to?(:call) ?
              state_roots.call : state_roots
          @checkpoint_evidence.capture(
            sandbox_root: sandbox_root,
            roots: roots
          )
        end

        def validated_process(process, checkpoint:)
          value = PROCESS_KEYS.to_h do |key|
            [ key, process.public_send(key) ]
          end
          validated_process_projection(value)
          validate_process_outcome!(
            value,
            checkpoint: checkpoint
          )

          immutable_json(value)
        rescue NoMethodError
          malformed!
        end

        def validated_stream(value)
          exact_keys!(value, STREAM_KEYS)
          malformed! unless
            nonnegative_integer?(value.fetch("bytes")) &&
              DIGEST.match?(value.fetch("sha256").to_s) &&
              [ true, false ].include?(value.fetch("truncated"))

          immutable_json(value)
        end

        def validated_teardown(value, attempt_count:, custody_count:)
          exact_keys!(value, TEARDOWN_KEYS)
          malformed! unless
            value.fetch("status") == "passed" &&
              value.fetch("attempt_count") == attempt_count &&
              value.fetch("custody_count") == custody_count &&
              attempt_count == custody_count &&
              value.fetch("live_processes") == 0 &&
              value.fetch("kill_authority") ==
                "host_pid_namespace"

          immutable_json(value)
        end

        def build_receipt(
          case_id:, generation:, checkpoint:, request_sha256:,
          predecessor:, before_snapshot:, after_snapshot:,
          checkpoint_evidence:, output_sha256:, process:
        )
          body = {
            "schema" => RECEIPT_SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "case_id" => case_id,
            "generation" => generation,
            "kind" => checkpoint ? "checkpointed" : "completed",
            "planned_checkpoint" => checkpoint,
            "request_sha256" => request_sha256,
            "predecessor_receipt_sha256" => predecessor,
            "state_before_sha256" => before_snapshot.sha256,
            "state_after_sha256" => after_snapshot.sha256,
            "checkpoint_evidence_sha256" =>
              checkpoint_evidence&.sha256,
            "output_sha256" => output_sha256,
            "process" => process
          }
          receipt_from_h(
            body.merge(
              "receipt_sha256" =>
                digest("qualification-generation-receipt", body)
            )
          )
        end

        def receipt_from_h(value)
          value = immutable_json(value)
          exact_keys!(value, RECEIPT_KEYS)
          malformed! unless
            value.fetch("schema") == RECEIPT_SCHEMA &&
              value.fetch("schema_version") == SCHEMA_VERSION &&
              CASE_ID.match?(value.fetch("case_id").to_s) &&
              value.fetch("generation").is_a?(Integer) &&
              value.fetch("generation").between?(1, 3) &&
              %w[checkpointed completed].include?(
                value.fetch("kind")
              ) &&
              DIGEST.match?(value.fetch("request_sha256").to_s) &&
              optional_digest?(
                value.fetch("predecessor_receipt_sha256")
              ) &&
              DIGEST.match?(
                value.fetch("state_before_sha256").to_s
              ) &&
              DIGEST.match?(
                value.fetch("state_after_sha256").to_s
              ) &&
              optional_digest?(
                value.fetch("checkpoint_evidence_sha256")
              ) &&
              optional_digest?(value.fetch("output_sha256")) &&
              DIGEST.match?(value.fetch("receipt_sha256").to_s)
          checkpoint = value.fetch("planned_checkpoint")
          process = value.fetch("process")
          if value.fetch("kind") == "checkpointed"
            malformed! unless
              QualificationCheckpointEvidence::CHECKPOINTS
                .include?(checkpoint) &&
                value.fetch("checkpoint_evidence_sha256") &&
                value.fetch("output_sha256").nil?
          else
            malformed! unless checkpoint.nil? &&
                              value.fetch(
                                "checkpoint_evidence_sha256"
                              ).nil? &&
                              value.fetch("output_sha256")
          end
          validated_process_projection(process)
          validate_process_outcome!(
            process,
            checkpoint: checkpoint
          )
          body = value.reject { |key, _| key == "receipt_sha256" }
          malformed! unless
            value.fetch("receipt_sha256") ==
              digest("qualification-generation-receipt", body)

          Receipt.new(payload: value).freeze
        rescue KeyError, NoMethodError, TypeError
          malformed!
        end

        def validated_process_projection(value)
          exact_keys!(value, PROCESS_KEYS)
          malformed! unless
            value.fetch("signal").nil? &&
              value.fetch("timed_out") == false &&
              value.fetch("network_isolated") == true &&
              nonnegative_integer?(
                value.fetch("attempt_count")
              ) &&
              nonnegative_integer?(
                value.fetch("custody_count")
              )
          duration = value.fetch("duration_seconds")
          malformed! unless duration.is_a?(Numeric) &&
                            duration.finite? &&
                            duration.between?(
                              0, MAX_TIMEOUT_SECONDS
                            )
          %w[
            executable_sha256 installed_inventory_sha256 ruby_sha256
            sandbox_profile_sha256 source_inventory_sha256
          ].each do |key|
            malformed! unless DIGEST.match?(value.fetch(key).to_s)
          end
          validated_stream(value.fetch("stdout"))
          validated_stream(value.fetch("stderr"))
          validated_teardown(
            value.fetch("teardown"),
            attempt_count: value.fetch("attempt_count"),
            custody_count: value.fetch("custody_count")
          )
        end

        def validate_process_outcome!(value, checkpoint:)
          if checkpoint
            malformed! unless
              value.fetch("status") == "failed" &&
                value.fetch("exit_status") == CHECKPOINT_EXIT
          else
            malformed! unless
              value.fetch("status") == "passed" &&
                value.fetch("exit_status") == 0
          end
        end

        def build_result(case_id:, recovery_plan:, generations:)
          final_output =
            generations.fetch(-1).receipt.output_sha256
          body = {
            "schema" => RESULT_SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "case_id" => case_id,
            "recovery_plan" => recovery_plan,
            "generation_count" => generations.length,
            "restart_count" => generations.length - 1,
            "generations" =>
              generations.map(&:to_h).freeze,
            "final_output_sha256" => final_output
          }
          result_from_h(
            body.merge(
              "result_sha256" =>
                digest("qualification-process-generations", body)
            )
          )
        end

        def result_from_h(value)
          value = immutable_json(value)
          exact_keys!(value, RESULT_KEYS)
          malformed! unless
            value.fetch("schema") == RESULT_SCHEMA &&
              value.fetch("schema_version") == SCHEMA_VERSION &&
              CASE_ID.match?(value.fetch("case_id").to_s) &&
              PLANS.key?(value.fetch("recovery_plan")) &&
              DIGEST.match?(
                value.fetch("final_output_sha256").to_s
              ) &&
              DIGEST.match?(value.fetch("result_sha256").to_s)
          expected_plan = PLANS.fetch(value.fetch("recovery_plan"))
          rows = value.fetch("generations")
          malformed! unless rows.is_a?(Array) &&
                            rows.length == expected_plan.length &&
                            value.fetch("generation_count") ==
                              rows.length &&
                            value.fetch("restart_count") ==
                              rows.length - 1
          generations = []
          predecessor = nil
          previous_state = nil
          process_identity = nil
          rows.each_with_index do |row, offset|
            exact_keys!(row, GENERATION_KEYS)
            generation = offset + 1
            checkpoint = expected_plan.fetch(offset)
            malformed! unless
              row.fetch("generation") == generation &&
                row.fetch("planned_checkpoint") == checkpoint
            before_snapshot =
              QualificationCheckpointEvidence::Snapshot.from_h(
                row.fetch("before_snapshot")
              )
            after_snapshot =
              QualificationCheckpointEvidence::Snapshot.from_h(
                row.fetch("after_snapshot")
              )
            malformed! if previous_state &&
                          previous_state != before_snapshot.sha256
            checkpoint_evidence =
              if checkpoint
                evidence =
                  QualificationCheckpointEvidence::Checkpoint.from_h(
                    row.fetch("checkpoint_evidence")
                  )
                malformed! unless
                  evidence.checkpoint == checkpoint &&
                    evidence.state_sha256 ==
                      after_snapshot.sha256
                evidence
              else
                malformed! unless
                  row.fetch("checkpoint_evidence").nil?
                nil
              end
            receipt = receipt_from_h(row.fetch("receipt"))
            malformed! unless
              receipt.generation == generation &&
                receipt.planned_checkpoint == checkpoint &&
                receipt.predecessor_sha256 == predecessor &&
                receipt.to_h.fetch("case_id") ==
                  value.fetch("case_id") &&
                receipt.to_h.fetch("state_before_sha256") ==
                  before_snapshot.sha256 &&
                receipt.to_h.fetch("state_after_sha256") ==
                  after_snapshot.sha256 &&
                receipt.to_h.fetch(
                  "checkpoint_evidence_sha256"
                ) == checkpoint_evidence&.sha256
            identity = receipt.process.slice(*PROCESS_IDENTITY_KEYS)
            process_identity ||= identity
            malformed! unless identity == process_identity
            generations << Generation.new(
              generation: generation,
              planned_checkpoint: checkpoint,
              before_snapshot: before_snapshot,
              after_snapshot: after_snapshot,
              checkpoint_evidence: checkpoint_evidence,
              receipt: receipt
            ).freeze
            predecessor = receipt.sha256
            previous_state = after_snapshot.sha256
          end
          malformed! unless
            generations.fetch(-1).receipt.output_sha256 ==
              value.fetch("final_output_sha256")
          body = value.reject { |key, _| key == "result_sha256" }
          malformed! unless
            value.fetch("result_sha256") ==
              digest("qualification-process-generations", body)

          Result.new(
            payload: value,
            generations: generations.freeze
          )
        rescue KeyError, NoMethodError, TypeError
          malformed!
        end

        def validated_digest(value)
          malformed! unless value.is_a?(String) &&
                            DIGEST.match?(value)

          value.dup.freeze
        end

        def optional_digest?(value)
          value.nil? ||
            (value.is_a?(String) && DIGEST.match?(value))
        end

        def nonnegative_integer?(value)
          value.is_a?(Integer) &&
            value.between?(0, 1_000_000)
        end

        def exact_keys!(value, keys)
          malformed! unless value.is_a?(Hash) &&
                            value.keys.sort == keys.sort
        end

        def immutable_json(value)
          case value
          when Hash
            value.keys.sort.to_h do |key|
              malformed! unless key.is_a?(String)
              [
                key.dup.freeze,
                immutable_json(value.fetch(key))
              ]
            end.freeze
          when Array
            value.map { |child| immutable_json(child) }.freeze
          when String
            malformed! unless value.valid_encoding?
            value.dup.freeze
          when Integer, TrueClass, FalseClass, NilClass
            value
          when Float
            malformed! unless value.finite?
            value
          else
            malformed!
          end
        end

        def digest(domain, value)
          Digest::SHA256.hexdigest(
            "#{domain}\0#{canonical(value)}"
          ).freeze
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def malformed!
          raise Hive::ConfigError, ERROR
        end
      end
    end
  end
end
