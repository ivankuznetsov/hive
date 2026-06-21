require "hive"
require "hive/workflows/coding"
require "hive/workflows/content"

module Hive
  module Workflows
    class UnknownWorkflow < Hive::Error
      # The offending workflow id and the registered-workflow list travel as
      # structured fields, not only baked into the interpolated message, so an
      # agent / TUI can render a diagnosis without regex-parsing `message`.
      # Mirrors the sibling `New::UnregisteredProjectWorkflow#value` pattern —
      # this is the most agent-facing error in the workflow stack (USAGE,
      # surfaced by `--workflow`).
      attr_reader :value, :valid

      def initialize(message, value: nil, valid: nil)
        super(message)
        @value = value
        @valid = valid
      end

      # A bad `--workflow` name is a do-not-retry usage error, not a generic
      # crash — classify it like InvalidTaskPath/WrongStage so automated
      # callers see USAGE (64), not GENERIC (1).
      def exit_code
        Hive::ExitCodes::USAGE
      end
    end

    module Registry
      WORKFLOWS = {
        coding: Coding::DESCRIPTOR,
        content: Content::DESCRIPTOR
      }.freeze

      module_function

      def fetch(id)
        workflows.fetch(id) do
          known = workflows.keys.map(&:inspect).join(", ")
          raise UnknownWorkflow.new(
            "unknown workflow #{id.inspect}; known workflows: #{known}",
            value: id,
            valid: workflows.keys.map(&:to_s)
          )
        end
      end

      # Uses the bare `:coding` symbol, NOT Hive::Workflows::CODING_ID: this
      # method is called at load time from stages.rb:12 (DIRS) before
      # workflows.rb has defined CODING_ID — registry.rb is required by
      # workflows.rb, so the constant is not yet reachable here. The literal is
      # the deliberate break in the require cycle, equal to CODING_ID by
      # construction (workflows_test pins them equal).
      def default
        fetch(:coding)
      end

      def all
        workflows.values
      end

      def ids
        workflows.keys
      end

      # The registry resolves workflows across THREE tiers, lowest precedence
      # first (see #workflows): built-in `WORKFLOWS` ◁ runtime `registrations`
      # ◁ project `project_registrations`. `merge` is last-wins, so a project
      # descriptor shadows a runtime one, which shadows a built-in — though in
      # practice register! REFUSES any id already present in a lower tier (the
      # collision guard below), so the precedence only governs lookup order, not
      # silent overrides.
      #
      # Two distinct overlay tiers exist on purpose:
      #   - project_registrations — PRODUCTION overlay. Owner-authored
      #     descriptors discovered from `<hive_state_path>/workflows/*.yml` and
      #     installed by Hive::Workflows::Project.load!; swapped per active
      #     project and reset with reset_project_registrations!.
      #   - registrations — TEST-injection overlay. The only writer is the test
      #     helper `with_registered_workflow` (register!(project: false)); reset
      #     with reset_runtime_registrations!. Kept separate from the project
      #     tier so a test fixture and a real project overlay can coexist without
      #     one clobbering the other (collapsing them would break that
      #     isolation), and so production code paths touch ONLY the project tier.
      def register!(descriptor, source_path: nil, project: false)
        id = descriptor.id.to_sym
        target = project ? project_registrations : registrations
        if workflows.key?(id)
          raise Hive::ConfigError,
                "#{registration_label(id, source_path)} collides with registered workflow #{id.inspect}"
        end

        target[id] = descriptor
        reset_union_cache
        descriptor
      end

      def reset_project_registrations!
        return if project_registrations.empty?

        project_registrations.clear
        reset_union_cache
      end

      def reset_runtime_registrations!
        return if registrations.empty?

        registrations.clear
        reset_union_cache
      end

      # Three-tier precedence, last-wins: built-in ◁ runtime(test) ◁ project.
      # See register! for why the two overlay tiers are kept distinct.
      #
      # Memoized: a single merged hash is rebuilt only when a registration
      # changes (reset_union_cache clears @workflows). Each `fetch`/`all`/`ids`
      # call — and register!'s own `key?` check — used to allocate two fresh
      # merged hashes, which adds up across a cross-project status scan.
      def workflows
        @workflows ||= WORKFLOWS.merge(registrations).merge(project_registrations)
      end

      def registrations
        @registrations ||= {}
      end

      def project_registrations
        @project_registrations ||= {}
      end

      def registration_label(id, source_path)
        return "workflow descriptor #{source_path}" if source_path

        "workflow #{id.inspect}"
      end

      def reset_union_cache
        # Drop the local merged-union memo (registrations changed) alongside the
        # derived stage-dir caches in Hive::Workflows.
        @workflows = nil
        Hive::Workflows.reset_union_cache! if Hive::Workflows.respond_to?(:reset_union_cache!)
      end
    end
  end
end
