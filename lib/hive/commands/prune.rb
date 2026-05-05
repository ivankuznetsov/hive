require "json"
require "hive/config"

module Hive
  module Commands
    # `hive prune [--dry-run] [--json]` — drop every registry entry in
    # ~/Dev/hive/config.yml whose `path` no longer points at a directory.
    # The .hive-state directory on disk (when present) is not touched.
    #
    # Common after running `hive init` against `mktemp -d` directories
    # for tests/dogfooding: the tmp dirs vanish, the registry entries do
    # not, and the TUI's project list keeps showing them as `(missing)`.
    class Prune
      def initialize(dry_run: false, json: false)
        @dry_run = dry_run
        @json = json
      end

      def call
        @stdout_written = false
        do_call
      rescue Hive::Error => e
        emit_error_envelope(e) if @json && !@stdout_written
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error_envelope(wrapped) if @json && !@stdout_written
        raise wrapped
      end

      def do_call
        before = Hive::Config.registered_projects
        removed = Hive::Config.prune_missing_projects!(dry_run: @dry_run)
        kept_count = before.size - removed.size

        if @json
          puts JSON.generate(success_payload(removed, kept_count))
          @stdout_written = true
        else
          render_text(removed, kept_count)
        end
      end

      def success_payload(removed, kept_count)
        {
          "schema" => "hive-prune",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-prune"),
          "ok" => true,
          "dry_run" => @dry_run,
          "removed" => removed.map { |entry| entry_payload(entry) },
          "removed_count" => removed.size,
          "kept_count" => kept_count
        }
      end

      def entry_payload(entry)
        {
          "name" => entry["name"],
          "path" => entry["path"],
          "hive_state_path" => entry["hive_state_path"] || File.join(entry["path"], ".hive-state")
        }
      end

      def render_text(removed, kept_count)
        verb = @dry_run ? "would remove" : "removed"
        if removed.empty?
          puts "no stale entries (kept #{kept_count})"
          return
        end

        puts "#{verb} #{removed.size}, kept #{kept_count}"
        removed.each do |entry|
          puts "  - #{entry['name']} (#{entry['path']})"
        end
        puts "(dry-run; rerun without --dry-run to apply)" if @dry_run
      end

      def emit_error_envelope(error)
        payload = {
          "schema" => "hive-prune",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-prune"),
          "ok" => false,
          "error_kind" => error_kind_for(error),
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        }
        puts JSON.generate(payload)
        @stdout_written = true
      rescue Errno::EPIPE, JSON::GeneratorError
        @stdout_written = true
      end

      def error_kind_for(error)
        case error
        when Hive::ConfigError   then "config"
        when Hive::InternalError then "internal"
        else                          "error"
        end
      end
    end
  end
end
