require "date"
require "json"
require "hive/digest"
require "hive/digest/merged_pr"
require "hive/digest/source"

module Hive
  module Commands
    class Digest
      DEFAULT_CONFIG_LOADER = -> { Hive::Config.load_global_digest_block }

      def initialize(date: nil, dry_run: false, json: false, runner: Hive::Digest,
                     merged_runner: Hive::Digest::MergedPr, output: $stdout,
                     source: nil, repos: [], config_loader: DEFAULT_CONFIG_LOADER)
        @date = date
        @dry_run = dry_run
        @json = json
        @runner = runner
        @merged_runner = merged_runner
        @output = output
        @source = source
        @repos = Array(repos)
        @config_loader = config_loader
        @configured_source = nil
        @resolved_source = nil
      end

      def call
        resolve_source!
        local_date = parse_date
        result =
          if merged_pr_source?
            @merged_runner.run(date: local_date, dry_run: @dry_run, repos: @repos)
          else
            @runner.run(date: local_date, dry_run: @dry_run)
          end
        emit(result)
        result
      rescue Hive::Error => e
        # A bad --date raises Hive::ConfigError, which Thor never sees (it is
        # not a Thor::Error), so bin/hive's JSON_USAGE_ERROR_CONTRACTS path
        # never fires for it. Emit the in-command JSON error envelope here —
        # mirroring ~10 sibling commands — before re-raising, so an agent
        # parsing --json stdout gets a structured error on the most common
        # usage mistake. Non-JSON output and the exit code are unchanged.
        emit_error_envelope(e) if @json
        raise
      end

      private

      def parse_date
        # No --date: defer to Hive::Digest.run, which owns the single
        # "local day that just ended" default (and its injectable clock).
        # Computing it here too would duplicate that default across two
        # sites that could drift.
        return nil if @date.to_s.empty?

        unless @date.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          raise Hive::ConfigError, "hive digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
        end

        Hive::Digest::Window.parse_date(@date)
      rescue ArgumentError
        raise Hive::ConfigError, "hive digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
      end

      def resolve_source!
        config = @config_loader.call
        @configured_source = config["source"]
        @resolved_source = Hive::Digest::Source.resolve(
          explicit: @source,
          repos: @repos,
          configured: @configured_source
        )
      end

      def merged_pr_source?
        @resolved_source == Hive::Digest::Source::MERGED_PRS
      end

      def emit(result)
        if @json
          @output.puts JSON.generate(json_payload(result))
        elsif merged_pr_source?
          emit_merged_pr_human(result)
        elsif @dry_run
          @output.puts result.message
        else
          @output.puts "hive digest: #{result.status} for #{result.date.iso8601}"
        end
      end

      def json_payload(result)
        return merged_pr_json_payload(result) if merged_pr_source?

        {
          # Derive from status so a machine consumer can tell a delivered
          # digest from one that fell back to a failure notice.
          "ok" => result.status != :failed_notice,
          "schema" => "hive-digest",
          # Versioned like every other --json envelope; fetched from the
          # single SCHEMA_VERSIONS registry so the two can't drift.
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-digest"),
          "date" => result.date.iso8601,
          "status" => result.status.to_s,
          "dry_run" => @dry_run,
          # The recipient the send actually resolved (nil on a dry-run, which
          # resolves none) — surfaced for post-send auditability. Optional in
          # the schema, so older consumers that ignore it stay compatible.
          "chat_id" => result.delivery&.chat_id,
          "message" => @dry_run ? result.message : nil
        }
      end

      def merged_pr_json_payload(result)
        {
          "ok" => true,
          "schema" => "hive-merged-pr-digest",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-merged-pr-digest"),
          "date" => result.date.iso8601,
          "source" => Hive::Digest::Source::MERGED_PRS,
          "dry_run" => @dry_run,
          "repos" => result.repos,
          "count" => result.count,
          "prs" => result.prs.map(&:to_h),
          "chat_id" => result.delivery&.chat_id,
          "message" => @dry_run ? result.message : nil
        }
      end

      def emit_merged_pr_human(result)
        if @dry_run
          @output.puts result.message
        elsif result.count.zero?
          # A zero-count digest is still delivered (a "PRs 0" footer is
          # sent); say so explicitly so the line doesn't read as "sent nothing".
          @output.puts "hive digest: sent empty digest (0 merged PRs) for #{result.date.iso8601}"
        else
          @output.puts "hive digest: sent #{result.count} merged PRs for #{result.date.iso8601}"
        end
      end

      def emit_error_envelope(error)
        schema =
          if @resolved_source
            Hive::Digest::Source.schema_for(@resolved_source)
          else
            Hive::Digest::Source.schema_for_options(
              explicit: @source,
              repos: @repos,
              configured: @configured_source
            )
          end
        @output.puts JSON.generate(
          "schema" => schema,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(schema),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error.is_a?(Hive::ConfigError) ? "config" : "internal",
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        )
      end
    end
  end
end
