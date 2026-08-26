require "open3"
require "hive/config"
require "hive/daemon/patrol_fix_candidate_inventory"
require "hive/daemon/patrol_fix_semantic_decision_runner"
require "hive/git_ops"
require "hive/patrol/state_store"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/semantic_admission"
require "hive/patrol_fix/task_materializer"
require "hive/workflows/registry"

module Hive
  module Daemon
    # Reconstructs one project-local admission source per project. Discovery
    # remains independently scheduled; admission consumes standard workflow
    # capacity only.
    class PatrolFixRuntime
      class Source
        attr_reader :project, :entry, :store

        def initialize(entry:, store:)
          @entry = entry.freeze
          @project = entry.fetch("name")
          @store = store
        end
      end

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     decision_runner_factory: nil)
        @registry = registry
        @config_loader = config_loader
        @decision_runner_factory = decision_runner_factory || lambda do |**arguments|
          Hive::Daemon::PatrolFixSemanticDecisionRunner.new(**arguments)
        end
        @admission_stores = {}
      end

      # The project registry is mutable while the one production daemon stays
      # alive. Rebuild the lightweight project sources on each scheduler tick
      # so a newly registered project does not need a daemon restart.
      def sources
        build_sources(entries).freeze
      end

      def semantic_admission(store:, source:, **)
        entry = source.entry
        project_root = entry.fetch("path")
        cfg = @config_loader.call(project_root)
        Hive::PatrolFix::SemanticAdmission.new(
          store: store, candidate_provider: candidate_provider(source),
          decision_provider: lambda do |input|
            state = Hive::Patrol::StateStore.new(
              project_root, hive_state_path: entry.fetch("hive_state_path")
            )
            @decision_runner_factory.call(
              project_root: project_root, cfg: cfg, state: state
            ).call(input)
          end,
          current_head: -> { current_head(source) }
        )
      end

      def run_semantic_decision(project:, source_name:, occurrence_id:, reservation_id:,
                                now: Time.now.utc)
        source = sources.find { |item| item.project.to_s == project.to_s }
        raise Hive::ConfigError, "Patrol Fix semantic admission source is unavailable" unless source

        store = source.store
        record = store.fetch(occurrence_id)
        unless record&.dig("source", "engine") == source_name.to_s
          raise Hive::ConfigError, "Patrol Fix semantic admission source changed"
        end
        semantic_admission(store: store, source: source).run_reserved(
          occurrence_id: occurrence_id, reservation_id: reservation_id, now: now
        )
      end

      def task_materializer(store:, source:, **)
        entry = source.entry
        Hive::PatrolFix::TaskMaterializer.new(
          project_root: entry.fetch("path"),
          hive_state: entry.fetch("hive_state_path"), store: store,
          workflow_info: {
            descriptor: Hive::Workflows::Registry.fetch(:"patrol-fix"),
            pin: true, managed: nil, managed_cfg: {}, authored_digest: nil
          },
          candidate_provider: candidate_provider(source),
          current_head: -> { current_head(source) }
        )
      end

      private

      def entries
        @registry.call.map { |raw| normalize_entry(raw) }.freeze
      end

      def build_sources(entries)
        active_roots = {}
        sources = entries.map do |entry|
          admission_root = File.join(
            entry.fetch("hive_state_path"), "patrol-fix", "admissions"
          )
          active_roots[admission_root] = true
          Source.new(
            entry: entry,
            store: (@admission_stores[admission_root] ||=
              Hive::PatrolFix::AdmissionStore.new(root: admission_root))
          )
        end
        @admission_stores.delete_if { |root, _store| !active_roots.key?(root) }
        sources
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
        inventory = Hive::Daemon::PatrolFixCandidateInventory.new(
          hive_state_path: source.entry.fetch("hive_state_path")
        )
        ->(snapshot) { inventory.call(snapshot) }
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
    end
  end
end
