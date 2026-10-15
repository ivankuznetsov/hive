require "json"
require "hive/config"
require "hive/mcp"
require "hive/mcp/discovery"
require "hive/mcp/importer"
require "hive/schemas"

module Hive
  module Commands
    # `hive mcp import` copies chosen personal MCP servers into Hive's
    # global catalog; `hive mcp login SERVER --agent AGENT` signs one agent
    # in to a catalog server so headless launches can reuse the saved login
    # (plan 2026-10-15-001, U5).
    class Mcp
      include Hive::Schemas::EnvelopeEmitter

      SUBCOMMANDS = %w[import login].freeze
      ERROR_KINDS = %w[usage consent_required config agent internal].freeze

      class ConsentRequired < Hive::UsageError; end

      def initialize(subcommand, server = nil, json: false, all: false, only: nil, dry_run: false,
                     yes: false, update: false, agent: nil, cwd: Dir.pwd, input: $stdin,
                     output: $stdout, error: $stderr, discover: nil, runner: nil)
        @subcommand = subcommand.to_s
        @server = server
        @json = json
        @all = all
        @only = only.to_s.split(",").map(&:strip).reject(&:empty?)
        @dry_run = dry_run
        @yes = yes
        @update = update
        @agent = agent
        @cwd = cwd
        @input = input
        @output = output
        @error = error
        @discover = discover || ->(cwd) { Hive::Mcp::Discovery.discover(cwd: cwd) }
        @runner = runner || ->(argv) { system(*argv) }
      end

      def call
        call_with_envelope do
          case @subcommand
          when "import" then import
          when "login" then login
          else raise Hive::UsageError, "hive mcp: expected a subcommand (#{SUBCOMMANDS.join(' or ')})"
          end
        end
      end

      def envelope_schema = "hive-mcp-import"

      def envelope_error_kind(error)
        case error
        when ConsentRequired then "consent_required"
        when Hive::UsageError then "usage"
        when Hive::ConfigError then "config"
        when Hive::AgentError then "agent"
        else "internal"
        end
      end

      def envelope_extras = { "action" => @subcommand.empty? ? nil : @subcommand }.compact

      # EnvelopeEmitter writes the error document with `puts`.
      def puts(*lines) = @output.puts(*lines)

      # --- import ---------------------------------------------------------------

      def import
        raise Hive::UsageError, "hive mcp import takes no SERVER argument; use --only" if @server
        raise Hive::UsageError, "hive mcp import: --all and --only are mutually exclusive" if @all && @only.any?

        catalog = Hive::Config.load_global_mcp.fetch("servers")
        result = @discover.call(@cwd)
        rows = Hive::Mcp::Importer.plan(result, catalog)
        selected = choose(rows)
        written = @dry_run ? [] : Hive::Mcp::Importer.apply!(selected)
        report(rows, selected, written, result.notices)
        0
      end

      def choose(rows)
        if @all || @only.any?
          selected = Hive::Mcp::Importer.select(rows, all: @all, only: @only, update: @update)
          return selected if @dry_run || @yes || selected.empty? || confirmed?(selected)

          raise ConsentRequired, "hive mcp import: pass --yes to write #{selected.size} server(s), or --dry-run to preview"
        end
        return [] if @dry_run
        raise ConsentRequired, "hive mcp import: choose servers with --all or --only (or run it in a terminal)" unless interactive?

        prompt_selection(rows)
      end

      def confirmed?(selected)
        return false unless interactive?

        @error.print "Write #{selected.map(&:id).join(', ')} to #{Hive::Config.global_config_path}? [y/N]: "
        @error.flush
        %w[y yes].include?(@input.gets.to_s.strip.downcase)
      end

      def interactive?
        !@json && @input.respond_to?(:tty?) && @input.tty?
      rescue IOError
        false
      end

      def prompt_selection(rows)
        render_table(rows)
        choices = rows.select(&:importable?)
        if choices.empty?
          @error.puts "Nothing to import."
          return []
        end
        @error.print "Import which servers? Numbers or names, comma-separated; `all` for every new one; Enter to skip: "
        @error.flush
        answer = @input.gets.to_s.strip
        return [] if answer.empty?
        return Hive::Mcp::Importer.select(rows, all: true, update: @update) if answer == "all"

        keys = answer.split(",").map(&:strip).map do |key|
          key.match?(/\A\d+\z/) ? rows.fetch(key.to_i - 1, nil)&.id || key : key
        end
        Hive::Mcp::Importer.select(rows, only: keys, update: @update)
      end

      def report(rows, selected, written, notices)
        if @json
          @output.puts JSON.generate(payload(rows, selected, written, notices))
          @stdout_written = true
          return
        end

        render_table(rows) unless interactive?
        notices.each { |notice| @error.puts "note: #{notice}" }
        if @dry_run
          @output.puts "dry run: would import #{selected.map(&:id).join(', ').then { |ids| ids.empty? ? 'nothing' : ids }}"
        else
          @output.puts(written.empty? ? "No servers imported." : "Imported #{written.join(', ')} into #{Hive::Config.global_config_path}")
        end
        exports = selected.flat_map(&:exports).uniq
        return if exports.empty?

        @output.puts "Export these before launching agents (Hive stores only the variable names):"
        exports.each { |export| @output.puts "  export #{export.fetch('var')}=...   # #{export.fetch('for')}" }
        @output.puts "Grant servers per project or stage with `mcp: { use: [name] }` in .hive-state/config.yml."
      end

      def payload(rows, selected, written, notices)
        ids = selected.map(&:id)
        {
          "schema" => "hive-mcp-import",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-mcp-import"),
          "ok" => true, "action" => "import", "dry_run" => @dry_run,
          "catalog_path" => Hive::Config.global_config_path,
          "written" => written,
          "rows" => rows.map { |item| item.to_h.merge("selected" => ids.include?(item.id)) },
          "notices" => notices
        }
      end

      def render_table(rows)
        if rows.empty?
          @error.puts "No personal MCP servers found."
          return
        end
        @error.puts format("%-3s %-13s %-24s %-22s %-6s %s", "#", "STATUS", "NAME", "SOURCES", "TYPE", "AUTH")
        rows.each_with_index do |item, index|
          detail = if item.refusal then "refused: #{item.refusal}"
          elsif item.logins.any? then "#{item.auth} (signed in: #{item.logins.join(', ')})"
          else item.auth
          end
          @error.puts format("%-3d %-13s %-24s %-22s %-6s %s", index + 1, item.status, item.id,
                             item.sources.join(","), item.transport || "-", detail)
        end
      end

      # --- login ----------------------------------------------------------------

      def login
        raise Hive::UsageError, "hive mcp login is interactive and has no JSON mode" if @json
        raise Hive::UsageError, "hive mcp login: name the catalog SERVER" if @server.to_s.empty?
        adapter = Hive::Mcp.adapter(@agent.to_s)
        unless adapter.respond_to?(:login_argv)
          signers = Hive::Mcp::Discovery::AGENTS.select { |agent| Hive::Mcp.adapter(agent).respond_to?(:login_argv) }
          raise Hive::UsageError, "hive mcp login: --agent must be one of #{signers.join(', ')}; " \
                                  "the other agents cannot sign in to a Hive-rendered server yet"
        end
        raise Hive::UsageError, "hive mcp login needs a terminal: the agent opens a browser sign-in" unless @input.respond_to?(:tty?) && @input.tty?

        spec = Hive::Config.load_global_mcp.fetch("servers")[@server]
        raise Hive::UsageError, "hive mcp login: #{@server} is not in the global MCP catalog; run `hive mcp import` first" unless spec
        raise Hive::UsageError, "hive mcp login: #{@server} is a stdio server; only HTTP servers sign in" unless spec["url"]

        unless @runner.call(adapter.login_argv(@server, spec))
          raise Hive::AgentError, "hive mcp login: #{@agent} sign-in for #{@server} did not complete"
        end
        Hive::Mcp::Importer.record_login!(@server, @agent)
        @output.puts "#{@agent} is signed in to #{@server}; Hive launches will now render it for #{@agent}."
        0
      end
    end
  end
end

# The pre-dispatch JSON usage contract for this command boundary (see
# Hive::CliUsageContracts).
require "hive/cli_usage_contracts"

Hive::CliUsageContracts.declare("mcp", { schema: "hive-mcp-import", error_kind: "usage" })
