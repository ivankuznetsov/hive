# frozen_string_literal: true

require "json"
require "hive/atomic_file"
require "hive/brainstorm_parser"
require "hive/brainstorm_suggestions/envelope"
require "hive/brainstorm_suggestions/store"
require "hive/config"
require "hive/lock"
require "hive/markers"

module Hive
  module Commands
    # Operational lifecycle commands for advisory brainstorm suggestions.
    # `cleanup` is the mandatory downgrade fence: it strips every reserved
    # envelope and sidecar under the task lock, then proves parsed answers did
    # not change before reporting that disabling the feature is safe.
    class BrainstormSuggestion
      RECEIPT_SCHEMA = "hive-brainstorm-suggestion-cleanup"

      def initialize(action, target: nil, project: nil, task_roots: nil,
                     json: false, output: $stdout)
        @action = action.to_s
        @target = target.to_s unless target.nil?
        @project = project.to_s unless project.nil?
        @task_roots = task_roots
        @json = json
        @output = output
      end

      def call
        raise Hive::UsageError, "expected `cleanup`" unless @action == "cleanup"

        tasks = discover_task_roots
        results = tasks.map { |task_root| cleanup_task(task_root) }
        receipt = {
          "schema" => RECEIPT_SCHEMA,
          "schema_version" => 1,
          "ok" => true,
          "operation" => "cleanup",
          "safe_to_disable" => results.all? { |result| result["status"] == "clean" },
          "tasks_scanned" => results.length,
          "envelopes_removed" => results.sum { |result| result["envelopes_removed"] },
          "sidecars_removed" => results.count { |result| result["sidecar_removed"] },
          "parser_verified" => results.count { |result| result["parser_verified"] },
          "tasks" => results
        }
        emit(receipt)
        receipt
      end

      private

      def discover_task_roots
        roots = if @task_roots
          Array(@task_roots)
        else
          registered_task_roots
        end
        roots.map { |root| File.expand_path(root) }
             .select { |root| File.directory?(root) && !File.symlink?(root) }
             .select { |root| @target.to_s.empty? || root == File.expand_path(@target) || File.basename(root) == @target }
             .uniq.sort
      end

      def registered_task_roots
        Hive::Config.registered_projects.flat_map do |entry|
          next [] if @project && entry["name"] != @project

          stages = File.join(entry.fetch("hive_state_path"), "stages")
          next [] unless File.directory?(stages)

          Dir.glob(File.join(stages, "*", "*"), File::FNM_DOTMATCH).filter_map do |candidate|
            next if %w[. ..].include?(File.basename(candidate))

            status = File.lstat(candidate)
            candidate if status.directory? && !status.symlink?
          rescue SystemCallError
            nil
          end
        end
      end

      def cleanup_task(task_root)
        result = task_result(task_root)
        Hive::Lock.with_task_lock(
          task_root,
          { op: "brainstorm_suggestion_cleanup", slug: File.basename(task_root) },
          create: false
        ) do
          state_path = File.join(task_root, "brainstorm.md")
          if File.exist?(state_path)
            cleanup_brainstorm(state_path, result)
          else
            result["parser_verified"] = true
          end
          result["sidecar_removed"] = remove_sidecar(task_root)
          verify_clean!(task_root, state_path, result)
        end
        result
      rescue Hive::ConcurrentRunError
        result.merge("status" => "lock_busy", "reason" => "task_lock_busy")
      rescue SystemCallError, IOError, Hive::BrainstormSuggestions::Error => e
        result.merge("status" => "unsafe", "reason" => e.class.name.split("::").last)
      end

      def cleanup_brainstorm(state_path, result)
        Hive::Markers.with_markers_lock(state_path, create: false, timeout: 5) do
          content = read_regular(state_path)
          before = Hive::BrainstormParser.parse_text(content).map(&:answer)
          stripped = Hive::BrainstormSuggestions::Envelope.strip(content)
          result["envelopes_removed"] = stripped.regions.length
          result["envelopes_removed"] += 1 if stripped.corrupt? && content.match?(Hive::BrainstormSuggestions::Envelope::RESERVED_RE)
          Hive::Markers.write_atomic(state_path, stripped.text) if stripped.text != content
          after = Hive::BrainstormParser.parse_text(stripped.text).map(&:answer)
          raise IOError, "brainstorm answers changed during suggestion cleanup" unless before == after

          result["parser_verified"] = true
        end
      end

      def remove_sidecar(task_root)
        path = File.join(task_root, Hive::BrainstormSuggestions::Store::FILENAME)
        return false unless File.exist?(path) || File.symlink?(path)

        status = File.lstat(path)
        raise IOError, "suggestion sidecar is not removable state" unless status.file? || status.symlink?

        File.unlink(path)
        Hive::AtomicFile.fsync_directory(task_root)
        true
      rescue Errno::ENOENT
        false
      end

      def verify_clean!(task_root, state_path, result)
        if File.exist?(state_path)
          body = read_regular(state_path)
          raise IOError, "reserved suggestion envelope remains" if
            body.match?(Hive::BrainstormSuggestions::Envelope::RESERVED_RE)
        end
        sidecar = File.join(task_root, Hive::BrainstormSuggestions::Store::FILENAME)
        raise IOError, "suggestion sidecar remains" if File.exist?(sidecar) || File.symlink?(sidecar)

        result["status"] = "clean"
      end

      def read_regular(path)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          status = file.stat
          raise IOError, "brainstorm state is not a regular file" unless status.file?

          file.read
        end
      end

      def task_result(task_root)
        {
          "task" => File.basename(task_root),
          "status" => "unsafe",
          "reason" => nil,
          "envelopes_removed" => 0,
          "sidecar_removed" => false,
          "parser_verified" => false
        }
      end

      def emit(receipt)
        if @json
          @output.puts(JSON.generate(receipt))
        else
          status = receipt.fetch("safe_to_disable") ? "safe" : "unsafe"
          @output.puts(
            "brainstorm suggestions cleanup: #{status}; " \
            "#{receipt.fetch('envelopes_removed')} envelopes, " \
            "#{receipt.fetch('sidecars_removed')} sidecars removed"
          )
        end
      end
    end
  end
end
