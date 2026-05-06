require "json"
require "hive/config"

module Hive
  module Commands
    # `hive prune [--dry-run] [--json]` — drop every registry entry in
    # ~/Dev/hive/config.yml whose `path` no longer points at a directory.
    # Also drops malformed entries (non-Hash rows, rows missing `path`,
    # rows whose `path` isn't a String) — these are hand-edit accidents
    # and have always been undisplayable in `hive status`. The
    # .hive-state directory on disk (when present) is not touched.
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
        result = Hive::Config.prune_missing_projects!(dry_run: @dry_run)
        removed = result.fetch(:removed)
        kept_count = result.fetch(:kept_count)

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
        path = entry["path"].is_a?(String) ? entry["path"] : ""
        {
          "name" => entry["name"].to_s,
          "path" => path,
          "hive_state_path" => entry["hive_state_path"] ||
            (path.empty? ? "" : File.join(path, ".hive-state"))
        }
      end

      def render_text(removed, kept_count)
        verb = @dry_run ? "would remove" : "removed"
        if removed.empty?
          # Same hint regardless of dry-run state: the registry is
          # already clean, and a dry-run vs. live invocation produces
          # the same result. Without naming dry-run here, an operator
          # who ran `hive prune --dry-run` couldn't tell the flag was
          # honoured (versus silently dropped) when there's nothing to
          # remove.
          suffix = @dry_run ? " (dry-run; nothing to do)" : ""
          puts "no stale entries (kept #{kept_count})#{suffix}"
          return
        end

        puts "#{verb} #{removed.size}, kept #{kept_count}"
        removed.each do |entry|
          puts "  - #{entry['name']} (#{entry['path']})"
        end
        puts "(dry-run; rerun without --dry-run to apply)" if @dry_run
      end

      def emit_error_envelope(error)
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-prune",
          error: error,
          error_kind: error_kind_for(error)
        )
        puts JSON.generate(payload)
        @stdout_written = true
      rescue Errno::EPIPE, JSON::GeneratorError
        @stdout_written = true
      end

      def error_kind_for(error)
        case error
        when Hive::ConfigError   then Hive::Schemas::PruneErrorKind::CONFIG
        when Hive::InternalError then Hive::Schemas::PruneErrorKind::INTERNAL
        else                          Hive::Schemas::PruneErrorKind::INTERNAL
        end
      end
    end
  end
end
