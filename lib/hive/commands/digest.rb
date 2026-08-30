require "json"
require "time"
require "uri"
require "hive/config"
require "hive/daily_digest/reader"
require "hive/tui/text"

module Hive
  module Commands
    # Pure selected-day digest read. This command deliberately has no
    # coordinator, delivery service, or Telegram dependency: all mutations
    # live behind the explicit digest action commands.
    class Digest
      class BrowserOpenFailed < Hive::UnavailableError; end

      SCHEMA = "hive-digest".freeze

      def initialize(date: nil, project: nil, json: false, open_web: false,
                     reader: DailyDigest::Reader.new,
                     web_config_loader: Hive::Config.method(:load_global_web),
                     browser_opener: nil, stdout: $stdout)
        @date = date
        @project = project
        @json = json
        @open_web = open_web
        @reader = reader
        @web_config_loader = web_config_loader
        @browser_opener = browser_opener || method(:open_browser)
        @stdout = stdout
        @emitted = false
      end

      def call
        validate_options!
        view = @reader.read(date: @date, project: @project)
        payload = public_payload(view)
        if @open_web
          opened = @browser_opener.call(payload.fetch("web_url"))
          raise BrowserOpenFailed, "could not open the Hive digest in a browser" if opened == false

          @stdout.puts("Opened #{safe(payload.fetch('web_url'))}")
        elsif @json
          emit_json(payload)
        else
          render_text(payload)
        end
        payload
      rescue Hive::Error => error
        emit_error(error) if @json && !@emitted
        raise
      rescue StandardError => error
        wrapped = Hive::InternalError.new(
          "hive digest read failed: #{error.class}: #{error.message}"
        )
        emit_error(wrapped) if @json && !@emitted
        raise wrapped
      end

      private

      def validate_options!
        return unless @json && @open_web

        raise Hive::UsageError, "--json and --open-web are mutually exclusive"
      end

      def public_payload(view)
        interval = view["interval"].is_a?(Hash) ? view.fetch("interval") : view
        status = view.fetch("reader_status", "ok")
        lifecycle = status == "missing" ? "missing" : view.fetch("lifecycle", status)
        completeness = if %w[missing pruned].include?(lifecycle)
          "unknown"
        else
          view["view_completeness"] || view["effective_completeness"] ||
            view["completeness"] || "unknown"
        end
        content = if %w[missing pruned].include?(lifecycle)
          "unknown"
        else
          view["effective_content"] || view["content"] || "unknown"
        end
        local_date = view["local_date"] || interval["local_date"] || normalized_requested_date

        {
          "schema" => SCHEMA,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => true,
          "reader_status" => status,
          "record_id" => view["record_id"],
          "interval_id" => interval["interval_id"],
          "local_date" => local_date,
          "sequence" => interval["sequence"],
          "time_zone" => interval["time_zone"],
          "starts_at" => interval["starts_at"],
          "ends_at" => interval["ends_at"],
          "duration_seconds" => interval["duration_seconds"],
          "boundary_kind" => interval["boundary_kind"],
          "cutover" => interval["cutover"],
          "lifecycle" => lifecycle,
          "closed_at" => view["closed_at"],
          "completeness" => completeness,
          "content" => content,
          "last_materialized_at" => view["last_materialized_at"],
          "stale" => view.fetch("stale", false) == true,
          "selected_project" => @project || view["selected_project"],
          "projects" => Array(view["projects"]),
          "attention" => Array(view["attention"]),
          "items" => Array(view["items"]),
          "gaps" => Array(view["effective_gaps"] || view["gaps"]),
          "amendments" => Array(view["amendments"]),
          "previous_date" => view["previous_date"],
          "next_date" => view["next_date"],
          "coverage_started_at" => view["coverage_started_at"],
          "precoverage" => view.fetch("precoverage", false) == true,
          "pruned_at" => view["pruned_at"],
          "web_url" => web_url(local_date, @project || view["selected_project"])
        }
      end

      def normalized_requested_date
        return nil if @date.nil?

        Date.iso8601(@date.to_s).iso8601
      rescue Date::Error, TypeError
        @date.to_s
      end

      def web_url(local_date, project)
        origin = @web_config_loader.call.fetch("origin").to_s.strip
        uri = URI.parse(origin)
        unless %w[http https].include?(uri.scheme) && uri.host
          raise Hive::ConfigError, "web.origin must be an http(s) URL before opening a digest"
        end

        label = local_date.to_s.empty? ? "today" : local_date.to_s
        url = "#{origin.sub(%r{/+\z}, '')}/digests/#{URI.encode_www_form_component(label)}"
        return url if project.to_s.empty?

        "#{url}?#{URI.encode_www_form('project' => project.to_s)}"
      rescue URI::InvalidURIError
        raise Hive::ConfigError, "web.origin must be a valid http(s) URL before opening a digest"
      end

      def render_text(payload)
        case payload.fetch("reader_status")
        when "missing"
          render_missing(payload)
        when "pruned"
          render_pruned(payload)
        else
          render_record(payload)
        end
      end

      def render_missing(payload)
        scope = payload.fetch("precoverage") ? " before digest coverage began" : ""
        @stdout.puts("Digest #{safe(payload['local_date'] || 'today')} is missing#{scope}.")
        @stdout.puts("Run `hive digest refresh#{date_flag(payload['local_date'])}` only for feature-era history.")
      end

      def render_pruned(payload)
        @stdout.puts("Digest #{safe(payload.fetch('local_date'))} was pruned.")
        @stdout.puts("Its audit tombstone remains; Hive will not reconstruct this projection.")
      end

      def render_record(payload)
        freshness = payload["last_materialized_at"] || "unknown"
        stale = payload.fetch("stale") ? " · stale" : ""
        @stdout.puts(
          "Digest #{safe(payload.fetch('local_date'))} · #{safe(payload['time_zone'])} · " \
          "#{safe(payload.fetch('lifecycle'))} · #{safe(payload.fetch('completeness'))} · " \
          "#{safe(payload.fetch('content'))} · materialized #{safe(freshness)}#{stale}"
        )
        render_attention(payload.fetch("attention"))
        render_gaps(payload.fetch("gaps"))
        render_items(payload.fetch("items"))
        render_amendments(payload.fetch("amendments"))
        if payload.fetch("content") == "empty"
          @stdout.puts("No material activity or boundary attention was observed.")
        elsif payload.fetch("content") == "unknown" && payload.fetch("items").empty?
          @stdout.puts("No known material activity; source gaps prevent an empty-day claim.")
        end
        @stdout.puts("Web: #{safe(payload.fetch('web_url'))}")
      end

      def render_attention(rows)
        @stdout.puts("\nNeeds attention (#{rows.length})")
        rows.each do |row|
          identity = [ row["project"], row["task_slug"] ].compact.join(":")
          state = [ row["stage"], row["state"] ].compact.join(" / ")
          age = row["waiting_age_seconds"] ? format_age(row.fetch("waiting_age_seconds")) : "age unknown"
          parts = [ "[#{safe(row['kind'])}] #{safe(identity)}", safe(state), age, safe(row["task_url"]) ]
          @stdout.puts("- #{parts.reject(&:empty?).join(' · ')}")
        end
      end

      def render_gaps(rows)
        return if rows.empty?

        @stdout.puts("\nSource gaps (#{rows.length})")
        rows.each do |gap|
          @stdout.puts(
            "- #{safe(gap['source'])} · #{safe(gap['scope'])} · #{safe(gap['reason'])}"
          )
        end
      end

      def render_items(rows)
        @stdout.puts("\nProject activity (#{rows.length})")
        rows.group_by { |row| row["project"] || "Historical project" }
            .sort_by { |project, _| project.to_s }
            .each do |project, items|
          @stdout.puts("#{safe(project)}")
          items.sort_by { |row| [ row["occurred_at"].to_s, row["fact_id"].to_s ] }.each do |row|
            task = row["task_slug"] ? " · #{safe(row['task_slug'])}" : ""
            link = item_link(row)
            @stdout.puts(
              "- #{safe(short_time(row['occurred_at']))} #{safe(row['summary'] || row['kind'])}#{task}#{link}"
            )
          end
        end
      end

      def render_amendments(rows)
        return if rows.empty?

        @stdout.puts("\nLate amendments (#{rows.length})")
        rows.each do |row|
          summary = [
            "#{Array(row['items']).length} item(s)",
            "#{Array(row['resolved_gap_ids']).length} resolved gap(s)"
          ].join(", ")
          @stdout.puts("- #{safe(row['amended_at'])} · #{safe(row['kind'])} · #{summary}")
        end
      end

      def item_link(row)
        value = row["task_url"] || row.dig("pr", "url")
        value.to_s.empty? ? "" : " · #{safe(value)}"
      end

      def short_time(value)
        Time.iso8601(value.to_s).utc.strftime("%H:%M")
      rescue ArgumentError, TypeError
        value.to_s
      end

      def format_age(seconds)
        value = Integer(seconds)
        return "#{value / 86_400}d" if value >= 86_400
        return "#{value / 3_600}h" if value >= 3_600
        return "#{value / 60}m" if value >= 60

        "#{value}s"
      rescue ArgumentError, TypeError
        "age unknown"
      end

      def date_flag(date)
        date.to_s.empty? ? "" : " --date #{safe(date)}"
      end

      def safe(value)
        Hive::Tui::Text.sanitize(value)
      end

      def open_browser(url)
        browser = ENV["BROWSER"].to_s.strip
        program = browser.empty? ? "xdg-open" : browser
        system(program, url, out: File::NULL, err: File::NULL)
      end

      def emit_json(payload)
        @stdout.puts(JSON.generate(payload))
        @emitted = true
      rescue Errno::EPIPE
        @emitted = true
      end

      def emit_error(error)
        emit_json(
          Hive::Schemas::ErrorEnvelope.build(
            schema: SCHEMA, error: error, error_kind: error_kind(error)
          )
        )
      end

      def error_kind(error)
        case error
        when Hive::UsageError then "usage"
        when Hive::ConfigError then "config"
        when DailyDigest::Reader::UnknownProject then "unknown_project"
        when DailyDigest::InvalidRecord then "invalid_date"
        when BrowserOpenFailed then "browser_unavailable"
        when Hive::InternalError then "internal"
        else "digest_error"
        end
      end
    end
  end
end
