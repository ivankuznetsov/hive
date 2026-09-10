require "digest"
require "json"
require "uri"
require "hive/bot/format"
require "hive/daily_digest"
require "hive/daily_digest/record"
require "hive/daily_digest/public_view"

module Hive
  module DailyDigest
    # Bounded HTML recap built only from the persisted digest projection.
    # Every dynamic field is control-stripped, length-bounded, and escaped at
    # this sink; attention rows use an explicit privacy allowlist.
    class TelegramRenderer
      MAX_CHARS = 3_800
      MAX_ATTENTION = 5
      MAX_ITEMS = 8
      FIELD_LIMIT = 160
      ATTENTION_KEYS = %w[kind project task_slug stage state waiting_age_seconds].freeze

      Rendered = Data.define(:text, :parse_mode, :payload_hash, :web_url,
                             :amendment_frontier, :counts)

      def initialize(web_origin:)
        @web_origin = validate_origin(web_origin)
      end

      def render(record)
        date = record.fetch("local_date")
        completeness = record["effective_completeness"] || record.fetch("completeness")
        items = PublicView.ordered_items(record)
        attention = Array(record["attention"]).map { |row| row.slice(*ATTENTION_KEYS) }
        gaps = Array(record["effective_gaps"] || record["gaps"])
        amendments = Array(record["amendments"])
        link = web_url(date)
        counts = {
          "items" => items.length, "attention" => attention.length,
          "gaps" => gaps.length, "amendments" => amendments.length
        }.freeze

        lines = [
          "<b>Hive daily digest · #{field(date, limit: 24)}</b>",
          status_line(completeness, record),
          "#{items.length} changes · #{attention.length} attention · " \
            "#{gaps.length} gaps · #{amendments.length} late amendments"
        ]
        append_attention(lines, attention)
        append_items(lines, items)
        append_gaps(lines, gaps)
        lines << %(<a href="#{Hive::Bot::Format.html_attr_escape(link)}">Open the complete digest</a>)
        text = bounded_message(lines)

        Rendered.new(
          text: text, parse_mode: :html,
          payload_hash: Digest::SHA256.hexdigest(text), web_url: link,
          amendment_frontier: amendment_frontier(amendments), counts: counts
        )
      end

      private

      def status_line(completeness, record)
        content = record["effective_content"] || record.fetch("content")
        label = completeness == "complete" ? "Complete" : "Incomplete data"
        "#{label} · #{field(content.to_s.tr('_', ' '), limit: 40)}"
      end

      def append_attention(lines, rows)
        return if rows.empty?

        lines << "\n<b>Needs attention</b>"
        rows.first(MAX_ATTENTION).each do |row|
          identity = [ row["project"], row["task_slug"] ].compact.join(":")
          state = [ row["stage"], row["state"] ].compact.join(" · ")
          age = row["waiting_age_seconds"] ? age_label(row.fetch("waiting_age_seconds")) : "age unknown"
          lines << "• #{field(identity)} · #{field(row['kind'])} · #{field(state)} · #{field(age)}"
        end
        append_more(lines, rows.length - MAX_ATTENTION, "attention items")
      end

      def append_items(lines, rows)
        return if rows.empty?

        lines << "\n<b>Material changes</b>"
        rows.first(MAX_ITEMS).each do |row|
          project = row["project"] || "Historical project"
          summary = row["summary"] || row["kind"] || "Changed"
          lines << "• #{field(project)} · #{field(summary)}"
        end
        append_more(lines, rows.length - MAX_ITEMS, "changes")
      end

      def append_gaps(lines, rows)
        return if rows.empty?

        lines << "\n<b>Source gaps</b>"
        rows.first(3).each do |gap|
          # Reasons can contain provider payloads or paths. The durable record
          # retains the bounded redacted reason; Telegram needs only source and
          # scope to truthfully label the recap incomplete.
          lines << "• #{field(gap['source'])} · #{field(gap['scope'] || 'global')}"
        end
        append_more(lines, rows.length - 3, "source gaps")
      end

      def append_more(lines, count, noun)
        lines << "• +#{count} more #{noun}" if count.positive?
      end

      def age_label(value)
        seconds = Integer(value)
        return "#{seconds / 86_400}d" if seconds >= 86_400
        return "#{seconds / 3_600}h" if seconds >= 3_600
        return "#{seconds / 60}m" if seconds >= 60

        "<1m"
      rescue ArgumentError, TypeError
        "age unknown"
      end

      def bounded_message(lines)
        link = lines.pop
        body = []
        lines.each do |line|
          candidate = ([ *body, line, link ]).join("\n")
          break if candidate.length > MAX_CHARS

          body << line
        end
        message = ([ *body, link ]).join("\n")
        raise DailyDigest::InvalidRecord, "digest Telegram payload exceeds its safety bound" if
          message.length > MAX_CHARS

        message
      end

      def amendment_frontier(amendments)
        identities = amendments.map { |row| row.fetch("amendment_id") }.sort
        Digest::SHA256.hexdigest(Record.canonical_json(identities))
      end

      def field(value, limit: FIELD_LIMIT)
        clean = Hive::Bot::Format.strip_control_chars(value).strip
        clean = "#{clean[0, limit - 1].rstrip}…" if clean.length > limit
        Hive::Bot::Format.html_escape(clean)
      end

      def web_url(date)
        "#{@web_origin}/digests/#{URI.encode_www_form_component(date.to_s)}"
      end

      def validate_origin(value)
        text = value.to_s.strip.sub(%r{/+\z}, "")
        uri = URI.parse(text)
        unless %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.nil?
          raise Hive::ConfigError, "web.origin must be an http(s) URL for digest delivery"
        end

        text
      rescue URI::InvalidURIError
        raise Hive::ConfigError, "web.origin must be a valid http(s) URL for digest delivery"
      end
    end
  end
end
