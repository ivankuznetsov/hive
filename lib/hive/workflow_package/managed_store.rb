require "fileutils"
require "json"
require "securerandom"
require "hive/atomic_file"
require "hive/task_meta"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/configuration"
require "hive/workflow_package/mutation_lock"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/transaction"
require "hive/workflow_package/validator"

module Hive
  module WorkflowPackage
    class ManagedStore
      LOCK_FILE = "honeycomb.lock.json".freeze
      # Tri-state CAS baseline: this sentinel means "do not compare", nil
      # means "the selection must still be absent", and a hash means "the
      # selection must still match this exact generation and configuration".
      NO_SELECTION_CHECK = Object.new.freeze
      private_constant :NO_SELECTION_CHECK

      attr_reader :hive_state_path, :workflows_dir

      def initialize(hive_state_path)
        @hive_state_path = File.expand_path(hive_state_path)
        @workflows_dir = File.join(@hive_state_path, "workflows")
      end

      def place_generation(package_root, resolution)
        validate_resolution!(resolution)
        result = Validator.validate!(package_root, expected_name: resolution.name,
                                     expected_manifest_digest: resolution.manifest_digest)
        executable_paths = trusted_executable_paths(result.manifest, package_root)
        destination = generation_path(resolution.name, resolution.source_commit)
        if File.directory?(destination)
          verification = verify_generation(resolution.name, resolution.source_commit, resolution.manifest_digest)
          if repairable_generation_modes?(verification)
            harden_generation!(destination, result.manifest, executable_paths)
            return destination if verify_generation(
              resolution.name, resolution.source_commit, resolution.manifest_digest
            ).valid?
          end
        end

        refuse_authored_collision!(resolution.name)
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        staging = File.join(
          File.dirname(destination), ".staging-#{resolution.name}-#{Process.pid}-#{SecureRandom.hex(4)}"
        )
        FileUtils.mkdir_p(staging, mode: 0o700)
        result.manifest.file_entries.map { |entry| entry.fetch("path") }.push(result.manifest.file_name).each do |relative|
          source = File.join(package_root, relative)
          target = File.join(staging, relative)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          FileUtils.copy_file(source, target)
        end
        harden_generation!(staging, result.manifest, executable_paths)
        File.rename(staging, destination)
        destination
      ensure
        remove_generation_tree(staging) if staging && File.exist?(staging)
      end

      def place_configuration(configuration)
        raise Hive::ConfigError, "managed workflow configuration is invalid" unless configuration.is_a?(Configuration)

        path = configuration_path(configuration.data.dig("generation", "name"), configuration.digest)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        return path if File.file?(path) && File.binread(path) == configuration.bytes

        Hive::AtomicFile.write(path, configuration.bytes, mode: 0o600)
        path
      end

      def activate(resolution, configuration: nil, cfg: {}, commit: nil,
                   expected_current: NO_SELECTION_CHECK)
        validate_resolution!(resolution)
        raise Hive::ConfigError, "managed generation is not installed" unless File.directory?(generation_path(resolution.name, resolution.source_commit))

        configuration ||= default_configuration(resolution, cfg: cfg)
        validate_configuration_generation!(configuration, resolution)
        place_configuration(configuration)

        MutationLock.with_lock(workflows_dir) do
          reconcile_unlocked!
          current = selected_unlocked(resolution.name, cfg: cfg)
          selection_changed =
            if expected_current.equal?(NO_SELECTION_CHECK)
              false
            elsif expected_current.nil?
              !current.nil?
            else
              !same_selection?(current, expected_current)
            end
          if selection_changed
            raise Hive::ConcurrentRunError.new("managed workflow selection changed after validation")
          end
          Transaction.activate(
            lock_path: lock_path(resolution.name), workflows_dir: workflows_dir,
            new_lock: lock_data(resolution, configuration), commit: commit
          )
        end
      end

      def remove_selection(name, commit: nil, expected_current: nil)
        MutationLock.with_lock(workflows_dir) do
          reconcile_unlocked!
          raise Hive::ConfigError, "managed workflow #{name.inspect} is not selected" unless File.file?(lock_path(name))
          if expected_current && !same_selection?(selected_unlocked(name), expected_current)
            raise Hive::ConcurrentRunError.new("managed workflow selection changed after validation")
          end

          Transaction.remove(lock_path: lock_path(name), workflows_dir: workflows_dir, commit: commit)
        end
      end

      # The optional block supplies project config only when a legacy v1 lock
      # needs a compatibility snapshot. Current locks and absent selections do
      # not need to read or validate project config.
      def selected(name, cfg: {}, &legacy_cfg_loader)
        result = nil
        with_stable_read do
          result = selected_unlocked(name, cfg: cfg, &legacy_cfg_loader)
        end
        result
      end

      # Validation and other strict no-write probes cannot use #selected:
      # with_stable_read creates the mutation lock and reconciles an interrupted
      # transaction before taking its shared read. This variant validates the
      # selected pointer and configuration without creating, restoring, or
      # clearing any managed-state path.
      def selected_read_only(name, cfg: {}, &legacy_cfg_loader)
        selected_unlocked(name, cfg: cfg, &legacy_cfg_loader)
      end

      def selections(cfg: {})
        result = []
        with_stable_read do
          result = Dir.glob(File.join(workflows_dir, "*", LOCK_FILE)).sort.filter_map do |path|
            name = File.basename(File.dirname(path))
            selected_unlocked(name, cfg: cfg)
          rescue Hive::ConfigError => e
            warn "hive: skipping managed workflow #{name.inspect}: #{e.message}"
            nil
          end
        end
        result
      end

      # Read-only inspection mirrors the module store's diagnostic boundary:
      # atomically published lock/configuration bytes may be inspected without
      # reconciling an interrupted mutation or creating lock files.
      def inspect_selected(name, cfg: {})
        selected_unlocked(name, cfg: cfg)
      end

      def inspect_selections(cfg: {})
        return [] unless File.directory?(workflows_dir)

        Dir.glob(File.join(workflows_dir, "*", LOCK_FILE)).sort.filter_map do |path|
          name = File.basename(File.dirname(path))
          selected_unlocked(name, cfg: cfg)
        end
      end

      def generation_path(name, commit)
        validate_name_and_commit!(name, commit)
        File.join(workflows_dir, name, "versions", commit)
      end

      def configuration_path(name, digest)
        raise Hive::ConfigError, "invalid managed workflow configuration digest" unless Configuration::SHA256.match?(digest.to_s)

        File.join(workflows_dir, name.to_s, "configurations", "#{digest}.json")
      end

      def configuration(name, digest, cfg: {})
        bytes = File.binread(configuration_path(name, digest))
        parsed = Configuration.load(bytes)
        raise Hive::ConfigError, "managed workflow configuration digest is tampered" unless parsed.digest == digest
        raise Hive::ConfigError, "managed workflow configuration name does not match" unless parsed.data.dig("generation", "name") == name.to_s
        parsed
      rescue Errno::ENOENT, Errno::EACCES, IOError
        legacy = legacy_configuration_from_selected_lock(name, cfg: cfg)
        return legacy if legacy && legacy.digest == digest

        raise Hive::ConfigError, "managed workflow configuration #{digest} is unavailable"
      end

      def verify_generation(name, commit, manifest_digest)
        Validator.validate(generation_path(name, commit), expected_name: name,
                           expected_manifest_digest: manifest_digest)
      end

      def workflow(name, commit, manifest_digest, configuration_digest: nil, cfg: {}, verify_profiles: true)
        result = Validator.validate!(generation_path(name, commit), expected_name: name,
                                     expected_manifest_digest: manifest_digest)
        return result.workflow unless configuration_digest

        config = begin
          configuration(name, configuration_digest, cfg: cfg)
        rescue Hive::ConfigError => error
          candidates = [ cfg, {} ].uniq.map do |candidate_cfg|
            legacy_configuration_for(
              name: name, commit: commit, manifest_digest: manifest_digest,
              workflow: result.workflow, manifest: result.manifest, cfg: candidate_cfg
            )
          end
          candidates.find { |candidate| candidate.digest == configuration_digest } || raise(error)
        end
        generation = config.data.fetch("generation")
        unless generation == {
          "name" => name.to_s, "source_commit" => commit.to_s, "manifest_digest" => manifest_digest.to_s
        }
          raise Hive::ConfigError, "managed workflow configuration is pinned to another generation"
        end
        config.apply(result.workflow, cfg: cfg, verify_profiles: verify_profiles)
      end

      def manifest(name, commit, manifest_digest)
        Validator.validate!(generation_path(name, commit), expected_name: name,
                            expected_manifest_digest: manifest_digest).manifest
      end

      def task_references(name = nil)
        MutationLock.with_lock(workflows_dir, shared: true) { task_references_unlocked(name) }
      end

      def inspect_task_references(name = nil)
        task_references_unlocked(name)
      end

      # Task creation uses this boundary to make a legacy v1 lock's derived
      # configuration durable before task metadata can pin its digest. The
      # project config is part of that derivation because agent-profile
      # overrides (notably agents.<name>.bin) are fingerprinted in the snapshot.
      def with_stable_selection(name, cfg: {})
        with_stable_read do
          yield selected_unlocked(name, cfg: cfg, persist_legacy_configuration: true)
        end
      end

      def task_references_unlocked(name = nil)
        pattern = File.join(hive_state_path, "stages", "*", "*", Hive::TaskMeta::FILENAME)
        Dir.glob(pattern).filter_map do |path|
          read = Hive::TaskMeta.read_for_admission(File.dirname(path))
          unless read.status == :ok
            raise Hive::ConfigError, "managed cleanup cannot safely read #{path}: #{read.error || read.status}"
          end
          meta = read.data
          provenance = %i[workflow_commit workflow_manifest_digest workflow_configuration_digest]
          next unless provenance.any? { |key| meta[key] }
          unless meta[:workflow] && meta[:workflow_commit] && meta[:workflow_manifest_digest]
            raise Hive::ConfigError, "managed cleanup found incomplete managed workflow provenance in #{path}"
          end
          next if name && meta[:workflow] != name

          { name: meta[:workflow], commit: meta[:workflow_commit], digest: meta[:workflow_manifest_digest],
            configuration_digest: meta[:workflow_configuration_digest] }
        end
      end

      # Returns commits retained by task pins. Unselected and unpinned
      # generations are deleted.
      def cleanup_unreferenced(name)
        MutationLock.with_lock(workflows_dir) do
          reconcile_unlocked!
          references = task_references_unlocked(name)
          retained = references.map { |entry| entry.fetch(:commit) }.uniq
          retained_configurations = references.filter_map { |entry| entry[:configuration_digest] }.uniq
          selection = selected_unlocked(name)
          active = selection&.fetch("source_commit")
          active_configuration = selection&.fetch("configuration_digest")
          keep = retained + Array(active)
          versions = File.join(workflows_dir, name, "versions")
          Dir.glob(File.join(versions, "*")).each do |path|
            remove_generation_tree(path) unless keep.include?(File.basename(path))
          end
          keep_configurations = retained_configurations + Array(active_configuration)
          Dir.glob(File.join(workflows_dir, name, "configurations", "*.json")).each do |path|
            FileUtils.rm_f(path) unless keep_configurations.include?(File.basename(path, ".json"))
          end
          retained
        end
      end

      def reconcile!
        MutationLock.with_lock(workflows_dir) { reconcile_unlocked! }
      end

      def reconcile_unlocked!
        journal = TransactionJournal.new(workflows_dir)
        data = journal.read
        return false unless data

        Transaction.new(lock_path: data.fetch("lock_path"), workflows_dir: workflows_dir).reconcile!
      end

      def lock_path(name)
        unless Hive::Workflows::DescriptorParser::SAFE_SLUG.match?(name.to_s)
          raise Hive::ConfigError, "invalid managed workflow name"
        end

        File.join(workflows_dir, name.to_s, LOCK_FILE)
      end

      private

      def same_selection?(current, expected)
        current && current.fetch("source_commit") == expected.fetch("source_commit") &&
          current.fetch("manifest_digest") == expected.fetch("manifest_digest") &&
          current.fetch("configuration_digest") == expected.fetch("configuration_digest")
      end

      def with_stable_read
        MutationLock.with_lock(workflows_dir) { reconcile_unlocked! }
        MutationLock.with_lock(workflows_dir, shared: true) { yield }
      end

      def selected_unlocked(name, cfg: {}, persist_legacy_configuration: false, &legacy_cfg_loader)
        return nil unless Hive::Workflows::DescriptorParser::SAFE_SLUG.match?(name.to_s)

        data = JSON.parse(File.read(lock_path(name)))
        validate_lock!(data, expected_name: name)
        if data["schema_version"] == 1
          legacy_cfg = legacy_cfg_loader ? legacy_cfg_loader.call : cfg
          legacy = legacy_configuration_from_selected_lock(name, cfg: legacy_cfg)
          raise Hive::ConfigError, "managed workflow legacy configuration is unavailable" unless legacy

          place_configuration(legacy) if persist_legacy_configuration
          data = data.merge("configuration_digest" => legacy.digest, "legacy_lock_schema" => 1)
        end
        data
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError
        raise Hive::ConfigError, "managed workflow lock for #{name.inspect} is malformed"
      end

      def lock_data(resolution, configuration)
        {
          "schema_version" => 2,
          "name" => resolution.name,
          "version" => resolution.version,
          "catalog_commit" => resolution.catalog_commit,
          "source_commit" => resolution.source_commit,
          "manifest_digest" => resolution.manifest_digest,
          "summary" => resolution.summary,
          "permissions" => resolution.permissions,
          "configuration_digest" => configuration.digest
        }
      end

      def validate_lock!(data, expected_name:)
        required_v1 = %w[catalog_commit manifest_digest name permissions schema_version source_commit summary version]
        required_v2 = required_v1 + [ "configuration_digest" ]
        expected = data.is_a?(Hash) && data["schema_version"] == 1 ? required_v1 : required_v2
        unless data.is_a?(Hash) && data.keys.sort == expected.sort && [ 1, 2 ].include?(data["schema_version"]) && data["name"] == expected_name
          raise Hive::ConfigError, "managed workflow lock for #{expected_name.inspect} is malformed"
        end
        validate_name_and_commit!(data["name"], data["source_commit"])
        unless Manifest::SHA256.match?(data["manifest_digest"].to_s) && RegistryClient::FULL_SHA.match?(data["catalog_commit"].to_s)
          raise Hive::ConfigError, "managed workflow lock provenance is malformed"
        end
        return if data["schema_version"] == 1

        config = configuration(data.fetch("name"), data.fetch("configuration_digest"))
        generation = config.data.fetch("generation")
        unless generation["source_commit"] == data["source_commit"] && generation["manifest_digest"] == data["manifest_digest"]
          raise Hive::ConfigError, "managed workflow lock configuration provenance is malformed"
        end
      end

      def legacy_configuration_from_selected_lock(name, cfg: {})
        data = JSON.parse(File.read(lock_path(name)))
        return unless data.is_a?(Hash) && data["schema_version"] == 1

        validate_lock!(data, expected_name: name)
        result = Validator.validate!(generation_path(name, data.fetch("source_commit")), expected_name: name,
                                     expected_manifest_digest: data.fetch("manifest_digest"))
        legacy_configuration_for(
          name: name, commit: data.fetch("source_commit"), manifest_digest: data.fetch("manifest_digest"),
          workflow: result.workflow, manifest: result.manifest, cfg: cfg
        )
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, IOError
        nil
      end

      def legacy_configuration_for(name:, commit:, manifest_digest:, workflow:, manifest:, cfg: {})
        Configuration.build(
          workflow,
          generation: { "name" => name.to_s, "source_commit" => commit.to_s,
                        "manifest_digest" => manifest_digest.to_s },
          cfg: cfg,
          overrides: Configuration.legacy_overrides(workflow),
          runtime_metadata: manifest.data.fetch("x-hive", {})
        )
      end

      def validate_resolution!(resolution)
        validate_name_and_commit!(resolution.name, resolution.source_commit)
        unless RegistryClient::FULL_SHA.match?(resolution.catalog_commit.to_s) &&
               Manifest::SHA256.match?(resolution.manifest_digest.to_s)
          raise Hive::ConfigError, "managed workflow resolution provenance is malformed"
        end
      end

      def default_configuration(resolution, cfg: {})
        result = Validator.validate!(generation_path(resolution.name, resolution.source_commit),
                                     expected_name: resolution.name,
                                     expected_manifest_digest: resolution.manifest_digest)
        Configuration.build(
          result.workflow,
          generation: {
            "name" => resolution.name,
            "source_commit" => resolution.source_commit,
            "manifest_digest" => resolution.manifest_digest
          },
          cfg: cfg,
          runtime_metadata: result.manifest.data.fetch("x-hive", {})
        )
      end

      def validate_configuration_generation!(configuration, resolution)
        expected = {
          "name" => resolution.name,
          "source_commit" => resolution.source_commit,
          "manifest_digest" => resolution.manifest_digest
        }
        unless configuration.data.fetch("generation") == expected
          raise Hive::ConfigError, "managed workflow configuration does not match package generation"
        end
      end

      def validate_name_and_commit!(name, commit)
        unless Hive::Workflows::DescriptorParser::SAFE_SLUG.match?(name.to_s) && RegistryClient::FULL_SHA.match?(commit.to_s)
          raise Hive::ConfigError, "invalid managed workflow name or immutable commit"
        end
      end

      def remove_generation_tree(path)
        Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.each do |entry|
          File.chmod(File.directory?(entry) ? 0o700 : 0o600, entry) unless File.symlink?(entry)
        rescue Errno::ENOENT
          nil
        end
        File.chmod(0o700, path) if File.exist?(path)
        FileUtils.rm_rf(path)
      end

      def repairable_generation_modes?(verification)
        verification.valid? || verification.errors.all? do |error|
          error.rule_id == "x-hive.tool_not_executable"
        end
      end

      def harden_generation!(root, manifest, executable_paths)
        executable_paths = executable_paths.to_h { |path| [ path, true ] }
        manifest.file_entries.map { |entry| entry.fetch("path") }.push(manifest.file_name).each do |relative|
          File.chmod(executable_paths.key?(relative) ? 0o555 : 0o444, File.join(root, relative))
        end
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
           .select { |path| File.directory?(path) && !File.symlink?(path) }
           .sort_by { |path| -path.count(File::SEPARATOR) }
           .each { |path| File.chmod(0o555, path) }
        File.chmod(0o555, root)
      end

      def trusted_executable_paths(manifest, package_root)
        declared_tools = manifest.data.dig("x-hive", "tools")
        return declared_tools.map { |tool| tool.fetch("path") } if declared_tools

        manifest.file_entries.filter_map do |entry|
          relative = entry.fetch("path")
          relative if File.executable?(File.join(package_root, relative))
        end
      end

      def refuse_authored_collision!(name)
        descriptor = File.join(workflows_dir, "#{name}.yml")
        raise Hive::ConfigError, "managed workflow #{name.inspect} collides with an authored workflow" if File.exist?(descriptor)
      end
    end
  end
end
