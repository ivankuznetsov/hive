require "json"
require "hive/config"

module Hive
  module Commands
    # `hive prune [--dry-run] [--json]` — drop every registry entry in
    # ~/Dev/hive/config.yml whose `path` no longer points at a directory,
    # whose stored realpath no longer matches the current target, or whose
    # row shape is invalid. Malformed entries (non-Hash rows, rows missing
    # `path`, rows whose `path` isn't a String) are hand-edit accidents
    # and have always been undisplayable in `hive status`. The
    # .hive-state directory on disk (when present) is not touched.
    #
    # Common after running `hive init` against `mktemp -d` directories
    # for tests/dogfooding: the tmp dirs vanish, the registry entries do
    # not, and the TUI's project list keeps showing them as `(missing)`.
    class Prune
      include Hive::Schemas::EnvelopeEmitter

      def initialize(dry_run: false, json: false)
        @dry_run = dry_run
        @json = json
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema
        "hive-prune"
      end

      def envelope_error_kind(error)
        error_kind_for(error)
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
        # Schema describes `path` / `hive_state_path` as absolute. Run
        # through File.expand_path so a hand-edited row carrying `~/foo`
        # or `./foo` lands as the absolute form in the envelope. Empty/
        # missing path is preserved as "" rather than expanded against
        # `Dir.pwd` (which would lie about where the row pointed).
        #
        # Non-Hash rows reach here from `prune_missing_projects!` (the
        # loader-level `valid_registry_entry?` filter is mirrored in
        # `droppable_registry_entry?` so the cleanup verb sees them).
        # `42["path"]` raises TypeError, which previously crashed the
        # success payload AFTER the registry was already rewritten. Emit
        # the row's own representation as `name` so the operator can see
        # what was dropped, and leave path / hive_state_path as "".
        return non_hash_entry_payload(entry) unless entry.is_a?(Hash)

        raw_path = entry["path"].is_a?(String) ? entry["path"] : ""
        abs_path = raw_path.empty? ? "" : File.expand_path(raw_path)
        raw_hive_state = entry["hive_state_path"]
        hive_state = if raw_hive_state.is_a?(String) && !raw_hive_state.empty?
                       File.expand_path(raw_hive_state)
        elsif abs_path.empty?
                       ""
        else
                       File.join(abs_path, ".hive-state")
        end
        {
          "name" => entry["name"].to_s,
          "path" => abs_path,
          "hive_state_path" => hive_state
        }
      end

      def non_hash_entry_payload(entry)
        {
          "name" => entry.to_s,
          "path" => "",
          "hive_state_path" => ""
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
