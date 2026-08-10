require "fileutils"
require "tmpdir"
require "hive/module_package/normalizer"
require "hive/workflow_package/managed_store"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/runtime_policy"
require "hive/workflow_package/validator"
require "hive/workflows/project"

module Hive
  module ModulePackage
    # Compatibility boundary for workflow-shaped Honeycombs. It normalizes
    # candidates into the module contract while deliberately retaining the
    # established workflow store, transaction, task pins, and loader as the
    # sole executable authority for the remaining 0.x line.
    class WorkflowCompatibility
      Candidate = Data.define(:descriptor, :resolution, :validated, :package_root) do
        def initialize(**values)
          super(**values)
          freeze
        end
      end

      def initialize(store:, project_config:, cache_reset: -> { Hive::Workflows::Project.reset! })
        @store = store
        @project_config = project_config
        @cache_reset = cache_reset
      end

      def fetch(source:, destination:, registry_client:)
        resolution = registry_client.fetch(source, destination: destination)
        candidate_for(
          package_root: destination, resolution: resolution,
          descriptor: nil
        )
      end

      def candidate(package_root:, resolution:)
        if resolution.respond_to?(:descriptor)
          adopt(module_resolution: resolution, package_root: package_root)
        else
          candidate_for(
            package_root: package_root, resolution: resolution,
            descriptor: nil
          )
        end
      end

      def adopt(module_resolution:, package_root:)
        resolution = workflow_resolution(module_resolution, package_root)
        candidate_for(
          package_root: package_root, resolution: resolution,
          descriptor: module_resolution.descriptor
        )
      end

      def selected(name)
        @store.selected(name, cfg: @project_config)
      end

      def configuration(name, digest)
        @store.configuration(name, digest, cfg: @project_config)
      end

      def activate!(candidate:, configuration:, expected_current:, commit:, admit: true)
        if admit
          admit_runtime!(
            candidate.validated.workflow, candidate.package_root,
            configuration: configuration
          )
        end
        @store.place_generation(candidate.package_root, candidate.resolution)
        begin
          @store.activate(
            candidate.resolution, configuration: configuration,
            cfg: @project_config, expected_current: expected_current,
            commit: commit
          )
        rescue StandardError => error
          cleanup_failed_activation(candidate.resolution.name, error)
        end
        @store.selected(candidate.resolution.name, cfg: @project_config)
      end

      def remove_selection!(name:, expected_current:, commit:)
        @store.remove_selection(
          name, expected_current: expected_current, commit: commit
        )
        true
      end

      def cleanup_unreferenced(name)
        @store.cleanup_unreferenced(name)
      end

      def reset_cache!
        @cache_reset.call
      end

      def admit_runtime!(workflow, package_root, configuration:)
        configured = configuration ? configuration.apply(workflow, cfg: @project_config) : workflow
        Dir.mktmpdir("hive-workflow-admission-") do |root|
          task_folder = File.join(root, "task")
          FileUtils.mkdir_p(task_folder)
          Hive::WorkflowPackage::RuntimePolicy.admit_workflow!(
            configured, task_folder: task_folder,
            policy_dir: File.join(root, "policy"), package_root: package_root
          )
        end
      end

      private

      def candidate_for(package_root:, resolution:, descriptor:)
        validated = Hive::WorkflowPackage::Validator.validate!(
          package_root, expected_name: resolution.name,
          expected_manifest_digest: resolution.manifest_digest
        )
        normalized = Hive::ModulePackage::Normalizer.from_honeycomb(
          validated.manifest, resolution: resolution
        )
        validate_normalized!(normalized, resolution, validated)
        if descriptor && descriptor.to_h != normalized.to_h
          raise Hive::ConfigError,
                "normalized Honeycomb descriptor does not match the reviewed module resolution"
        end
        Candidate.new(
          descriptor: normalized, resolution: resolution,
          validated: validated, package_root: File.expand_path(package_root)
        )
      end

      def workflow_resolution(module_resolution, package_root)
        validated = Hive::WorkflowPackage::Validator.validate!(
          package_root, expected_name: module_resolution.name,
          expected_manifest_digest: module_resolution.manifest_digest
        )
        manifest = validated.manifest
        Hive::WorkflowPackage::RegistryClient::Resolution.new(
          name: module_resolution.name, version: module_resolution.version,
          source_commit: module_resolution.source_commit,
          catalog_commit: module_resolution.catalog_commit,
          source_revision: module_resolution.source_revision,
          manifest_digest: module_resolution.manifest_digest,
          hive_min_version: module_resolution.descriptor.hive_min_version,
          summary: manifest.summary, permissions: manifest.permissions
        ).freeze
      rescue KeyError
        raise Hive::ConfigError, "reviewed Honeycomb metadata is incomplete"
      end

      def validate_normalized!(descriptor, resolution, validated)
        valid = descriptor.legacy_honeycomb &&
          descriptor.name == resolution.name &&
          descriptor.version == resolution.version &&
          descriptor.manifest_digest == resolution.manifest_digest &&
          descriptor.catalog_commit == resolution.catalog_commit &&
          descriptor.workflows == [
            {
              "id" => resolution.name,
              "descriptor" => validated.manifest.descriptor
            }
          ] &&
          descriptor.hooks.empty?
        return true if valid

        raise Hive::ConfigError,
              "reviewed Honeycomb cannot be represented by the workflow compatibility contract"
      end

      def cleanup_failed_activation(name, original_error)
        @store.cleanup_unreferenced(name)
      rescue StandardError => cleanup_error
        warn(
          "hive workflow: activation failed with #{original_error.class}: #{original_error.message}; " \
          "candidate cleanup also failed with #{cleanup_error.class}: #{cleanup_error.message}"
        )
      ensure
        raise original_error
      end
    end
  end
end
