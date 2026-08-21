require "open3"
require "hive/agent_limit"
require "hive/config"
require "hive/daemon/patrol_fix_operational_projection"
require "hive/daemon/patrol_fix_semantic_decision_runner"
require "hive/git_ops"
require "hive/patrol/fix_admission_outbox"
require "hive/patrol/state_store"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/migration/cutover_state"
require "hive/patrol_fix/semantic_admission"
require "hive/patrol_fix/task_manifest"
require "hive/patrol_fix/task_materializer"
require "hive/refactor_patrol/fix_admission_outbox"
require "hive/task_meta"
require "hive/workflows/registry"

module Hive
  module Daemon
    # Reconstructs committed project-local Patrol-fix outbox readers and their
    # admission factories on daemon start. Discovery remains independently
    # scheduled; these sources consume standard workflow capacity only.
    class PatrolFixRuntime
      class Source
        attr_reader :project, :entry, :port

        def initialize(entry:, port:)
          @entry = entry.freeze
          @project = entry.fetch("name")
          @port = port
        end

        def enabled?
          state = cutover_state.read
          state && state.fetch("status") == "committed" && port.enabled?
        end

        def method_missing(name, *arguments, **keywords, &block)
          return super unless port.respond_to?(name)
          port.public_send(name, *arguments, **keywords, &block)
        end

        def respond_to_missing?(name, include_private = false)
          port.respond_to?(name, include_private) || super
        end

        private

        def cutover_state
          Hive::PatrolFix::Migration::CutoverState.new(
            root: File.join(entry.fetch("hive_state_path"), "patrol-fix", "migration")
          )
        end
      end

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     decision_runner_factory: nil,
                     operational_projection: Hive::Daemon::PatrolFixOperationalProjection.new)
        @registry = registry
        @config_loader = config_loader
        @operational_projection = operational_projection
        @decision_runner_factory = decision_runner_factory || lambda do |**arguments|
          Hive::Daemon::PatrolFixSemanticDecisionRunner.new(**arguments)
        end
        @entries = @registry.call.map { |raw| normalize_entry(raw) }.freeze
        @sources = build_sources(@entries).freeze
      end

      attr_reader :sources

      # The daemon is the sole owner of source-store reads. All interfaces
      # receive these bounded project rows through OperationalSnapshot.
      def operational_projections(tasks:, now: Time.now.utc)
        task_rows = Array(tasks).group_by { |row| value(row, :project).to_s }
        @entries.to_h do |entry|
          name = entry.fetch("name")
          normalized_tasks = Array(task_rows[name]).map { |row| operational_task(row) }
          projection = begin
            @operational_projection.call(
              project: entry, config: @config_loader.call(entry.fetch("path")),
              tasks: normalized_tasks, now: now
            )
          rescue StandardError => error
            @operational_projection.unavailable(
              project: entry, tasks: normalized_tasks, now: now,
              source: "runtime", code: "runtime_projection_unavailable", error: error
            )
          end
          [ name, projection ]
        end
      end

      def admission_store(source:, **)
        Hive::PatrolFix::AdmissionStore.new(
          root: File.join(source.entry.fetch("hive_state_path"), "patrol-fix", "admissions")
        )
      end

      def semantic_admission(store:, source:, **)
        entry = source.entry
        project_root = entry.fetch("path")
        cfg = @config_loader.call(project_root)
        state = Hive::Patrol::StateStore.new(
          project_root, hive_state_path: entry.fetch("hive_state_path")
        )
        Hive::PatrolFix::SemanticAdmission.new(
          store: store, candidate_provider: candidate_provider(source),
          decision_provider: @decision_runner_factory.call(
            project_root: project_root, cfg: cfg, state: state
          ),
          current_head: -> { current_head(source) }
        )
      end

      def task_materializer(store:, source:, source_acknowledger:, **)
        entry = source.entry
        Hive::PatrolFix::TaskMaterializer.new(
          project_root: entry.fetch("path"),
          hive_state: entry.fetch("hive_state_path"), store: store,
          workflow_info: {
            descriptor: Hive::Workflows::Registry.fetch(:"patrol-fix"),
            pin: true, managed: nil, managed_cfg: {}, authored_digest: nil
          },
          source_acknowledger: source_acknowledger,
          candidate_provider: candidate_provider(source),
          current_head: -> { current_head(source) }
        )
      end

      private

      def build_sources(entries)
        entries.flat_map do |entry|
          [
            Source.new(
              entry: entry,
              port: Hive::Patrol::FixAdmissionOutbox.for_project(
                project_root: entry.fetch("path"),
                hive_state_path: entry.fetch("hive_state_path")
              )
            ),
            Source.new(
              entry: entry,
              port: Hive::RefactorPatrol::FixAdmissionOutbox.for_project(
                project_root: entry.fetch("path"),
                hive_state_path: entry.fetch("hive_state_path")
              )
            )
          ]
        end
      end

      def normalize_entry(raw)
        project_root = File.expand_path(raw.fetch("path"))
        Hive::PatrolFix.deep_freeze(
          raw.merge(
            "path" => project_root,
            "hive_state_path" => File.expand_path(
              raw.fetch("hive_state_path", ".hive-state"), project_root
            )
          )
        )
      end

      def candidate_provider(source)
        lambda do |_snapshot|
          Dir.glob(File.join(source.entry.fetch("hive_state_path"), "stages", "*", "*"))
            .filter_map do |folder|
              next unless File.directory?(folder)
              admission = Hive::TaskMeta.read_for_admission(folder)
              unless admission.status == :ok
                raise Hive::ConfigError,
                      "Patrol-fix candidate task metadata is unreadable"
              end
              next unless admission.data.fetch(:workflow).to_s == "patrol-fix"

              manifest = Hive::PatrolFix::TaskManifest.new(task_folder: folder).read
              {
                "kind" => "task", "identity" => manifest.dig("task", "slug"),
                "evidence_digest" => manifest.dig("evidence_revision", "digest"),
                "target_revision" => manifest.fetch("target_revision")
              }
            end
        end
      end

      def current_head(source)
        cfg = @config_loader.call(source.entry.fetch("path"))
        branch = cfg["default_branch"] ||
          Hive::GitOps.new(source.entry.fetch("path")).detect_default_branch
        out, error, status = Open3.capture3(
          "git", "-C", source.entry.fetch("path"), "rev-parse", branch
        )
        unless status.success? && out.strip.match?(/\A[0-9a-f]{40}\z/)
          raise Hive::GitError,
                "cannot resolve Patrol-fix admission head: #{error.to_s.strip[0, 256]}"
        end
        out.strip
      end

      def operational_task(row)
        attrs = value(row, :marker_attrs)
        held = if attrs.is_a?(Hash) && Hive::AgentLimit.held?(value(row, :marker), attrs)
          {
            "provider" => Hive::AgentLimit.held_provider(attrs),
            "retry_after" => Hive::AgentLimit.retry_after_time(attrs)&.iso8601
          }
        end
        {
          "slug" => value(row, :slug).to_s,
          "stage" => value(row, :stage).to_s,
          "patrol_fix" => value(row, :patrol_fix),
          "held" => held
        }
      end

      def value(row, key)
        return row.public_send(key) if row.respond_to?(key)
        return row[key] if row.respond_to?(:key?) && row.key?(key)
        return row[key.to_s] if row.respond_to?(:key?) && row.key?(key.to_s)

        nil
      end
    end
  end
end
