require "fileutils"
require "json"
require "stringio"
require "time"
require "hive/atomic_file"
require "hive/commands/refactor_patrol"
require "hive/config"
require "hive/daemon/refactor_patrol_scheduler"
require "hive/errors"
require "hive/modules/adapters/architecture_patrol"
require "hive/modules/event_ledger"
require "hive/modules/migration/patrol_evidence"
require "hive/modules/migration/shadow_comparator"
require "hive/refactor_patrol/action_runner"
require "hive/refactor_patrol/architecture_intake_transitions"
require "hive/refactor_patrol/architecture_project_binding"
require "hive/refactor_patrol/canonical_action_catalog"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/policy"
require "hive/refactor_patrol/pr_manifest"
require "hive/refactor_patrol/repository_ownership"
require "hive/refactor_patrol/reviewer"

module Hive
  module Modules
    module Migration
      # Drives one deterministic Architecture Patrol qualification occurrence
      # through the production intake, scheduler, command, lifecycle, event,
      # adapter, and shadow-comparison boundaries. Only genuinely external
      # behavior is injected: reviewer output, fixer output, and repository
      # identity resolution.
      class QualificationArchitectureScenario
        Result = Data.define(
          :job_id, :aggregate, :occurrence, :event,
          :comparison, :runs
        )

        COMMAND_OUTPUT_MUTEX = Mutex.new
        private_constant :COMMAND_OUTPUT_MUTEX

        def initialize(
          project:, manifest:, configuration:,
          review_agent_runner:, fixer:,
          repository_identity_resolver:,
          clock: -> { Time.now.utc },
          output: StringIO.new,
          canonical_state_home: nil
        )
          @project = project_value(project)
          @manifest = manifest_value(manifest)
          @configuration = configuration
          @review_agent_runner = callable!(
            review_agent_runner,
            "architecture qualification reviewer"
          )
          @fixer = fixer_value(fixer)
          @repository_identity_resolver = callable!(
            repository_identity_resolver,
            "architecture qualification repository identity resolver"
          )
          @clock = callable!(
            clock,
            "architecture qualification clock"
          )
          unless output.respond_to?(:write)
            raise Hive::ConfigError,
                  "architecture qualification output is unavailable"
          end
          @output = output
          @canonical_state_home = File.expand_path(
            canonical_state_home ||
              File.join(
                @project.fetch("hive_state_path"),
                "module-runtime", "qualification"
              )
          )
          validate_configuration!
          validate_binding!
        end

        def call
          publish_manifest!
          enroll!
          runs = [ drive!(:discovery) ]
          aggregate = store.read_job(job_id)
          runs << drive!(:action) unless aggregate.fetch("complete")
          aggregate = store.read_job(job_id)
          unless aggregate.fetch("complete")
            raise Hive::ConfigError,
                  "architecture qualification lifecycle did not close"
          end

          occurrence_id = aggregate.fetch("occurrence_id")
          event = final_event!(occurrence_id)
          # A successful outbox drain retires the live journal record. The
          # event's validated final capture is the durable occurrence proof.
          occurrence = final_capture!(
            event,
            occurrence_id
          )
          comparison = compare_shadow!(event, occurrence)
          Result.new(
            job_id: job_id.freeze,
            aggregate: immutable(aggregate),
            occurrence: immutable(occurrence),
            event: immutable(event),
            comparison: immutable(comparison),
            runs: immutable(runs)
          ).freeze
        end

        private

        def project_value(project)
          unless project.is_a?(Hash)
            raise Hive::ConfigError,
                  "architecture qualification project is malformed"
          end
          required = %w[
            name project_id path hive_state_path repository_identity
          ]
          unless required.all? do |key|
            project[key].is_a?(String) &&
              !project[key].empty?
          end
            raise Hive::ConfigError,
                  "architecture qualification project is malformed"
          end

          immutable(
            project.merge(
              "path" => File.expand_path(project.fetch("path")),
              "hive_state_path" =>
                File.expand_path(project.fetch("hive_state_path"))
            )
          )
        end

        def manifest_value(manifest)
          immutable(
            Hive::RefactorPatrol::PrManifest.validate!(
              JSON.parse(JSON.generate(manifest))
            )
          )
        rescue JSON::GeneratorError, TypeError
          raise Hive::ConfigError,
                "architecture qualification manifest is malformed"
        end

        def callable!(value, label)
          return value if value.respond_to?(:call)

          raise Hive::ConfigError, "#{label} is unavailable"
        end

        def fixer_value(fixer)
          return fixer if fixer.respond_to?(:attempt)

          raise Hive::ConfigError,
                "architecture qualification fixer is unavailable"
        end

        def validate_configuration!
          unless
            @configuration.respond_to?(:settings) &&
              @configuration.respond_to?(:grants) &&
              @configuration.respond_to?(:digest) &&
              @configuration.respond_to?(:generation)
            raise Hive::ConfigError,
                  "architecture qualification module configuration is malformed"
          end
          unless
            @configuration.settings["shadow_mode"] == true &&
              @configuration.settings["dry_run"] == false
            raise Hive::ConfigError,
                  "architecture qualification requires a live legacy run " \
                  "and shadow module comparison"
          end
        end

        def validate_binding!
          cfg = config
          Hive::RefactorPatrol::PrManifest.validate!(
            @manifest,
            expected_job_id: job_id,
            registration: @project.fetch("name"),
            default_branch: cfg.fetch("default_branch")
          )
          Hive::RefactorPatrol::ArchitectureProjectBinding.from_entry!(
            entry: @project,
            source: @manifest.fetch("source")
          )
        rescue KeyError
          raise Hive::ConfigError,
                "architecture qualification project configuration is incomplete"
        end

        def publish_manifest!
          FileUtils.mkdir_p(manifest_root, mode: 0o700)
          Hive::AtomicFile.write(
            manifest_path,
            "#{JSON.pretty_generate(@manifest)}\n",
            mode: 0o600
          )
          Hive::AtomicFile.fsync_directory(manifest_root)
        end

        def enroll!
          Hive::RefactorPatrol::ArchitectureIntakeTransitions.new(
            config_loader: config_loader
          ).enqueue(
            entry: @project,
            store: store,
            manifest: @manifest,
            policy: Hive::RefactorPatrol::Policy.capture(
              config,
              now: now
            ),
            now: now
          )
        end

        def drive!(phase)
          scheduler = build_scheduler
          candidate = scheduler.candidates(now: now).find do |item|
            item.fetch(:job_id) == job_id &&
              item.fetch(:action_phase, :discovery).to_sym == phase
          end
          unless candidate
            raise Hive::ConfigError,
                  "architecture qualification #{phase} candidate is unavailable"
          end

          dispatch = scheduler.reserve(candidate, now: now)
          envelope = invoke_command(dispatch, phase)
          completion = scheduler.complete(
            dispatch_token: dispatch.fetch(:dispatch_token),
            exit_code:
              envelope.is_a?(Hash) && envelope["ok"] == false ? 1 : 0,
            envelope: envelope,
            now: now
          )
          status = completion.fetch(:status)
          expected =
            phase == :discovery ?
              %i[closed classified] : [ :closed ]
          unless expected.include?(status)
            raise Hive::ConfigError,
                  "architecture qualification #{phase} ended as #{status}"
          end

          {
            "phase" => phase.to_s,
            "status" => status.to_s,
            "envelope" => envelope
          }
        rescue StandardError
          scheduler&.cancel(
            dispatch,
            reason: "qualification_scenario_error",
            now: now
          ) if dispatch
          raise
        end

        def build_scheduler
          Hive::Daemon::RefactorPatrolScheduler.new(
            registry: -> { [ @project ] },
            config_loader: config_loader,
            job_store_factory: ->(_root) { store },
            repository_ownership: repository_ownership,
            owner: scheduler_owner,
            migration_authority: :legacy
          )
        end

        def invoke_command(dispatch, phase)
          command = Hive::Commands::RefactorPatrol.new(
            @project.fetch("name"),
            json: true,
            job_manifest: manifest_path,
            actions: phase == :action,
            result_file:
              dispatch.dig(:dispatch_token, :result_path),
            reviewer_factory: method(:build_reviewer),
            action_runner_factory: lambda do |root, cfg|
              build_action_runner(
                root,
                cfg,
                occurrence_id:
                  dispatch.dig(
                    :dispatch_token,
                    :occurrence_id
                  )
              )
            end,
            job_store_factory: ->(_root) { store },
            repository_ownership: repository_ownership,
            project_entry: @project,
            occurrence_id:
              dispatch.dig(:dispatch_token, :occurrence_id),
            heartbeat_clock: @clock,
            config_loader: config_loader
          )
          COMMAND_OUTPUT_MUTEX.synchronize do
            previous = $stdout
            $stdout = @output
            command.call
          ensure
            $stdout = previous
          end
        end

        def build_reviewer(root, cfg, state)
          aggregate = store.read_job(job_id)
          Hive::RefactorPatrol::Reviewer.new(
            root,
            cfg: cfg,
            state: state,
            agent_runner: @review_agent_runner,
            source_pr: aggregate.fetch("source"),
            read_only: true,
            audit_context: {
              "job_id" => job_id,
              "analysis_sha" =>
                aggregate.fetch("analysis_sha"),
              "source_pr" => aggregate.fetch("source")
            }
          )
        end

        def build_action_runner(root, cfg, occurrence_id:)
          Hive::RefactorPatrol::ActionRunner.new(
            root,
            cfg: cfg,
            hive_state_path:
              @project.fetch("hive_state_path"),
            job_store: store,
            fixer: @fixer,
            repository_ownership: repository_ownership,
            canonical_action_catalog:
              canonical_action_catalog,
            registration: @project.fetch("name"),
            occurrence_id: occurrence_id,
            clock: @clock,
            config_loader: config_loader
          )
        end

        def final_event!(occurrence_id)
          events = event_ledger.all.select do |event|
            event.dig("source", "type") ==
              "legacy_architecture_patrol_completion" &&
              event.dig("source", "id") ==
                occurrence_id
          end
          unless events.length == 1
            raise Hive::ConfigError,
                  "architecture qualification final event is unavailable"
          end
          events.fetch(0)
        end

        def final_capture!(event, occurrence_id)
          capture =
            Hive::Modules::Migration::PatrolCapture.from_h(
              event.dig(
                "payload",
                "legacy_mutator_capture"
              )
            )
          unless
            capture.occurrence_id == occurrence_id &&
              capture.outcome_class == "complete" &&
              capture.outcome.fetch("complete") == true
            raise Hive::ConfigError,
                  "architecture qualification occurrence did not finalize"
          end
          capture.to_h
        rescue Hive::ConfigError, KeyError
          raise Hive::ConfigError,
                "architecture qualification occurrence did not finalize"
        end

        def compare_shadow!(event, occurrence)
          hook = event.dig("payload", "target_hook")
          Hive::Modules::Adapters::ArchitecturePatrol.new.call(
            project: @project,
            hook_id: hook,
            event: event,
            configuration: @configuration
          )
          records =
            shadow_comparator
            .each_record("architecture-patrol")
            .to_a
            .select do |record|
              record.dig(
                "legacy_capture",
                "occurrence_id"
              ) == occurrence.fetch("occurrence_id")
            end
          unless records.length == 1
            raise Hive::ConfigError,
                  "architecture qualification shadow comparison is unavailable"
          end
          records.fetch(0)
        end

        def store
          Hive::RefactorPatrol::JobStore.new(
            @project.fetch("path"),
            hive_state_path:
              @project.fetch("hive_state_path"),
            project: @project
          )
        end

        def repository_ownership
          @repository_ownership ||=
            Hive::RefactorPatrol::RepositoryOwnership.new(
              registry: -> { [ @project ] },
              config_loader: config_loader,
              identity_resolver:
                @repository_identity_resolver
            )
        end

        def canonical_action_catalog
          @canonical_action_catalog ||=
            Hive::RefactorPatrol::CanonicalActionCatalog.new(
              state_home: @canonical_state_home,
              registry: -> { [ @project ] },
              job_store_factory: ->(_root) { store },
              clock: @clock
            )
        end

        def event_ledger
          Hive::Modules::EventLedger.new(
            root: File.join(
              @project.fetch("hive_state_path"),
              "module-runtime"
            )
          )
        end

        def shadow_comparator
          Hive::Modules::Migration::ShadowComparator.new(
            root: File.join(
              @project.fetch("hive_state_path"),
              "module-runtime", "migration", "shadow"
            ),
            clock: @clock
          )
        end

        def config
          @config ||= Hive::Config.load(
            @project.fetch("path")
          )
        end

        def config_loader
          @config_loader ||= ->(_root) { config }
        end

        def now
          value = @clock.call
          time =
            value.is_a?(Time) ?
              value : Time.iso8601(value.to_s)
          time.utc
        rescue ArgumentError, TypeError
          raise Hive::ConfigError,
                "architecture qualification clock is malformed"
        end

        def scheduler_owner
          @scheduler_owner ||=
            "qualification-architecture-#{Process.pid}"
        end

        def job_id = @manifest.fetch("job_id")

        def manifest_root
          File.join(
            @project.fetch("hive_state_path"),
            "refactor_patrol", "v2", "manifests"
          )
        end

        def manifest_path
          File.join(manifest_root, "#{job_id}.json")
        end

        def immutable(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, child), copy|
              copy[immutable(key)] = immutable(child)
            end.freeze
          when Array
            value.map { |child| immutable(child) }.freeze
          when String
            value.dup.freeze
          else
            value.freeze
          end
        end
      end
    end
  end
end
