require "json"
require "hive/atomic_file"
require "hive/workflow_package/canonical_json"

module Hive
  module ModulePackage
    class Transaction
      JOURNAL_FILE = "activation.json".freeze
      PHASES = %w[prepared pointer_provisional health_validated committed].freeze

      attr_reader :module_dir, :selection_path, :hooks_path, :setup_outbox_path,
                  :barrier_path, :journal_path

      def initialize(module_dir)
        @module_dir = File.expand_path(module_dir)
        @selection_path = File.join(@module_dir, "selection.json")
        @hooks_path = File.join(@module_dir, "runtime", "hooks.json")
        @setup_outbox_path = File.join(@module_dir, "runtime", "setup-outbox.json")
        @barrier_path = File.join(@module_dir, "runtime", "activation-barrier.json")
        @journal_path = File.join(@module_dir, JOURNAL_FILE)
      end

      def begin!(candidate_path:, candidate_created:)
        write_journal(
          "schema_version" => 1, "phase" => "prepared",
          "old_selection" => read_bytes(selection_path), "old_hooks" => read_bytes(hooks_path),
          "old_setup_outbox" => read_bytes(setup_outbox_path),
          "candidate_path" => candidate_path, "candidate_created" => !!candidate_created
        )
        write_barrier("prepared")
      end

      def provisional!(selection_bytes:, hooks_bytes:, setup_outbox_bytes: nil)
        restore(selection_path, selection_bytes)
        restore(hooks_path, hooks_bytes)
        restore(setup_outbox_path, setup_outbox_bytes)
        update_phase("pointer_provisional")
        write_barrier("pointer_provisional")
      end

      def health_validated!
        update_phase("health_validated")
        write_barrier("health_validated")
      end

      def commit!
        update_phase("committed")
        FileUtils.rm_f(barrier_path)
        Hive::AtomicFile.fsync_directory(File.dirname(barrier_path))
        FileUtils.rm_f(journal_path)
        Hive::AtomicFile.fsync_directory(module_dir)
        true
      end

      def rollback!
        data = read_journal
        return false unless data
        restore(selection_path, data["old_selection"])
        restore(hooks_path, data["old_hooks"])
        restore(setup_outbox_path, data["old_setup_outbox"])
        remove_candidate(data) if data.fetch("candidate_created")
        clear
        true
      end

      def reconcile!
        data = read_journal
        return false unless data
        if data.fetch("phase") == "committed"
          clear
        else
          rollback!
        end
        true
      end

      private

      def read_journal
        bytes = File.binread(journal_path)
        data = JSON.parse(bytes)
        unless bytes == Hive::WorkflowPackage::CanonicalJSON.generate(data) &&
               data.is_a?(Hash) && data["schema_version"] == 1 && PHASES.include?(data["phase"])
          raise Hive::ConfigError, "module activation journal is malformed"
        end
        data
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError, EncodingError
        raise Hive::ConfigError, "module activation journal is malformed"
      end

      def write_journal(data)
        Hive::AtomicFile.write(
          journal_path, Hive::WorkflowPackage::CanonicalJSON.generate(data), mode: 0o600
        )
        Hive::AtomicFile.fsync_directory(module_dir)
      end

      def update_phase(phase)
        data = read_journal or raise Hive::ConfigError, "module activation journal is missing"
        write_journal(data.merge("phase" => phase))
      end

      def write_barrier(phase)
        Hive::AtomicFile.write(
          barrier_path,
          Hive::WorkflowPackage::CanonicalJSON.generate(
            "schema_version" => 1, "phase" => phase, "module" => File.basename(module_dir)
          ),
          mode: 0o600
        )
      end

      def read_bytes(path)
        File.binread(path) if File.file?(path)
      end

      def restore(path, bytes)
        if bytes
          Hive::AtomicFile.write(path, bytes, mode: 0o600)
        else
          FileUtils.rm_f(path)
          Hive::AtomicFile.fsync_directory(File.dirname(path)) if File.directory?(File.dirname(path))
        end
      end

      def remove_candidate(data)
        candidate = File.expand_path(data.fetch("candidate_path"))
        generations = File.expand_path(File.join(module_dir, "generations"))
        unless candidate.start_with?("#{generations}/") && File.dirname(candidate) == generations
          raise Hive::ConfigError, "module activation candidate path escaped generation storage"
        end
        return unless File.exist?(candidate)
        FileUtils.chmod_R(0o700, candidate)
        FileUtils.rm_rf(candidate)
        Hive::AtomicFile.fsync_directory(generations)
      end

      def clear
        FileUtils.rm_f(barrier_path)
        FileUtils.rm_f(journal_path)
        Hive::AtomicFile.fsync_directory(module_dir)
      end
    end
  end
end
