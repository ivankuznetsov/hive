require "fileutils"
require "json"
require "securerandom"
require "hive/atomic_file"
require "hive/task_meta"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/mutation_lock"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/transaction"
require "hive/workflow_package/validator"

module Hive
  module WorkflowPackage
    class ManagedStore
      LOCK_FILE = "honeycomb.lock.json".freeze

      attr_reader :hive_state_path, :workflows_dir

      def initialize(hive_state_path)
        @hive_state_path = File.expand_path(hive_state_path)
        @workflows_dir = File.join(@hive_state_path, "workflows")
      end

      def place_generation(package_root, resolution)
        validate_resolution!(resolution)
        result = Validator.validate!(package_root, expected_name: resolution.name,
                                     expected_manifest_digest: resolution.manifest_digest)
        destination = generation_path(resolution.name, resolution.source_commit)
        return destination if File.directory?(destination) &&
                              verify_generation(resolution.name, resolution.source_commit,
                                                resolution.manifest_digest).valid?

        refuse_authored_collision!(resolution.name)
        staging = File.join(workflows_dir, ".staging-#{resolution.name}-#{Process.pid}-#{SecureRandom.hex(4)}")
        FileUtils.mkdir_p(staging, mode: 0o700)
        result.manifest.data.fetch("files").map { |entry| entry.fetch("path") }.push(Manifest::FILE_NAME).each do |relative|
          source = File.join(package_root, relative)
          target = File.join(staging, relative)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          FileUtils.copy_file(source, target)
        end
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        File.rename(staging, destination)
        destination
      ensure
        FileUtils.rm_rf(staging) if staging && File.exist?(staging)
      end

      def activate(resolution, commit: nil, expected_current: nil)
        validate_resolution!(resolution)
        raise Hive::ConfigError, "managed generation is not installed" unless File.directory?(generation_path(resolution.name, resolution.source_commit))

        MutationLock.with_lock(workflows_dir) do
          reconcile_unlocked!
          if expected_current
            current = selected_unlocked(resolution.name)
            unless current && current.fetch("source_commit") == expected_current.fetch("source_commit") &&
                   current.fetch("manifest_digest") == expected_current.fetch("manifest_digest")
              raise Hive::ConcurrentRunError.new("managed workflow selection changed after validation")
            end
          end
          Transaction.activate(
            lock_path: lock_path(resolution.name), workflows_dir: workflows_dir,
            new_lock: lock_data(resolution), commit: commit
          )
        end
      end

      def remove_selection(name, commit: nil)
        MutationLock.with_lock(workflows_dir) do
          reconcile_unlocked!
          raise Hive::ConfigError, "managed workflow #{name.inspect} is not selected" unless File.file?(lock_path(name))

          Transaction.remove(lock_path: lock_path(name), workflows_dir: workflows_dir, commit: commit)
        end
      end

      def selected(name)
        result = nil
        with_stable_read { result = selected_unlocked(name) }
        result
      end

      def selections
        result = []
        with_stable_read do
          result = Dir.glob(File.join(workflows_dir, "*", LOCK_FILE)).sort.filter_map do |path|
            selected_unlocked(File.basename(File.dirname(path)))
          rescue Hive::ConfigError
            nil
          end
        end
        result
      end

      def generation_path(name, commit)
        validate_name_and_commit!(name, commit)
        File.join(workflows_dir, name, "versions", commit)
      end

      def verify_generation(name, commit, manifest_digest)
        Validator.validate(generation_path(name, commit), expected_name: name,
                           expected_manifest_digest: manifest_digest)
      end

      def workflow(name, commit, manifest_digest)
        Validator.validate!(generation_path(name, commit), expected_name: name,
                            expected_manifest_digest: manifest_digest).workflow
      end

      def manifest(name, commit, manifest_digest)
        Validator.validate!(generation_path(name, commit), expected_name: name,
                            expected_manifest_digest: manifest_digest).manifest
      end

      def task_references(name = nil)
        MutationLock.with_lock(workflows_dir, shared: true) { task_references_unlocked(name) }
      end

      def with_stable_selection(name)
        with_stable_read { yield selected_unlocked(name) }
      end

      def task_references_unlocked(name = nil)
        pattern = File.join(hive_state_path, "stages", "*", "*", Hive::TaskMeta::FILENAME)
        Dir.glob(pattern).filter_map do |path|
          read = Hive::TaskMeta.read_for_admission(File.dirname(path))
          unless read.status == :ok
            raise Hive::ConfigError, "managed cleanup cannot safely read #{path}: #{read.error || read.status}"
          end
          meta = read.data
          next unless meta[:workflow_commit] && meta[:workflow_manifest_digest]
          next if name && meta[:workflow] != name

          { name: meta[:workflow], commit: meta[:workflow_commit], digest: meta[:workflow_manifest_digest] }
        end
      end

      # Returns commits retained by task pins. Unselected and unpinned
      # generations are deleted.
      def cleanup_unreferenced(name)
        MutationLock.with_lock(workflows_dir) do
          reconcile_unlocked!
          retained = task_references_unlocked(name).map { |entry| entry.fetch(:commit) }.uniq
          active = selected_unlocked(name)&.fetch("source_commit")
          keep = retained + Array(active)
          versions = File.join(workflows_dir, name, "versions")
          Dir.glob(File.join(versions, "*")).each do |path|
            FileUtils.rm_rf(path) unless keep.include?(File.basename(path))
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

      def with_stable_read
        MutationLock.with_lock(workflows_dir) { reconcile_unlocked! }
        MutationLock.with_lock(workflows_dir, shared: true) { yield }
      end

      def selected_unlocked(name)
        return nil unless Hive::Workflows::DescriptorParser::SAFE_SLUG.match?(name.to_s)

        data = JSON.parse(File.read(lock_path(name)))
        validate_lock!(data, expected_name: name)
        data
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError
        raise Hive::ConfigError, "managed workflow lock for #{name.inspect} is malformed"
      end

      def lock_data(resolution)
        {
          "schema_version" => 1,
          "name" => resolution.name,
          "version" => resolution.version,
          "catalog_commit" => resolution.catalog_commit,
          "source_commit" => resolution.source_commit,
          "manifest_digest" => resolution.manifest_digest,
          "summary" => resolution.summary,
          "permissions" => resolution.permissions
        }
      end

      def validate_lock!(data, expected_name:)
        required = %w[catalog_commit manifest_digest name permissions schema_version source_commit summary version]
        unless data.is_a?(Hash) && data.keys.sort == required && data["schema_version"] == 1 && data["name"] == expected_name
          raise Hive::ConfigError, "managed workflow lock for #{expected_name.inspect} is malformed"
        end
        validate_name_and_commit!(data["name"], data["source_commit"])
        unless Manifest::SHA256.match?(data["manifest_digest"].to_s) && RegistryClient::FULL_SHA.match?(data["catalog_commit"].to_s)
          raise Hive::ConfigError, "managed workflow lock provenance is malformed"
        end
      end

      def validate_resolution!(resolution)
        validate_name_and_commit!(resolution.name, resolution.source_commit)
        unless RegistryClient::FULL_SHA.match?(resolution.catalog_commit.to_s) &&
               Manifest::SHA256.match?(resolution.manifest_digest.to_s)
          raise Hive::ConfigError, "managed workflow resolution provenance is malformed"
        end
      end

      def validate_name_and_commit!(name, commit)
        unless Hive::Workflows::DescriptorParser::SAFE_SLUG.match?(name.to_s) && RegistryClient::FULL_SHA.match?(commit.to_s)
          raise Hive::ConfigError, "invalid managed workflow name or immutable commit"
        end
      end

      def refuse_authored_collision!(name)
        descriptor = File.join(workflows_dir, "#{name}.yml")
        raise Hive::ConfigError, "managed workflow #{name.inspect} collides with an authored workflow" if File.exist?(descriptor)
      end
    end
  end
end
