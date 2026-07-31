require "digest"
require "fileutils"
require "open3"
require "pathname"
require "shellwords"
require "stringio"
require_relative "../../errors"
require_relative "qualification_scenario_actuals"
require_relative "qualification_scenario_input"

module Hive
  module Modules
    module Migration
      # Qualification-only orchestration for one closed production scenario.
      # The driver accepts no decision labels: those are derived later from
      # the persisted legacy capture and comparator evidence.
      class QualificationScenarioDriver
        CANDIDATE_PACKAGES = %w[
          modules/architecture-patrol
          modules/patrol
        ].freeze
        SUPPORTED_OPERATIONS = %w[
          capacity_deferral new_commit ordinary_clean_fixture
          ordinary_positive_fixture partial_failure quota_deferral
          restart same_commit timer_due timer_not_due timer_reset_reload
        ].freeze
        NEW_COMMIT_OPERATIONS = %w[new_commit same_commit].freeze
        RELOADED_OPERATIONS = %w[restart timer_reset_reload].freeze
        SUPPORTED_FAULTS = %w[after_module_decision].freeze
        FAULT_EXIT_STATUS = 76
        private_constant :FAULT_EXIT_STATUS
        PROJECT_KEYS = %w[name project_id repository].freeze
        MAX_PATH_BYTES = 4_096
        INSTALL_LEAD_TIME_SEC = 3_600
        ATTEMPT_WAIT_TIMEOUT_SEC = 15
        ATTEMPT_WAIT_INTERVAL_SEC = 0.01

        Result = Data.define(
          :observation, :repository_root, :hive_state_path,
          :attempts_root, :comparator_record, :effect_index
        )

        class QualificationAgent
          def initialize(output_path:, operation:, findings:)
            @output_path = output_path
            @operation = operation
            @findings = findings
          end

          def run!
            if @operation == "partial_failure"
              return {
                status: :error,
                error_message:
                  "qualification reviewer partial failure"
              }
            end

            File.binwrite(
              @output_path,
              Hive::WorkflowPackage::CanonicalJSON.generate(
                "findings" => @findings
              )
            )
            {
              status: :ok,
              model: "qualification-fixture",
              usage: {
                input: 1,
                output: 1,
                cached: 0,
                model: "qualification-fixture"
              }
            }
          end
        end
        private_constant :QualificationAgent

        class QualificationTokenBudget
          def initialize(delegate:, operation:)
            @delegate = delegate
            @operation = operation
            @cycle_exhausted = false
          end

          def remaining_launches(...)
            available = @delegate.remaining_launches(...)
            return available unless
              %w[
                capacity_deferral quota_deferral
              ].include?(@operation)

            [ available, 1 ].max
          end

          def acquire(stage:, minimum_tokens:)
            exhaust_cycle!(stage) if
              @operation == "capacity_deferral" &&
                !@cycle_exhausted
            @delegate.acquire(
              stage: stage,
              minimum_tokens: minimum_tokens
            )
          end

          def method_missing(name, ...)
            return super unless @delegate.respond_to?(name)

            @delegate.public_send(name, ...)
          end

          def respond_to_missing?(name, include_private = false)
            @delegate.respond_to?(name, include_private) || super
          end

          private

          def exhaust_cycle!(stage)
            @cycle_exhausted = true
            return unless
              @delegate.acquire(
                stage: stage,
                minimum_tokens: 0
              )

            @delegate.record!(
              result: {
                status: :ok,
                model: "qualification-fixture",
                usage: {
                  input: 0,
                  output: 0,
                  cached: 0,
                  model: "qualification-fixture"
                }
              },
              profile: "qualification-fixture",
              stage: stage,
              started_at: Time.now.utc
            )
          end
        end
        private_constant :QualificationTokenBudget

        def initialize(candidate_source_root:, sandbox_root:, project:,
                       scenario_input:)
          @candidate_source_root =
            canonical_root(candidate_source_root, "candidate source")
          @sandbox_root =
            canonical_path(sandbox_root, "sandbox")
          @project = validate_project(project)
          @scenario_input = validate_scenario_input(scenario_input)
          @clock = -> { @scenario_input.clock }
        end

        def call
          validate_scenario!
          package_roots = candidate_package_roots
          validate_sandbox!
          validate_process_home!
          load_runtime!
          repository_root, hive_state_path = build_sandbox!
          registry_entry =
            build_registry!(repository_root, hive_state_path)
          store = install_candidate_packages!(
            package_roots,
            hive_state_path
          )
          establish_legacy_ownership!(
            repository_root,
            hive_state_path,
            store
          )
          prepare_scenario!(
            repository_root,
            hive_state_path
          )
          event, capture = run_legacy_patrol!(
            registry_entry,
            repository_root,
            hive_state_path
          )
          unless %w[completed not_dispatched].include?(
                   capture.outcome_class
                 ) &&
                 capture.owner == "legacy" &&
                 event.dig(
                   "payload",
                   "legacy_mutator_capture"
                 ) == capture.to_h
            raise Hive::ConfigError,
                  "qualification legacy patrol capture is malformed"
          end
          decisions, terminal, attempt_records =
            run_module_shadow_with_recovery!(
            event: event,
            registry_entry: registry_entry,
            hive_state_path: hive_state_path,
            store: store
          )
          restart_generation =
            if
              RELOADED_OPERATIONS.include?(
                @scenario_input.operation
              ) ||
                (@consumed_faults || {}).any? do |_name, consumed|
                  consumed
                end
              2
            else
              1
            end
          assemble_result!(
            case_id: @scenario_input.case_id,
            event: event,
            capture: capture,
            decisions: decisions,
            terminal: terminal,
            attempt_records: attempt_records,
            repository_root: repository_root,
            hive_state_path: hive_state_path,
            restart_generation: restart_generation
          )
        end

        private

        def load_runtime!
          require "hive/attempts/api"
          require "hive/attempts/output_reference"
          require "hive/attempts/reconciler"
          require "hive/attempts/store"
          require "hive/commands/patrol"
          require "hive/config"
          require "hive/daemon/patrol_scheduler"
          require "hive/module_package/catalog_client"
          require "hive/module_package/managed_store"
          require "hive/module_package/preview"
          require "hive/module_package/validator"
          require "hive/paths"
          require "hive/modules/event_ledger"
          require "hive/modules/event_publisher"
          require "hive/modules/decision_journal"
          require "hive/modules/daemon_runtime"
          require "hive/modules/dispatcher"
          require "hive/modules/migration/patrol_effect_index"
          require "hive/modules/migration/patrols"
          require "hive/modules/migration/qualification_scenario_observations"
          require "hive/modules/migration/shadow_comparator"
          require "hive/patrol/reviewer"
          require "hive/patrol/state_store"
          require "hive/workflow_package/canonical_yaml"
        end

        def run_module_shadow_with_recovery!(
          store:, event:, registry_entry:, hive_state_path:
        )
          return run_module_shadow!(
            store: store,
            event: event,
            registry_entry: registry_entry,
            hive_state_path: hive_state_path
          ) unless
            qualification_fault?("after_module_decision")
          unless Process.respond_to?(:fork)
            raise Hive::ConfigError,
                  "qualification fault supervisor is unavailable"
          end

          actor_pid = fork do
            run_module_shadow!(
              store: store,
              event: event,
              registry_entry: registry_entry,
              hive_state_path: hive_state_path
            )
            Process.exit!(71)
          rescue StandardError
            Process.exit!(70)
          end
          _pid, status = Process.wait2(actor_pid)
          unless status.exited? && status.exitstatus == FAULT_EXIT_STATUS
            raise Hive::ConfigError,
                  "qualification fault actor did not stop at its checkpoint"
          end
          wait_for_fault_workers!
          attempt_store = Hive::Attempts::Store.new(
            root: qualification_attempts_root
          )
          @pre_fault_durable_state_sha256 =
            runtime_state_digest(
              hive_state_path: hive_state_path,
              attempt_store: attempt_store
            )
          @consumed_faults ||= {}
          @consumed_faults["after_module_decision"] = true
          reconciliation =
            Hive::Attempts::Reconciler.new(
              store: attempt_store
            ).reconcile(now: @clock.call)
          unless reconciliation.newly_lost_attempts.length == 1
            raise Hive::ConfigError,
                  "qualification fault attempt was not recovered as lost"
          end

          run_module_shadow!(
            store: store,
            event: event,
            registry_entry: registry_entry,
            hive_state_path: hive_state_path
          )
        rescue Errno::ECHILD
          raise Hive::ConfigError,
                "qualification fault actor custody was lost"
        ensure
          if actor_pid
            begin
              Process.kill("KILL", actor_pid)
              Process.wait(actor_pid)
            rescue Errno::ESRCH, Errno::ECHILD
              nil
            end
          end
        end

        def run_module_shadow!(store:, event:, registry_entry:,
                               hive_state_path:)
          worker_release_reader = nil
          worker_release_writer = nil
          if qualification_fault?("after_module_decision")
            worker_release_reader,
              worker_release_writer = IO.pipe
          end
          attempts_root = qualification_attempts_root
          attempt_store = Hive::Attempts::Store.new(root: attempts_root)
          attempts_daemon =
            Hive::Attempts::ConfiguredDispatcher.new(
              store: attempt_store,
              worker_release_io: worker_release_reader
            )
          attempts_api = Hive::Attempts::API.new(
            store: attempt_store,
            daemon: attempts_daemon
          )
          checkpoint = lambda do |name, decision|
            qualification_checkpoint!(
              name,
              decision,
              worker_release_writer:
                worker_release_writer
            )
          end
          runtime = Hive::Modules::DaemonRuntime.new(
            attempt_store: attempt_store,
            attempt_dispatcher: attempts_api,
            registry: -> { [ registry_entry ] },
            dispatcher_factory: lambda do |**dependencies|
              Hive::Modules::Dispatcher.new(
                **dependencies,
                checkpoint: checkpoint
              )
            end,
            clock: @clock
          )
          journal = Hive::Modules::DecisionJournal.new(
            root: File.join(hive_state_path, "module-runtime")
          )
          decision_count_before = journal.all.length
          first_tick = runtime.tick(now: @clock.call).fetch(0)
          decisions = journal.all
          event_decisions = decisions.select do |decision|
            decision["module"] == "patrol" &&
              decision["hook"] == "scheduled-scan" &&
              decision["event_id"] == event.fetch("event_id")
          end.sort_by do |decision|
            [
              (
                decision["outcome"] == "launch" &&
                decision["reason"] == "admitted"
              ) ? 0 : 1,
              decision.fetch("evaluated_at"),
              decision.fetch("decision_id")
            ]
          end
          launches = event_decisions.select do |decision|
            decision["outcome"] == "launch" &&
              decision["reason"] == "admitted"
          end
          decision = launches.fetch(0)
          extras = event_decisions.reject do |row|
            row.equal?(decision)
          end
          unless first_tick.fetch(:status) == :ok &&
                 first_tick.fetch(:decisions) ==
                   decisions.length - decision_count_before &&
                 launches.length == 1 &&
                 !decision["attempt_id"].to_s.empty? &&
                 extras.all? do |row|
                   row["outcome"] == "skip"
                 end
            raise Hive::ConfigError,
                  "qualification module event drain is malformed"
          end

          terminal, attempt_records =
            await_terminal_lineage(
              attempt_store,
              event_id: event.fetch("event_id"),
              module_name: "patrol"
            )
          unless attempt_records.fetch(0).attempt_id ==
                   decision.fetch("attempt_id") &&
                 terminal.state == "terminal" &&
                 terminal.outcome == "succeeded" &&
                 terminal.module_hook? &&
                 terminal.wrapper.is_a?(Hash) &&
                 terminal.worker.is_a?(Hash) &&
                 Hive::Attempts::OutputReference.verify(
                   terminal.receipt.fetch("log_reference"),
                   root: attempts_root
                 )
            raise Hive::ConfigError,
                  "qualification module hook did not succeed"
          end
          before_replay = qualification_runtime_snapshot(
            attempt_store: attempt_store,
            journal: journal,
            hive_state_path: hive_state_path
          )
          second_tick = runtime.tick(now: @clock.call).fetch(0)
          after_replay = qualification_runtime_snapshot(
            attempt_store: attempt_store,
            journal: journal,
            hive_state_path: hive_state_path
          )
          runs = Dir.glob(
            File.join(store.runtime_path("patrol"), "runs", "*.json")
          ).map do |path|
            JSON.parse(File.binread(path))
          end
          unless second_tick.fetch(:status) == :ok &&
                 second_tick.fetch(:decisions).zero? &&
                 second_tick.fetch(:schedules).zero? &&
                 runs.length == 1 &&
                 runs.fetch(0)["status"] == "succeeded" &&
                 before_replay == after_replay
            raise Hive::ConfigError,
                  "qualification module event replay was not idempotent"
          end

          [ event_decisions, terminal, attempt_records ].freeze
        rescue IndexError
          raise Hive::ConfigError,
                "qualification module hook did not succeed"
        ensure
          [
            worker_release_reader,
            worker_release_writer
          ].compact.each do |io|
            io.close unless io.closed?
          end
        end

        def qualification_checkpoint!(
          name,
          decision,
          worker_release_writer:
        )
          return unless
            qualification_fault?(
              "after_module_decision"
            ) &&
              name == :after_module_decision &&
              decision["module"] ==
                @scenario_input.module_name &&
              decision["outcome"] == "launch" &&
              decision["reason"] == "admitted" &&
              !decision["attempt_id"].to_s.empty?
          unless
            worker_release_writer &&
              !worker_release_writer.closed?
            raise Hive::ConfigError,
                  "qualification worker release gate is unavailable"
          end

          Process.exit!(FAULT_EXIT_STATUS)
        end

        def qualification_fault?(name)
          @scenario_input.faults.include?(name) &&
            !(@consumed_faults || {}).fetch(name, false)
        end

        def wait_for_fault_workers!
          deadline =
            Process.clock_gettime(Process::CLOCK_MONOTONIC) +
            ATTEMPT_WAIT_TIMEOUT_SEC
          loop do
            store = Hive::Attempts::Store.new(
              root: qualification_attempts_root,
              create_directories: false
            )
            records = store.scan.records
            pids = records.flat_map do |record|
              [
                record.wrapper && record.wrapper["pid"],
                record.worker && record.worker["pid"]
              ]
            end.compact
            return if
              !pids.empty? &&
                pids.none? { |pid| process_alive?(pid) }

            if Process.clock_gettime(
              Process::CLOCK_MONOTONIC
            ) >= deadline
              raise Hive::ConfigError,
                    "qualification fault workers did not terminate"
            end
            sleep ATTEMPT_WAIT_INTERVAL_SEC
          end
        end

        def process_alive?(pid)
          Process.kill(0, Integer(pid))
          true
        rescue Errno::ESRCH
          false
        rescue ArgumentError, TypeError
          true
        end

        def await_terminal_lineage(
          attempt_store,
          event_id:,
          module_name:
        )
          deadline =
            Process.clock_gettime(Process::CLOCK_MONOTONIC) +
            ATTEMPT_WAIT_TIMEOUT_SEC
          loop do
            records =
              attempt_store.scan.records.select do |record|
                subject = record.subject
                record.module_hook? &&
                  subject["project_id"] ==
                    @project.fetch("project_id") &&
                  subject["module"] == module_name &&
                  subject["event_id"] == event_id
              end
            successful =
              records.select do |record|
                record.state == "terminal" &&
                  record.outcome == "succeeded"
              end
            unless successful.empty?
              terminal = successful.max_by do |record|
                record["retry_charge"]
              end
              lineage =
                attempt_lineage(records, terminal)
              if lineage.length != records.length ||
                 successful.length != 1
                raise Hive::ConfigError,
                      "qualification attempt lineage is ambiguous"
              end

              return [ terminal, lineage.freeze ].freeze
            end

            remaining =
              deadline -
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              raise Hive::ConfigError,
                    "qualification module hook did not terminate"
            end
            sleep [ ATTEMPT_WAIT_INTERVAL_SEC, remaining ].min
          end
        end

        def attempt_lineage(records, terminal)
          by_id = records.to_h do |record|
            [ record.attempt_id, record ]
          end
          lineage = []
          current = terminal
          while current
            lineage << current
            predecessor_id =
              current["predecessor_attempt_id"]
            current =
              predecessor_id && by_id.fetch(predecessor_id)
          end
          lineage.reverse!
          unless lineage.fetch(0)["predecessor_attempt_id"].nil? &&
                 lineage.fetch(0)["retry_charge"].zero? &&
                 lineage.each_cons(2).all? do |previous, successor|
                   successor["predecessor_attempt_id"] ==
                     previous.attempt_id &&
                     successor["retry_charge"] ==
                       previous["retry_charge"] + 1
                 end
            raise Hive::ConfigError,
                  "qualification attempt lineage is malformed"
          end
          lineage
        rescue KeyError
          raise Hive::ConfigError,
                "qualification attempt lineage is incomplete"
        end

        def runtime_state_digest(hive_state_path:, attempt_store:)
          journal = Hive::Modules::DecisionJournal.new(
            root: File.join(hive_state_path, "module-runtime")
          )
          Digest::SHA256.hexdigest(
            canonical(
              qualification_runtime_snapshot(
                attempt_store: attempt_store,
                journal: journal,
                hive_state_path: hive_state_path
              )
            )
          ).freeze
        end

        def qualification_runtime_snapshot(
          attempt_store:, journal:, hive_state_path:
        )
          shadow_root = File.join(
            hive_state_path,
            "module-runtime",
            "migration",
            "shadow",
            "patrol"
          )
          {
            "attempts" =>
              attempt_store.scan.records.map(&:to_h),
            "decisions" => journal.all,
            "shadow_files" =>
              Dir.glob(File.join(shadow_root, "*.json"))
                .sort
                .to_h do |path|
                  [ File.basename(path), File.binread(path) ]
                end
          }.freeze
        end

        def assemble_result!(case_id:, event:, capture:, decisions:,
                             terminal:, attempt_records:, repository_root:,
                             hive_state_path:, restart_generation:)
          comparator = Hive::Modules::Migration::ShadowComparator.new(
            root: File.join(
              hive_state_path,
              "module-runtime",
              "migration",
              "shadow"
            )
          )
          records = comparator.each_record("patrol").to_a
          unless records.length == 1
            raise Hive::ConfigError,
                  "qualification comparator evidence is unavailable"
          end
          comparator_record = records.fetch(0)
          effect_index =
            Hive::Modules::Migration::PatrolEffectIndex.build(
              records: records
            )
          receipt_ids = comparator_record.fetch(
            "legacy_effects"
          ).map do |receipt|
            receipt.fetch("receipt_id")
          end.sort
          unless comparator_record.fetch("comparable") == true &&
                 comparator_record.fetch("evidence_source") ==
                   "legacy_mutator_capture" &&
                 comparator_record.fetch(
                   "unexplained_differences"
                 ).empty? &&
                 comparator_record.fetch("duplicate_effects").empty? &&
                 receipt_ids == capture.effect_ids.sort &&
                 effect_index.legacy_count == receipt_ids.length &&
                 effect_index.module_count.zero? &&
                 effect_index.duplicate_keys.empty?
            raise Hive::ConfigError,
                  "qualification comparator evidence is malformed"
          end

          attempts =
            attempt_records.map do |record|
              attempt_projection(record)
            end.freeze
          recovered_durable_state_sha256 =
            if (@consumed_faults || {}).any? do |_name, consumed|
              consumed
            end
              runtime_state_digest(
                hive_state_path: hive_state_path,
                attempt_store:
                  Hive::Attempts::Store.new(
                    root: qualification_attempts_root
                  )
              )
            else
              durable_state_digest(
                event: event,
                decisions: decisions,
                attempts: attempts,
                comparator_record: comparator_record,
                effect_index: effect_index
              )
            end
          pre_fault_durable_state_sha256 =
            @pre_fault_durable_state_sha256 ||
            recovered_durable_state_sha256
          fault_checkpoint =
            if (@consumed_faults || {}).fetch(
              "after_module_decision",
              false
            )
              "after_module_decision"
            end
          observation = {
            "case_id" => case_id,
            "decision_id" =>
              comparator_record.fetch("decision_id"),
            "module" => comparator_record.fetch("module"),
            "repository_sha" =>
              git!(repository_root, "rev-parse", "HEAD").strip,
            "trigger_digest" =>
              comparator_record.fetch("trigger_digest"),
            "comparator_semantic_digest" =>
              comparator_record.fetch("semantic_digest"),
            "legacy_capture_id" => capture.capture_id,
            "event_id" => event.fetch("event_id"),
            "legacy_effect_keys" => effect_index.legacy_keys,
            "module_effect_keys" =>
              effect_index.entries
                .select { |entry| entry["channel"] == "module" }
                .map { |entry| entry.fetch("effect_key") }
                .sort
                .freeze,
            "fault_checkpoint" => fault_checkpoint,
            "pre_fault_durable_state_sha256" =>
              pre_fault_durable_state_sha256,
            "recovered_durable_state_sha256" =>
              recovered_durable_state_sha256,
            "restart_generation" => restart_generation,
            "event" => event,
            "decisions" => decisions,
            "attempts" => attempts
          }
          validated =
            Hive::Modules::Migration::
              QualificationScenarioActuals.from_h(
                "schema" =>
                  Hive::Modules::Migration::
                    QualificationScenarioActuals::SCHEMA,
                "schema_version" =>
                  Hive::Modules::Migration::
                    QualificationScenarioActuals::SCHEMA_VERSION,
                "actuals" => [ observation ]
              ).actuals.fetch(0)
          Result.new(
            observation: validated,
            repository_root: repository_root,
            hive_state_path: hive_state_path,
            attempts_root: qualification_attempts_root,
            comparator_record: comparator_record,
            effect_index: effect_index
          ).freeze
        rescue IndexError, KeyError
          raise Hive::ConfigError,
                "qualification persisted artifacts are malformed"
        end

        def attempt_projection(record)
          value = record.to_h.slice(
            "attempt_id",
            "predecessor_attempt_id",
            "retry_charge",
            "state",
            "outcome",
            "task_generation",
            "ownership_generation",
            "task_input_epoch",
            "subject",
            "receipt",
            "loss"
          )
          value["receipt_sha256"] =
            value["receipt"] &&
            Digest::SHA256.hexdigest(canonical(value["receipt"]))
          value["projection_sha256"] =
            Digest::SHA256.hexdigest(canonical(value))
          value.freeze
        end

        # Semantic digest of the selected durable records for this no-fault
        # slice. Fault scenarios must instead snapshot their actual durable
        # boundaries before injection and after recovery.
        def durable_state_digest(event:, decisions:, attempts:,
                                 comparator_record:, effect_index:)
          Digest::SHA256.hexdigest(
            canonical(
              "event_id" => event.fetch("event_id"),
              "decision_ids" =>
                decisions.map do |decision|
                  decision.fetch("decision_id")
                end,
              "attempt_projections" =>
                attempts.map do |attempt|
                  attempt.fetch("projection_sha256")
                end,
              "comparator_decision_id" =>
                comparator_record.fetch("decision_id"),
              "comparator_semantic_digest" =>
                comparator_record.fetch("semantic_digest"),
              "effect_index_digest" => effect_index.digest
            )
          ).freeze
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def run_legacy_patrol!(
          registry_entry,
          repository_root,
          hive_state_path
        )
          config_loader =
            ->(root) { Hive::Config.load(root) }
          scheduler = patrol_scheduler(
            registry_entry,
            config_loader
          )
          dispatches = scheduler.tick(now: @clock.call)
          if @scenario_input.operation == "restart"
            unless dispatches.length == 1
              raise Hive::ConfigError,
                    "qualification patrol schedule was not reserved"
            end
            scheduler = patrol_scheduler(
              registry_entry,
              config_loader
            )
            dispatches = scheduler.tick(now: @clock.call)
          end
          if dispatches.length > 1
            raise Hive::ConfigError,
                  "qualification patrol schedule was not reserved"
          end
          unless dispatches.empty?
            run_reserved_patrol!(
              scheduler,
              dispatches.fetch(0),
              registry_entry,
              repository_root,
              hive_state_path,
              config_loader
            )
          end
          events = Hive::Modules::EventLedger.new(
            root: File.join(hive_state_path, "module-runtime")
          ).all
          unless events.length == 1
            raise Hive::ConfigError,
                  "qualification legacy patrol event is unavailable"
          end
          event = events.fetch(0)
          final_capture =
            Hive::Modules::Migration::PatrolCapture.from_h(
              event.dig(
                "payload",
                "legacy_mutator_capture"
              )
            )
          [ event, final_capture ]
        rescue KeyError, TypeError
          raise Hive::ConfigError,
                "qualification legacy patrol did not complete cleanly"
        end

        def patrol_scheduler(registry_entry, config_loader)
          Hive::Daemon::PatrolScheduler.new(
            registry: -> { [ registry_entry ] },
            config_loader: config_loader,
            event_publisher:
              Hive::Modules::EventPublisher.new(clock: @clock)
          )
        end

        def run_reserved_patrol!(
          scheduler,
          dispatch,
          registry_entry,
          repository_root,
          hive_state_path,
          config_loader
        )
          state = Hive::Patrol::StateStore.new(
            repository_root,
            hive_state_path: hive_state_path
          )
          reservations = state.each_reserved_occurrence.to_a
          unless reservations.length == 1
            raise Hive::ConfigError,
                  "qualification patrol schedule was not reserved"
          end
          occurrence_id =
            reservations.fetch(0).fetch("occurrence_id")
          expected_command = [
            "hive patrol",
            Shellwords.escape(@project.fetch("name")),
            "--json --occurrence-id",
            occurrence_id
          ].join(" ")
          unless dispatch.fetch(:command) == expected_command
            raise Hive::ConfigError,
                  "qualification patrol schedule was not reserved"
          end
          capture = state.occurrence_capture(occurrence_id)
          unless capture &&
                 dispatch.fetch(:project) ==
                   @project.fetch("name")
            raise Hive::ConfigError,
                  "qualification patrol schedule was not reserved"
          end
          payload = Hive::Commands::Patrol.new(
            @project.fetch("name"),
            json: true,
            project_entry: registry_entry,
            occurrence_id: occurrence_id,
            capture: capture,
            migration_authority: :legacy,
            reviewer_factory: lambda do |root, cfg, command_state|
              deterministic_reviewer_state!(command_state)
              Hive::Patrol::Reviewer.new(
                root,
                cfg: cfg,
                state: command_state,
                token_budget:
                  qualification_token_budget(root, cfg),
                agent_factory:
                  method(:qualification_agent)
              )
            end,
            token_budget_factory:
              method(:qualification_token_budget),
            clock: @clock,
            output: StringIO.new,
            config_loader: config_loader
          ).call
          unless payload.fetch("ok") == true
            raise Hive::ConfigError,
                  "qualification legacy patrol did not complete cleanly"
          end
          scheduler.complete(
            project: @project.fetch("name"),
            exit_code: Hive::ExitCodes::SUCCESS,
            envelope: payload,
            now: @clock.call
          )
        end

        # Finding identities are part of the candidate actuals. Keep the
        # production Reviewer and its parser, but make its otherwise
        # installation-random scratch directory reproducible within this
        # qualification-only sandbox.
        def deterministic_reviewer_state!(state)
          suffix = @clock.call.utc.strftime("%Y%m%dT%H%M%S")
          run_log_writer = state.method(:write_run_log)
          state.define_singleton_method(:run_dir) do |prefix|
            ensure!
            path = File.join(
              root,
              "runs",
              "#{prefix}-#{suffix}-qualification"
            )
            FileUtils.mkdir_p(path, mode: 0o700)
            path
          end
          state.define_singleton_method(:write_run_log) do |id, data|
            target = if id.start_with?("review-error-")
              "review-error-qualification"
            else
              id
            end
            run_log_writer.call(target, data)
          end
          state
        end

        def build_registry!(repository_root, hive_state_path)
          entry = {
            "hive_state_path" => hive_state_path,
            "name" => @project.fetch("name"),
            "path" => repository_root,
            "project_id" => @project.fetch("project_id"),
            "real_path" => File.realpath(repository_root),
            "registered_at" => @clock.call.utc.iso8601(6),
            "registration_id" =>
              "qualification:#{@project.fetch('project_id')}",
            "repository" => @project.fetch("repository"),
            "repository_identity" => @project.fetch("repository")
          }
          registry_path =
            File.join(@sandbox_root, "hive-home", "config.yml")
          FileUtils.mkdir_p(File.dirname(registry_path), mode: 0o700)
          write_fixture(
            registry_path,
            Hive::WorkflowPackage::CanonicalYAML.dump(
              "registered_projects" => [ entry ]
            )
          )
          loaded = Hive::Config.load_global_config(registry_path)
          registered =
            Array(loaded["registered_projects"]).fetch(0)
          unless Hive::Config.valid_registry_entry?(registered) &&
                 registered == entry
            raise Hive::ConfigError,
                  "qualification project registry is malformed"
          end
          registered.freeze
        rescue IndexError, KeyError, TypeError
          raise Hive::ConfigError,
                "qualification project registry is malformed"
        end

        def install_candidate_packages!(package_roots, hive_state_path)
          store = Hive::ModulePackage::ManagedStore.new(hive_state_path)
          package_roots.sort.each do |name, root|
            installed_at = @clock.call - INSTALL_LEAD_TIME_SEC
            validated = Hive::ModulePackage::Validator.validate!(
              root,
              expected_name: name,
              catalog_commit: package_revision(root)
            )
            resolution = package_resolution(validated)
            descriptor = validated.descriptor
            preview = Hive::ModulePackage::Preview.build(
              operation: "install",
              descriptor: descriptor,
              generation: resolution,
              current: nil,
              current_configuration: nil,
              settings: default_settings(descriptor),
              hooks: qualification_hooks(name, descriptor),
              grants: descriptor.permissions,
              now: installed_at
            )
            store.apply(
              preview,
              package_root: root,
              resolution: resolution,
              now: installed_at
            )
          end
          store
        end

        def package_revision(root)
          Hive::ModulePackage::Manifest.load(
            File.join(root, "manifest.yml")
          ).data.dig("source", "revision")
        end

        def package_resolution(validated)
          manifest = validated.manifest
          revision = manifest.data.dig("source", "revision")
          Hive::ModulePackage::CatalogClient::Resolution.new(
            name: manifest.name,
            version: manifest.version,
            type: manifest.type,
            source_commit: revision,
            catalog_commit: revision,
            source_revision: revision,
            manifest_digest: manifest.digest,
            summary: manifest.summary,
            package_path:
              "modules/#{manifest.name}/#{manifest.version}",
            descriptor: validated.descriptor
          )
        end

        def default_settings(descriptor)
          descriptor.settings.to_h do |setting|
            [ setting.fetch("name"), setting.fetch("default", nil) ]
          end
        end

        def qualification_hooks(name, descriptor)
          descriptor.hooks.to_h do |hook|
            enabled =
              name == "patrol" &&
              hook.fetch("id") == "scheduled-scan"
            [ hook.fetch("id"), enabled ]
          end
        end

        def establish_legacy_ownership!(
          repository_root,
          hive_state_path,
          store
        )
          migration = Hive::Modules::Migration::Patrols.new(
            project_root: repository_root,
            project: @project.fetch("name"),
            hive_state_path: hive_state_path,
            module_store: store,
            quiescence_probe:
              ->(_module_name, _root) { :quiescent }
          )
          outcome = migration.adopt!(now: @clock.call)
          ownership =
            Hive::Modules::Migration::Patrols.ownership_snapshot(
              repository_root,
              "patrol",
              hive_state_path: hive_state_path
            )
          unless outcome.status == "shadowing" &&
                 ownership == {
                   "owner" => "legacy",
                   "epoch" => 1,
                   "admission" => true
                 }
            raise Hive::ConfigError,
                  "qualification patrol ownership is unavailable"
          end
          migration
        end

        def prepare_scenario!(repository_root, hive_state_path)
          state = Hive::Patrol::StateStore.new(
            repository_root,
            hive_state_path: hive_state_path
          )
          case @scenario_input.operation
          when "timer_not_due", "timer_reset_reload"
            last_run_at = @clock.call.utc.iso8601
            state.update_state("last_run_at" => last_run_at)
            if @scenario_input.operation == "timer_reset_reload"
              reloaded = Hive::Patrol::StateStore.new(
                repository_root,
                hive_state_path: hive_state_path
              )
              unless reloaded.state.fetch("last_run_at") ==
                     last_run_at
                raise Hive::ConfigError,
                      "qualification patrol timer did not reload"
              end
            end
          when "same_commit", "new_commit"
            state.update_state(
              "last_scanned_sha" =>
                git!(
                  repository_root,
                  "rev-parse",
                  "HEAD"
                ).strip
            )
            commit_qualification_change!(
              repository_root
            ) if @scenario_input.operation == "new_commit"
          end
          true
        rescue KeyError
          raise Hive::ConfigError,
                "qualification patrol state is malformed"
        end

        def commit_qualification_change!(repository_root)
          write_fixture(
            File.join(
              repository_root,
              "lib",
              "qualification_change.rb"
            ),
            <<~RUBY
              module QualificationChange
                def self.applied? = true
              end
            RUBY
          )
          git!(
            repository_root,
            "add",
            "--",
            "lib/qualification_change.rb"
          )
          git!(
            repository_root,
            "-c", "user.name=Hive Qualification",
            "-c", "user.email=qualification@hive.invalid",
            "commit", "--quiet", "--no-gpg-sign",
            "--message=Add qualification change",
            env: {
              "GIT_AUTHOR_DATE" =>
                (@clock.call + 1).utc.iso8601(6),
              "GIT_COMMITTER_DATE" =>
                (@clock.call + 1).utc.iso8601(6)
            }
          )
        end

        def build_sandbox!
          repository_root = File.join(@sandbox_root, "repository")
          hive_state_path = File.join(@sandbox_root, "hive-state")
          FileUtils.mkdir_p(
            [
              File.join(repository_root, ".hive-state"),
              File.join(repository_root, "lib"),
              hive_state_path
            ],
            mode: 0o700
          )
          write_fixture(
            File.join(repository_root, ".hive-state", "config.yml"),
            Hive::WorkflowPackage::CanonicalYAML.dump(project_config)
          )
          write_fixture(
            File.join(repository_root, "lib", "qualification_demo.rb"),
            <<~RUBY
              module QualificationDemo
                def self.ready? = true
              end
            RUBY
          )
          git!(repository_root, "init", "--quiet", "--initial-branch=main")
          git!(repository_root, "add", "--", ".")
          git!(
            repository_root,
            "-c", "user.name=Hive Qualification",
            "-c", "user.email=qualification@hive.invalid",
            "commit", "--quiet", "--no-gpg-sign",
            "--message=Initial qualification fixture",
            env: {
              "GIT_AUTHOR_DATE" =>
                @clock.call.utc.iso8601(6),
              "GIT_COMMITTER_DATE" =>
                @clock.call.utc.iso8601(6)
            }
          )
          [ repository_root.freeze, hive_state_path.freeze ]
        rescue SystemCallError, IOError => error
          raise Hive::ConfigError,
                "qualification scenario sandbox could not be created: " \
                "#{error.class}"
        end

        def project_config
          {
            "default_branch" => "main",
            "hive_state_path" => "../hive-state",
            "patrol" => {
              "enabled" => true,
              "trigger" =>
                NEW_COMMIT_OPERATIONS.include?(
                  @scenario_input.operation
                ) ? "new_commits" : "timer",
              "poll_interval_sec" => 600,
              "max_agent_spawns_per_cycle" =>
                @scenario_input.operation ==
                  "capacity_deferral" ? 1 : 3,
              "max_agent_spawns_per_day" =>
                @scenario_input.operation ==
                  "quota_deferral" ? 1 : 8,
              "commands" => { "test" => "true" }
            },
            "refactor_patrol" => { "enabled" => false }
          }
        end

        def write_fixture(path, bytes)
          File.binwrite(path, bytes)
          File.chmod(0o600, path)
        end

        def git!(repository_root, *arguments, env: {})
          output, error, status = Open3.capture3(
            env,
            "git", "-C", repository_root, *arguments
          )
          return output if status.success?

          detail = error.strip.empty? ? output.strip : error.strip
          raise Hive::ConfigError,
                "qualification scenario git fixture failed: #{detail}"
        end

        def candidate_package_roots
          CANDIDATE_PACKAGES.to_h do |relative|
            path = File.join(@candidate_source_root, relative)
            stat = File.lstat(path)
            unless stat.directory? && !stat.symlink? &&
                   File.realpath(path) == path &&
                   contained?(path, @candidate_source_root) &&
                   regular_file?(
                     File.join(path, "manifest.yml")
                   )
              malformed_candidate_package!
            end
            [ File.basename(path), path.freeze ]
          rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR,
                 Errno::ELOOP
            malformed_candidate_package!
          end.freeze
        end

        def validate_sandbox!
          if contained?(@sandbox_root, @candidate_source_root) ||
             contained?(@candidate_source_root, @sandbox_root)
            raise Hive::ConfigError,
                  "qualification scenario sandbox path is unsafe"
          end
          if File.exist?(@sandbox_root) ||
             File.symlink?(@sandbox_root)
            stat = File.lstat(@sandbox_root)
            unless stat.directory? && !stat.symlink? &&
                   File.realpath(@sandbox_root) == @sandbox_root &&
                   Dir.children(@sandbox_root).empty?
              raise Hive::ConfigError,
                    "qualification scenario sandbox must be empty"
            end
          end
          %w[hive-home hive-state repository].each do |name|
            path = File.join(@sandbox_root, name)
            next unless File.exist?(path) || File.symlink?(path)

            raise Hive::ConfigError,
                  "qualification scenario sandbox is already populated"
          end
          true
        rescue Errno::ENOENT
          true
        rescue Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP
          raise Hive::ConfigError,
                "qualification scenario sandbox path is unsafe"
        end

        def validate_process_home!
          expected = File.join(@sandbox_root, "hive-home")
          actual = ENV["HIVE_HOME"].to_s
          unless !actual.empty? &&
                 Pathname.new(actual).absolute? &&
                 actual == File.expand_path(actual) &&
                 actual == expected
            raise Hive::ConfigError,
                  "qualification scenario process home is not confined"
          end
          true
        rescue ArgumentError
          raise Hive::ConfigError,
                "qualification scenario process home is not confined"
        end

        def qualification_attempts_root
          expected =
            File.join(@sandbox_root, "hive-home", "attempts", "v2")
          actual = File.expand_path(Hive::Paths.attempts_root)
          unless actual == expected
            raise Hive::ConfigError,
                  "qualification attempt store is not process-confined"
          end
          expected.freeze
        end

        def validate_scenario!
          unless
            @scenario_input.module_name == "patrol" &&
              SUPPORTED_OPERATIONS.include?(
                @scenario_input.operation
              ) &&
              (
                @scenario_input.faults -
                  SUPPORTED_FAULTS
              ).empty?
            raise Hive::ConfigError,
                  "qualification scenario is unsupported"
          end
        end

        def validate_scenario_input(value)
          unless value.is_a?(
            Hive::Modules::Migration::QualificationScenarioInput
          )
            raise Hive::ConfigError,
                  "qualification scenario input is malformed"
          end
          value
        end

        def qualification_agent(**attributes)
          QualificationAgent.new(
            output_path: attributes.fetch(:expected_output),
            operation: @scenario_input.operation,
            findings: @scenario_input.reviewer_findings
          )
        rescue KeyError
          raise Hive::ConfigError,
                "qualification reviewer fixture failed"
        end

        def qualification_token_budget(root, cfg)
          seed_daily_quota!(root) if
            @scenario_input.operation == "quota_deferral"
          QualificationTokenBudget.new(
            delegate:
              Hive::Patrol::TokenBudget.new(
                root,
                cfg: cfg,
                clock: @clock
              ),
            operation: @scenario_input.operation
          )
        end

        def seed_daily_quota!(root)
          @quota_seeded_roots ||= {}
          project_slug = File.basename(root)
          return if @quota_seeded_roots[project_slug]

          @quota_seeded_roots[project_slug] = true
          recorded = Hive::UsageDb.record!(
            agent: "qualification-fixture",
            model: "qualification-fixture",
            project_slug: project_slug,
            task_slug: "patrol-review",
            stage: "patrol-review-unmetered",
            started_at: @clock.call,
            ended_at: @clock.call,
            input: 0,
            output: 0,
            cached: 0
          )
          unless recorded
            raise Hive::ConfigError,
                  "qualification daily quota fixture is unavailable"
          end
        end

        def validate_project(value)
          unless value.is_a?(Hash) &&
                 value.keys.map(&:to_s).sort == PROJECT_KEYS
            raise Hive::ConfigError,
                  "qualification scenario project is malformed"
          end
          project = value.to_h do |key, child|
            [ key.to_s, child.to_s ]
          end
          unless project.values.all? do |child|
                   !child.empty? && child.bytesize <= 512 &&
                     !child.match?(/[\u0000-\u001f\u007f]/)
                 end
            raise Hive::ConfigError,
                  "qualification scenario project is malformed"
          end
          project.freeze
        end

        def canonical_root(value, label)
          path = canonical_path(value, label)
          stat = File.lstat(path)
          unless stat.directory? && !stat.symlink? &&
                 File.realpath(path) == path
            raise Hive::ConfigError,
                  "qualification scenario #{label} is unsafe"
          end
          path
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR,
               Errno::ELOOP
          raise Hive::ConfigError,
                "qualification scenario #{label} is unsafe"
        end

        def canonical_path(value, label)
          path = value.to_s
          pathname = Pathname.new(path)
          expanded = File.expand_path(path)
          unless pathname.absolute? && path == expanded &&
                 path.bytesize <= MAX_PATH_BYTES &&
                 path != File::SEPARATOR
            raise Hive::ConfigError,
                  "qualification scenario #{label} path is unsafe"
          end
          expanded.freeze
        rescue ArgumentError
          raise Hive::ConfigError,
                "qualification scenario #{label} path is unsafe"
        end

        def regular_file?(path)
          stat = File.lstat(path)
          stat.file? && !stat.symlink? && stat.nlink == 1
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR,
               Errno::ELOOP
          false
        end

        def contained?(path, root)
          path == root ||
            path.start_with?("#{root}#{File::SEPARATOR}")
        end

        def malformed_candidate_package!
          raise Hive::ConfigError,
                "qualification candidate module package is unavailable"
        end
      end
    end
  end
end
