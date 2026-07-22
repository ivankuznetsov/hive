require "fileutils"
require "json"
require "securerandom"
require "time"
require "hive/atomic_file"
require "hive/module_package/configuration"
require "hive/module_package/transaction"
require "hive/module_package/validator"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/mutation_lock"

module Hive
  module ModulePackage
    class ManagedStore
      SELECTION_FILE = "selection.json".freeze
      HOOKS_FILE = "hooks.json".freeze

      attr_reader :hive_state_path, :modules_dir

      def initialize(hive_state_path)
        @hive_state_path = File.expand_path(hive_state_path)
        @modules_dir = File.join(@hive_state_path, "modules")
      end

      def apply(preview, package_root:, resolution:, health_check: nil, failpoint: nil, commit: nil, now: Time.now.utc)
        validate_resolution!(resolution)
        raise Hive::ConfigError, "module preview generation does not match resolution" unless same_generation?(
          preview.configuration.generation, resolution
        )
        health_check ||= ->(_path, _configuration) { true }
        with_mutation do
          reconcile_unlocked!(resolution.name)
          current = selected_unlocked(resolution.name, include_tombstone: true)
          preview.verify!(digest: preview.digest, current: current, now: now)
          generation_existed = File.directory?(generation_path(resolution.name, resolution.source_commit))
          placed = place_generation_unlocked(package_root, resolution)
          place_configuration_unlocked(preview.configuration)
          transaction = Transaction.new(module_path(resolution.name))
          transaction.begin!(candidate_path: placed, candidate_created: !generation_existed)
          failpoint&.call(:prepared)
          selection = activation_selection(current, resolution, preview.configuration, preview.digest, now)
          hooks = activation_hooks(current, preview.configuration, now)
          transaction.provisional!(
            selection_bytes: canonical(selection), hooks_bytes: canonical(hooks)
          )
          failpoint&.call(:pointer_provisional)
          begin
            healthy = health_check.call(placed, preview.configuration)
            raise Hive::ConfigError, "module activation health check failed" unless healthy
          rescue Hive::ConfigError
            raise
          rescue StandardError
            raise Hive::ConfigError, "module activation health check failed"
          end
          transaction.health_validated!
          failpoint&.call(:health_validated)
          cleanup_generations_unlocked!(resolution.name, selection)
          commit&.call
          transaction.commit!
          clear_failed_activation(resolution.name)
          cleanup_configurations_unlocked!(resolution.name, selection)
          selection
        rescue StandardError => e
          begin
            transaction&.rollback!
          ensure
            write_failed_activation(resolution.name, e, now)
          end
          raise
        end
      end

      def selected(name, include_tombstone: false)
        result = nil
        Hive::WorkflowPackage::MutationLock.with_lock(modules_dir) { reconcile_all_unlocked! }
        Hive::WorkflowPackage::MutationLock.with_lock(modules_dir, shared: true) do
          result = selected_unlocked(name, include_tombstone: include_tombstone)
        end
        result
      end

      def selections(include_tombstones: false)
        Hive::WorkflowPackage::MutationLock.with_lock(modules_dir) { reconcile_all_unlocked! }
        Hive::WorkflowPackage::MutationLock.with_lock(modules_dir, shared: true) do
          Dir.glob(File.join(modules_dir, "*", SELECTION_FILE)).sort.filter_map do |path|
            selected_unlocked(File.basename(File.dirname(path)), include_tombstone: include_tombstones)
          end
        end
      end

      # Inspection deliberately bypasses transaction reconciliation and the
      # mutation lock. Selections and configurations are published through
      # atomic renames, so readers either see the old bytes or the new bytes.
      # This distinction is what lets doctor/status describe an interrupted
      # activation without healing it or creating lock files as a side effect.
      def inspect_selection(name, include_tombstone: false)
        selected_unlocked(name, include_tombstone: include_tombstone)
      end

      def inspect_selections(include_tombstones: false)
        module_names.filter_map do |name|
          inspect_selection(name, include_tombstone: include_tombstones)
        end
      end

      def module_names
        return [] unless File.directory?(modules_dir)

        Dir.children(modules_dir).sort.select do |name|
          Manifest::NAME.match?(name) && File.directory?(File.join(modules_dir, name))
        end
      rescue SystemCallError => e
        raise Hive::ConfigError, "module installation state is unreadable: #{e.message}"
      end

      def inspect_hooks(name)
        bytes = File.binread(File.join(runtime_path(name), HOOKS_FILE))
        data = JSON.parse(bytes)
        unless bytes == canonical(data) && data.is_a?(Hash) && data["schema_version"] == 1 &&
               data["hooks"].is_a?(Hash)
          raise Hive::ConfigError, "module hook runtime state is malformed"
        end
        data
      rescue Errno::ENOENT
        { "schema_version" => 1, "configuration_digest" => nil, "updated_at" => nil, "hooks" => {} }
      rescue JSON::ParserError, EncodingError
        raise Hive::ConfigError, "module hook runtime state is malformed"
      end

      def configuration(name, digest)
        bytes = File.binread(configuration_path(name, digest))
        configuration = Configuration.load(bytes)
        raise Hive::ConfigError, "module configuration digest is tampered" unless configuration.digest == digest
        raise Hive::ConfigError, "module configuration belongs to another module" unless configuration.generation.fetch("name") == name.to_s
        configuration
      rescue Errno::ENOENT, Errno::EACCES, IOError
        raise Hive::ConfigError, "module configuration is missing or unreadable"
      end

      def disable(name, now: Time.now.utc, commit: nil)
        mutate_state(name, commit: commit) do |selection|
          raise Hive::ConfigError, "module is not installed" unless selection.fetch("installed")
          selection.merge("enabled" => false, "epoch" => selection.fetch("epoch") + 1)
        end
      end

      def enable(name, now: Time.now.utc, commit: nil)
        mutate_state(name, commit: commit) do |selection|
          raise Hive::ConfigError, "module is not installed" unless selection.fetch("installed")
          selection.merge(
            "enabled" => true, "epoch" => selection.fetch("epoch") + 1,
            "high_water_at" => now.utc.iso8601(6)
          )
        end
      end

      def uninstall(name, now: Time.now.utc, commit: nil)
        mutate_state(name, commit: commit) do |selection|
          active = selection["active"]
          selection.merge(
            "installed" => false, "enabled" => false, "active" => nil,
            "previous" => active || selection["previous"],
            "epoch" => selection.fetch("epoch") + 1, "high_water_at" => now.utc.iso8601(6)
          )
        end
      end

      # Migration rollback may restore the previously reviewed executable and
      # configuration, but never runtime ledgers. The active-generation CAS
      # prevents a stale rollback request from overwriting a later operator
      # update, and Transaction keeps the selection and hook bindings atomic.
      def restore_previous(name, expected_active:, now: Time.now.utc)
        with_mutation do
          reconcile_unlocked!(name)
          current = selected_unlocked(name, include_tombstone: true)
          unless current&.fetch("installed") && current.fetch("active") == expected_active
            raise Hive::ConfigError, "module rollback active generation changed"
          end
          previous = current.fetch("previous", nil)
          return current unless previous

          configuration = self.configuration(name, previous.fetch("configuration_digest"))
          restored = current.merge(
            "active" => previous, "previous" => current.fetch("active"),
            "epoch" => current.fetch("epoch") + 1,
            "receipt_digest" => ::Digest::SHA256.hexdigest(
              canonical(
                "operation" => "migration_rollback", "name" => name.to_s,
                "active" => previous, "previous" => current.fetch("active"),
                "restored_at" => now.utc.iso8601(6)
              )
            )
          )
          hooks = activation_hooks(current, configuration, now)
          transaction = Transaction.new(module_path(name))
          transaction.begin!(
            candidate_path: generation_path(name, previous.fetch("source_commit")),
            candidate_created: false
          )
          transaction.provisional!(selection_bytes: canonical(restored), hooks_bytes: canonical(hooks))
          transaction.health_validated!
          cleanup_generations_unlocked!(name, restored)
          cleanup_configurations_unlocked!(name, restored)
          transaction.commit!
          restored
        rescue StandardError
          transaction&.rollback!
          raise
        end
      end

      def generation_path(name, commit)
        validate_name_commit!(name, commit)
        File.join(module_path(name), "generations", commit.to_s)
      end

      def generation_commits(name)
        Dir.glob(File.join(module_path(name), "generations", "*")).select { |path| File.directory?(path) }
           .map { |path| File.basename(path) }
      end

      def configuration_path(name, digest)
        raise Hive::ConfigError, "invalid module configuration digest" unless Manifest::SHA256.match?(digest.to_s)
        File.join(module_path(name), "configurations", "#{digest}.json")
      end

      def runtime_path(name) = File.join(module_path(name), "runtime")
      def failed_activation_path(name) = File.join(module_path(name), "diagnostics", "failed-activation.json")

      def reconcile!
        with_mutation { reconcile_all_unlocked! }
      end

      private

      def with_mutation(&block)
        Hive::WorkflowPackage::MutationLock.with_lock(modules_dir, &block)
      end

      def module_path(name)
        raise Hive::ConfigError, "invalid module name" unless Manifest::NAME.match?(name.to_s)
        File.join(modules_dir, name.to_s)
      end

      def selection_path(name) = File.join(module_path(name), SELECTION_FILE)

      def selected_unlocked(name, include_tombstone: false)
        path = selection_path(name)
        bytes = File.binread(path)
        data = JSON.parse(bytes)
        raise Hive::ConfigError, "module selection is not canonical" unless bytes == canonical(data)
        validate_selection!(data, name)
        return nil if !include_tombstone && !data.fetch("installed")
        data
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError, EncodingError
        raise Hive::ConfigError, "module selection for #{name.inspect} is malformed"
      end

      def place_generation_unlocked(package_root, resolution)
        result = Validator.validate!(
          package_root, expected_name: resolution.name,
          expected_manifest_digest: resolution.manifest_digest,
          catalog_commit: resolution.catalog_commit
        )
        destination = generation_path(resolution.name, resolution.source_commit)
        if File.directory?(destination)
          verify = Validator.validate!(
            destination, expected_name: resolution.name,
            expected_manifest_digest: resolution.manifest_digest,
            catalog_commit: resolution.catalog_commit
          )
          return destination if verify.manifest.digest == resolution.manifest_digest
        end
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        staging = File.join(File.dirname(destination), ".staging-#{Process.pid}-#{SecureRandom.hex(4)}")
        FileUtils.mkdir_p(staging, mode: 0o700)
        ([ result.manifest.file_name ] + result.manifest.file_entries.map { |entry| entry.fetch("path") }).each do |relative|
          target = File.join(staging, relative)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          FileUtils.copy_file(File.join(package_root, relative), target)
        end
        harden_generation!(staging)
        File.rename(staging, destination)
        Hive::AtomicFile.fsync_directory(File.dirname(destination))
        destination
      ensure
        remove_generation_tree(staging) if staging && File.exist?(staging)
      end

      def harden_generation!(root)
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.reverse_each do |path|
          next if %w[. ..].include?(File.basename(path))
          File.chmod(File.directory?(path) ? 0o555 : 0o444, path)
        end
        File.chmod(0o555, root)
      end

      def place_configuration_unlocked(configuration)
        path = configuration_path(configuration.generation.fetch("name"), configuration.digest)
        if File.file?(path)
          existing = Configuration.load(File.binread(path))
          raise Hive::ConfigError, "module configuration digest collision" unless existing.bytes == configuration.bytes
          return path
        end
        Hive::AtomicFile.write(path, configuration.bytes, mode: 0o400)
        path
      end

      def activation_selection(current, resolution, configuration, receipt_digest, now)
        active = generation_identity(resolution, configuration)
        previous = current && current["active"] unless current&.dig("active", "source_commit") == resolution.source_commit
        {
          "schema_version" => 1, "name" => resolution.name,
          "installed" => true, "enabled" => current ? current.fetch("enabled") : true,
          "active" => active, "previous" => previous || current&.fetch("previous", nil),
          "epoch" => current ? current.fetch("epoch") + 1 : 1,
          "high_water_at" => current&.fetch("high_water_at", nil) || now.utc.iso8601(6),
          "receipt_digest" => receipt_digest
        }
      end

      def generation_identity(resolution, configuration)
        {
          "version" => resolution.version, "catalog_commit" => resolution.catalog_commit,
          "source_commit" => resolution.source_commit, "manifest_digest" => resolution.manifest_digest,
          "configuration_digest" => configuration.digest
        }
      end

      def activation_hooks(current, configuration, now)
        old = read_hooks(current&.fetch("name", nil))
        rows = configuration.hooks.to_h do |id, enabled|
          previous = old.dig("hooks", id) || {}
          [ id, {
            "enabled" => enabled, "cursor" => previous["cursor"],
            "binding_digest" => binding_digest(configuration, id)
          } ]
        end
        {
          "schema_version" => 1, "configuration_digest" => configuration.digest,
          "updated_at" => now.utc.iso8601(6), "hooks" => rows.sort.to_h
        }
      end

      def read_hooks(name)
        return {} unless name
        JSON.parse(File.read(File.join(runtime_path(name), HOOKS_FILE)))
      rescue Errno::ENOENT, JSON::ParserError
        {}
      end

      def binding_digest(configuration, id)
        spec = configuration.contract.fetch("hooks").find { |hook| hook.fetch("id") == id }
        ::Digest::SHA256.hexdigest(canonical(spec))
      end

      def cleanup_generations_unlocked!(name, selection)
        keep = [ selection["active"], selection["previous"] ].compact.map { |row| row.fetch("source_commit") }
        run_generation_references(name).each do |reference|
          next if keep.include?(reference.fetch("source_commit"))
          snapshot = reference["execution_snapshot"]
          unless complete_snapshot?(snapshot)
            raise Hive::ConfigError, "module generation pruning requires a complete nonterminal run snapshot"
          end
        end
        generation_commits(name).each do |commit|
          remove_generation_tree(generation_path(name, commit)) unless keep.include?(commit)
        end
      end

      def cleanup_configurations_unlocked!(name, selection)
        keep = [ selection["active"], selection["previous"] ].compact.map { |row| row.fetch("configuration_digest") }
        Dir.glob(File.join(module_path(name), "configurations", "*.json")).each do |path|
          FileUtils.rm_f(path) unless keep.include?(File.basename(path, ".json"))
        end
      end

      def run_generation_references(name)
        Dir.glob(File.join(runtime_path(name), "runs", "*.json")).filter_map do |path|
          data = JSON.parse(File.read(path))
          next if %w[succeeded failed cancelled].include?(data["status"])
          data if data["source_commit"]
        rescue JSON::ParserError, SystemCallError, IOError
          raise Hive::ConfigError, "module cleanup cannot safely inspect runtime run snapshots"
        end
      end

      def complete_snapshot?(snapshot)
        snapshot.is_a?(Hash) && %w[descriptor configuration grants].all? do |key|
          snapshot[key].is_a?(Hash) && !snapshot[key].empty?
        end
      end

      def mutate_state(name, commit: nil)
        with_mutation do
          reconcile_unlocked!(name)
          selection = selected_unlocked(name, include_tombstone: true)
          raise Hive::ConfigError, "module is not installed" unless selection
          updated = yield(selection)
          old_bytes = canonical(selection)
          Hive::AtomicFile.write(selection_path(name), canonical(updated), mode: 0o600)
          begin
            commit&.call
          rescue StandardError
            Hive::AtomicFile.write(selection_path(name), old_bytes, mode: 0o600)
            raise
          end
          updated
        end
      end

      def reconcile_all_unlocked!
        Dir.glob(File.join(modules_dir, "*", Transaction::JOURNAL_FILE)).sort.each do |journal|
          Transaction.new(File.dirname(journal)).reconcile!
        end
      end

      def reconcile_unlocked!(name)
        Transaction.new(module_path(name)).reconcile!
      end

      def write_failed_activation(name, error, now)
        data = {
          "schema_version" => 1, "failed_at" => now.utc.iso8601(6),
          "reason" => "activation_failed", "error_class" => safe_error_class(error)
        }
        Hive::AtomicFile.write(failed_activation_path(name), canonical(data), mode: 0o600)
      rescue SystemCallError, IOError
        nil
      end

      def clear_failed_activation(name)
        path = failed_activation_path(name)
        return unless File.exist?(path)

        FileUtils.rm_f(path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      rescue SystemCallError, IOError
        nil
      end

      def safe_error_class(error)
        allowed = [ Hive::ConfigError, Hive::ConcurrentRunError ]
        allowed.any? { |type| error.is_a?(type) } ? error.class.name : "RuntimeError"
      end

      def validate_resolution!(resolution)
        validate_name_commit!(resolution.name, resolution.source_commit)
        unless Manifest::SEMVER.match?(resolution.version.to_s) && Manifest::REVISION.match?(resolution.catalog_commit.to_s) &&
               Manifest::SHA256.match?(resolution.manifest_digest.to_s)
          raise Hive::ConfigError, "module resolution provenance is malformed"
        end
      end

      def validate_name_commit!(name, commit)
        unless Manifest::NAME.match?(name.to_s) && Manifest::REVISION.match?(commit.to_s)
          raise Hive::ConfigError, "invalid module generation identity"
        end
      end

      def same_generation?(generation, resolution)
        generation == {
          "name" => resolution.name, "version" => resolution.version,
          "catalog_commit" => resolution.catalog_commit, "source_commit" => resolution.source_commit,
          "manifest_digest" => resolution.manifest_digest
        }
      end

      def validate_selection!(data, name)
        unless data.is_a?(Hash) && data.keys.sort == %w[active enabled epoch high_water_at installed name previous receipt_digest schema_version] &&
               data["schema_version"] == 1 && data["name"] == name.to_s &&
               [ true, false ].include?(data["installed"]) && [ true, false ].include?(data["enabled"]) &&
               data["epoch"].is_a?(Integer) && data["epoch"].positive? &&
               Manifest::SHA256.match?(data["receipt_digest"].to_s)
          raise Hive::ConfigError, "module selection for #{name.inspect} is malformed"
        end
        [ data["active"], data["previous"] ].compact.each { |row| validate_generation_identity!(row) }
        raise Hive::ConfigError, "uninstalled module cannot be enabled" if !data["installed"] && data["enabled"]
      end

      def validate_generation_identity!(row)
        expected = %w[catalog_commit configuration_digest manifest_digest source_commit version]
        unless row.is_a?(Hash) && row.keys.sort == expected && Manifest::SEMVER.match?(row["version"].to_s) &&
               Manifest::REVISION.match?(row["catalog_commit"].to_s) && Manifest::REVISION.match?(row["source_commit"].to_s) &&
               Manifest::SHA256.match?(row["manifest_digest"].to_s) && Manifest::SHA256.match?(row["configuration_digest"].to_s)
          raise Hive::ConfigError, "module selection generation is malformed"
        end
      end

      def remove_generation_tree(path)
        return unless path && File.exist?(path)
        FileUtils.chmod_R(0o700, path)
        FileUtils.rm_rf(path)
      end

      def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)
    end
  end
end
