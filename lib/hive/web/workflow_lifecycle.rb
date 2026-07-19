require "stringio"

require "hive/commands/workflow"
require "hive/commands/workflow/install"
require "hive/commands/workflow/list"
require "hive/commands/workflow/remove"
require "hive/commands/workflow/update"
require "hive/config"
require "hive/workflow_package/managed_store"
require "hive/workflow_package/registry_client"

module Hive
  module Web
    # Project-scoped adapter over the same workflow command objects the CLI
    # uses. Managed mutations are deliberately two-step: callers first run a
    # dry-run disclosure, then pass its signed identity back as `expected`.
    # PreviewRegistry re-fetches and rejects a changed candidate before any
    # project write; update/remove also bind the selected generation.
    class WorkflowLifecycle
      class PreviewChanged < Hive::Error; end

      SelectionIdentity = Data.define(:source_commit, :manifest_digest) do
        def self.from_selection(selection)
          new(
            source_commit: selection.fetch("source_commit"),
            manifest_digest: selection.fetch("manifest_digest")
          )
        end

        def self.from_update_preview(preview)
          new(
            source_commit: preview.fetch("from_commit"),
            manifest_digest: preview.fetch("from_manifest_digest")
          )
        end

        def to_expected
          { "source_commit" => source_commit, "manifest_digest" => manifest_digest }
        end
      end

      class PreviewRegistry
        IDENTITY_FIELDS = %w[name version catalog_commit source_commit manifest_digest].freeze
        UPDATE_IDENTITY_FIELDS = %w[name source_commit manifest_digest].freeze

        def initialize(delegate, expected, identity_fields: IDENTITY_FIELDS)
          missing = identity_fields.reject do |field|
            expected.key?(field) && !expected.fetch(field).to_s.empty?
          end
          unless missing.empty?
            raise ArgumentError, "reviewed candidate identity is missing: #{missing.join(', ')}"
          end

          @delegate = delegate
          @expected = expected
          @identity_fields = identity_fields
        end

        def fetch(source, destination:)
          resolution = @delegate.fetch(source, destination: destination)
          changed = @identity_fields.any? do |field|
            expected = @expected.fetch(field)
            resolution.public_send(field) != expected
          end
          if changed
            raise PreviewChanged,
                  "the reviewed Honeycomb package changed; preview it again before applying"
          end

          resolution
        end
      end

      def initialize(registry_client_factory: -> { Hive::WorkflowPackage::RegistryClient.new },
                     committer: nil)
        @registry_client_factory = registry_client_factory
        @committer = committer
      end

      def templates
        Hive::Commands::Workflow.available_templates
      end

      def list(project)
        default = Hive::Config.load(project_root(project)).fetch("default_workflow", "coding").to_s
        Hive::Commands::Workflow::List.new(
          project_root: project_root(project), json: true, stdout: StringIO.new
        ).call!.fetch("workflows").map do |row|
          row.merge("default" => row.fetch("name") == default && row.fetch("selection") != "retained")
        end
      end

      def scaffold(project, id:, template:)
        Hive::Commands::Workflow.new(
          "new", id, project_root: project_root(project), json: true,
          stdout: StringIO.new, template: template
        ).call!
      end

      def preview_install(project, source:)
        Hive::Commands::Workflow::Install.new(
          source, project_root: project_root(project), json: true, dry_run: true,
          stdout: StringIO.new, registry_client: registry_client, committer: @committer
        ).call!
      end

      def install(project, source:, expected:)
        Hive::Commands::Workflow::Install.new(
          source, project_root: project_root(project), json: true, yes: true,
          stdout: StringIO.new, committer: @committer,
          registry_client: PreviewRegistry.new(registry_client, candidate_identity(expected))
        ).call!
      end

      def preview_update(project, name:)
        before = selected!(project, name)
        payload = Hive::Commands::Workflow::Update.new(
          name, project_root: project_root(project), json: true, dry_run: true,
          stdout: StringIO.new, registry_client: registry_client, committer: @committer
        ).call!
        after = selected!(project, name)
        unless same_selection?(before, after) && before.fetch("source_commit") == payload.fetch("from_commit")
          raise PreviewChanged, "the managed workflow selection changed; preview the update again"
        end

        payload.merge("from_manifest_digest" => before.fetch("manifest_digest"))
      end

      def update(project, name:, expected:, allow_escalation:)
        current = SelectionIdentity.from_update_preview(expected).to_expected
        Hive::Commands::Workflow::Update.new(
          name, project_root: project_root(project), json: true, yes: true,
          allow_escalation: allow_escalation, stdout: StringIO.new,
          registry_client: PreviewRegistry.new(registry_client, {
            "name" => name,
            "source_commit" => expected.fetch("to_commit"),
            "manifest_digest" => expected.fetch("manifest_digest")
          }, identity_fields: PreviewRegistry::UPDATE_IDENTITY_FIELDS),
          expected_current: current, committer: @committer
        ).call!
      end

      def preview_remove(project, name:)
        Hive::Commands::Workflow::Remove.new(
          name, project_root: project_root(project), json: true, dry_run: true,
          stdout: StringIO.new, committer: @committer
        ).call!
      end

      def remove(project, name:, expected:)
        Hive::Commands::Workflow::Remove.new(
          name, project_root: project_root(project), json: true, yes: true,
          stdout: StringIO.new,
          expected_current: SelectionIdentity.from_selection(expected).to_expected,
          committer: @committer
        ).call!
      end

      private

      def project_root(project)
        File.expand_path(project.fetch("path"))
      end

      def registry_client
        @registry_client_factory.call
      end

      def store(project)
        root = project_root(project)
        state = File.expand_path(Hive::Config.load(root).fetch("hive_state_path"), root)
        Hive::WorkflowPackage::ManagedStore.new(state)
      end

      def selected!(project, name)
        store(project).selected(name) ||
          raise(Hive::Commands::Workflow::OwnershipError, "managed workflow #{name.inspect} is not installed")
      end

      def same_selection?(left, right)
        SelectionIdentity.from_selection(left) == SelectionIdentity.from_selection(right)
      end

      def candidate_identity(expected)
        {
          "name" => expected.fetch("name"),
          "version" => expected.fetch("version"),
          "catalog_commit" => expected.fetch("catalog_commit"),
          "source_commit" => expected.fetch("source_commit"),
          "manifest_digest" => expected.fetch("manifest_digest")
        }
      end
    end
  end
end
