require "base64"
require "digest"
require "json"
require "openssl"
require "time"
require "hive/secret_patterns"
require "hive/task_workspace"

module Hive
  module TaskWorkspace
    # Deterministic, bounded projection of authoritative task activity and
    # fail-soft operational telemetry. The projector never grants authority to
    # a legacy event: journal records win correlation conflicts and raw legacy
    # messages are deliberately reduced to a closed summary vocabulary.
    class Timeline
      GROUP_WINDOW_SECONDS = 60
      MATERIAL_ACTIVITY_KINDS = Hive::TaskJournal::ACTIVITY_KINDS.freeze
      MATERIAL_JOURNAL_TYPES = %w[
        condition_observed generation_advanced commit_generation_advanced
        operator_action implementation_identity_captured
        implementation_identity_backfilled implementation_identity_fallback
        implementation_stage_resolved activity_recorded
      ].freeze
      MATERIAL_EVENT_TYPES = %w[
        stage_enter stage_exit agent_start agent_end error round_waiting
        round_complete clean_exit_auto_committed claude_completion_fallback
      ].freeze
      SAFE_DETAIL_KEYS = %w[
        session_id role provider requested_model actual_model requested_effort
        health outcome timeout_sec timed_out resource_kind retry_at question_id
        answer_id decision approval commit_oid branch pr_number pr_state to_stage
        check_state merge_state context_kind
      ].freeze

      class InvalidCursor < Hive::Error; end

      class CursorCodec
        MAX_TOKEN_BYTES = 8 * 1024

        def initialize(secret:)
          @secret = secret.to_s.b
          raise ArgumentError, "timeline cursor secret must be at least 32 bytes" if @secret.bytesize < 32
        end

        def encode(payload)
          encoded = Base64.urlsafe_encode64(
            Hive::TaskWorkspace.canonical_json(payload), padding: false
          )
          signature = OpenSSL::HMAC.hexdigest("SHA256", @secret, encoded)
          "#{encoded}.#{signature}"
        end

        def decode(token)
          value = token.to_s
          raise InvalidCursor, "timeline cursor is missing" if value.empty?
          raise InvalidCursor, "timeline cursor is too large" if value.bytesize > MAX_TOKEN_BYTES

          encoded, signature, extra = value.split(".", 3)
          raise InvalidCursor, "timeline cursor is malformed" if encoded.to_s.empty? ||
            signature.to_s.empty? || extra
          expected = OpenSSL::HMAC.hexdigest("SHA256", @secret, encoded)
          unless signature.bytesize == expected.bytesize &&
                 OpenSSL.fixed_length_secure_compare(signature, expected)
            raise InvalidCursor, "timeline cursor signature is invalid"
          end
          payload = JSON.parse(Base64.urlsafe_decode64(encoded))
          raise InvalidCursor, "timeline cursor payload is invalid" unless payload.is_a?(Hash)

          payload
        rescue ArgumentError, JSON::ParserError
          raise InvalidCursor, "timeline cursor is malformed"
        end
      end

      def initialize(task_identity:, journal_records:, event_records:, legacy_records: [],
                     source_positions: {}, source_truncated: {}, limits: Limits.new,
                     cursor_codec:, clock: -> { Time.now.utc })
        @task_identity = stringify(task_identity)
        @journal_records = Array(journal_records)
        @event_records = Array(event_records)
        @legacy_records = Array(legacy_records)
        @source_positions = stringify(source_positions)
        @source_truncated = stringify(source_truncated)
        @limits = limits
        @cursor_codec = cursor_codec
        @clock = clock
        @task_fingerprint = Digest::SHA256.hexdigest(
          Hive::TaskWorkspace.canonical_json(
            "project" => @task_identity["project"],
            "slug" => @task_identity["slug"],
            "task_id" => @task_identity["task_id"] || @task_identity["id"]
          )
        )
      end

      def call(cursor: nil, raw_cursor: nil)
        return raw_group(raw_cursor) if raw_cursor

        diagnostics = []
        items = normalized_items(diagnostics)
        material, noise = items.partition { |item| item["material"] }
        material = deduplicate_material(material)
        material.sort_by! { |item| sort_key(item) }
        material.reverse!
        material = apply_cursor(material, cursor) if cursor

        material_limit = @limits.fetch(:timeline_material_items)
        remaining_material = material.drop(material_limit)
        material = material.first(material_limit)
        groups = group_noise(noise).first(@limits.fetch(:timeline_noise_groups))
        material, groups, byte_truncated, material_byte_truncated, observed_bytes =
          enforce_byte_budget(material, groups)

        material_truncated = remaining_material.any? || material_byte_truncated ||
                             @source_truncated.values.any? { |value| value == true }
        noise_truncated = group_noise(noise).length > groups.length
        truncated = material_truncated || noise_truncated || byte_truncated
        diagnostics << cap_diagnostic(
          "timeline_material_items", @limits.fetch(:timeline_material_items),
          material.length + remaining_material.length
        ) if material_truncated
        diagnostics << cap_diagnostic(
          "timeline_noise_groups", @limits.fetch(:timeline_noise_groups),
          group_noise(noise).length
        ) if noise_truncated
        diagnostics << cap_diagnostic(
          "timeline_bytes", @limits.fetch(:timeline_bytes), observed_bytes
        ) if byte_truncated

        older_cursor = if material_truncated && material.any?
          encode_cursor(
            "kind" => "material", "before" => sort_key(material.last),
            "source_before" => @source_positions
          )
        end
        state = if items.empty?
          diagnostics.empty? ? "missing" : "unavailable"
        elsif truncated || diagnostics.any?
          "partial"
        else
          "current"
        end
        Hive::TaskWorkspace.safe_value!(
          "state" => state,
          "records" => material.map { |item| item.reject { |key, _| key == "material" } },
          "noise_groups" => groups,
          "older_cursor" => older_cursor,
          "diagnostics" => diagnostics,
          "truncated" => truncated,
          "observed_bytes" => observed_bytes
        )
      end

      private

      public

      def source_before(token)
        cursor = decode_cursor(token, expected_kind: "material")
        stringify(cursor["source_before"] || {})
      end

      private

      def normalized_items(diagnostics)
        journal = @journal_records.filter_map do |record|
          normalize_journal(record, diagnostics)
        end
        events = @event_records.filter_map.with_index do |record, index|
          normalize_event(record, index, diagnostics)
        end
        legacy = @legacy_records.filter_map.with_index do |record, index|
          normalize_legacy(record, index, diagnostics)
        end
        journal + events + legacy
      end

      def normalize_journal(value, diagnostics)
        record = stringify(value)
        event_type = record["event_type"].to_s
        return nil unless MATERIAL_JOURNAL_TYPES.include?(event_type)

        kind = event_type == "activity_recorded" ?
          record.dig("payload", "activity_kind").to_s : event_type
        if event_type == "activity_recorded" && !MATERIAL_ACTIVITY_KINDS.include?(kind)
          diagnostics << diagnostic("task_journal", "malformed_record", "invalid activity kind")
          return nil
        end

        occurred = parse_time(record["occurred_at"], "task_journal", diagnostics)
        ingested = parse_time(
          record["observed_at"] || record.dig("provenance", "ingested_at") || record["occurred_at"],
          "task_journal", diagnostics
        )
        return nil unless occurred && ingested

        source = record.dig("provenance", "source").to_s
        source = "task_journal" if source.empty?
        payload = stringify(record["payload"] || {})
        {
          "event_id" => safe_identifier(record["event_id"], prefix: "journal"),
          "kind" => kind,
          "summary" => safe_reason(record["reason"], fallback: label(kind)),
          "material" => true,
          "source" => "task_journal",
          "source_kind" => source,
          "source_quality" => "authoritative",
          "occurred_at" => iso(occurred),
          "ingested_at" => iso(ingested),
          "ordering_at" => iso(occurred),
          "external_clock_unverified" => false,
          "task_generation" => record["task_generation"],
          "attempt_id" => record["attempt_id"],
          "stage" => record["stage"],
          "correlation_id" => payload["correlation_id"],
          "operation_id" => payload["operation_id"],
          "supersedes_event_id" => payload["supersedes_event_id"],
          "details" => safe_details(payload),
          "source_refs" => [ safe_identifier(record["event_id"], prefix: "journal") ]
        }
      rescue StandardError => e
        diagnostics << diagnostic("task_journal", "malformed_record", e.class.name)
        nil
      end

      def normalize_event(value, index, diagnostics)
        record = stringify(value)
        kind = record["event_type"].to_s
        return nil if kind.empty?

        occurred = parse_time(record["occurred_at"] || record["ts"], "event_stream", diagnostics)
        ingested = parse_time(record["observed_at"] || record["ingested_at"] || record["ts"],
                              "event_stream", diagnostics)
        return nil unless occurred && ingested

        external = %w[provider_external github].include?(record["source"].to_s)
        verified = external && (occurred - ingested).abs <= @limits.fetch(:timeline_clock_skew_seconds)
        ordering = external && !verified ? ingested : occurred
        event_id = safe_identifier(record["event_id"], prefix: "event-#{index}")
        {
          "event_id" => event_id,
          "kind" => kind,
          "summary" => label(kind),
          "material" => MATERIAL_EVENT_TYPES.include?(kind) || MATERIAL_ACTIVITY_KINDS.include?(kind),
          "source" => "event_stream",
          "source_kind" => record["source"].to_s.empty? ? "event_stream" : record["source"].to_s,
          "source_quality" => "observational",
          "occurred_at" => iso(occurred),
          "ingested_at" => iso(ingested),
          "ordering_at" => iso(ordering),
          "external_clock_unverified" => external && !verified,
          "task_generation" => record["task_generation"],
          "attempt_id" => record["attempt_id"],
          "stage" => record["stage"],
          "correlation_id" => record["correlation_id"],
          "operation_id" => record["operation_id"],
          "supersedes_event_id" => record["supersedes_event_id"],
          "details" => safe_details(record),
          "source_refs" => [ event_id ]
        }
      rescue StandardError => e
        diagnostics << diagnostic("event_stream", "malformed_record", e.class.name)
        nil
      end

      def normalize_legacy(value, index, diagnostics)
        record = stringify(value)
        record["event_type"] ||= record["kind"] || "legacy_evidence"
        record["event_id"] ||= "legacy-#{index}"
        record["source"] ||= "legacy"
        record["ts"] ||= record["occurred_at"] || record["observed_at"]
        item = normalize_event(record, index, diagnostics)
        return nil unless item

        item["material"] = true
        item["source"] = "legacy"
        item["source_kind"] = "legacy"
        item["source_quality"] = "partial"
        item
      end

      def deduplicate_material(items)
        grouped = items.group_by { |item| correlation_key(item) }
        grouped.values.map do |duplicates|
          ranked = duplicates.sort_by do |item|
            [ item["source"] == "task_journal" ? 0 : 1, sort_key(item) ]
          end
          primary = ranked.first.dup
          primary["source_refs"] = duplicates.flat_map { |item| item["source_refs"] }.uniq.sort
          if duplicates.map { |item| item["source"] }.uniq.length > 1
            primary["cross_source_duplicate"] = true
          end
          primary
        end
      end

      def correlation_key(item)
        correlation = item["correlation_id"].to_s
        operation = item["operation_id"].to_s
        return "correlation:#{item['kind']}:#{correlation}" unless correlation.empty?
        return "operation:#{item['kind']}:#{operation}" unless operation.empty?

        "event:#{item['source']}:#{item['event_id']}"
      end

      def group_noise(items)
        ordered = items.sort_by { |item| sort_key(item) }
        groups = []
        ordered.each do |item|
          signature = Digest::SHA256.hexdigest(
            [ item["kind"], item["summary"], item["source_kind"] ].join("\0")
          )
          current = groups.last
          item_time = Time.iso8601(item.fetch("ordering_at"))
          if current && current["__signature"] == signature &&
             item_time - Time.iso8601(current.fetch("first_at")) <= GROUP_WINDOW_SECONDS
            current["count"] += 1
            current["last_at"] = item.fetch("ordering_at")
            current["__members"] << item
          else
            groups << {
              "group_id" => Digest::SHA256.hexdigest(
                "#{signature}\0#{item.fetch('ordering_at')}\0#{item.fetch('event_id')}"
              )[0, 24],
              "kind" => item["kind"], "summary" => item["summary"],
              "source_kind" => item["source_kind"], "count" => 1,
              "first_at" => item.fetch("ordering_at"),
              "last_at" => item.fetch("ordering_at"),
              "__signature" => signature, "__members" => [ item ]
            }
          end
        end
        groups.reverse.map do |group|
          group = group.dup
          group.delete("__members")
          group.delete("__signature")
          group["raw_cursor"] = encode_cursor(
            "kind" => "raw_group", "group_id" => group.fetch("group_id")
          )
          group
        end
      end

      def raw_group(token)
        cursor = decode_cursor(token, expected_kind: "raw_group")
        diagnostics = []
        items = normalized_items(diagnostics).reject { |item| item["material"] }
        group = grouped_noise_with_members(items).find do |candidate|
          candidate.fetch("group_id") == cursor.fetch("group_id")
        end
        raise InvalidCursor, "timeline noise group is unavailable" unless group

        members = group.fetch("members")
        limit = @limits.fetch(:timeline_raw_members)
        records = members.first(limit).map do |item|
          item.reject { |key, _| key == "material" }
        end
        {
          "state" => diagnostics.empty? ? "current" : "partial",
          "records" => records,
          "group_id" => cursor.fetch("group_id"),
          "diagnostics" => diagnostics,
          "truncated" => members.length > limit,
          "observed_count" => members.length
        }
      end

      def apply_cursor(items, token)
        cursor = decode_cursor(token, expected_kind: "material")
        before = Array(cursor["before"])
        raise InvalidCursor, "timeline cursor boundary is invalid" unless before.length == 3

        items.select { |item| (sort_key(item) <=> before) == -1 }
      end

      def encode_cursor(payload)
        @cursor_codec.encode(payload.merge("task" => @task_fingerprint, "version" => 1))
      end

      def decode_cursor(token, expected_kind:)
        cursor = @cursor_codec.decode(token)
        unless cursor["version"] == 1 && cursor["task"] == @task_fingerprint &&
               cursor["kind"] == expected_kind
          raise InvalidCursor, "timeline cursor does not match this task or operation"
        end
        cursor
      end

      def enforce_byte_budget(material, groups)
        limit = @limits.fetch(:timeline_bytes)
        bytes = 0
        accepted_material = []
        accepted_groups = []
        truncated = false
        material_truncated = false
        material.each do |item|
          size = JSON.generate(item).bytesize
          if bytes + size > limit
            truncated = true
            material_truncated = true
            break
          end
          accepted_material << item
          bytes += size
        end
        groups.each do |group|
          size = JSON.generate(group).bytesize
          if bytes + size > limit
            truncated = true
            break
          end
          accepted_groups << group
          bytes += size
        end
        [ accepted_material, accepted_groups, truncated, material_truncated, bytes ]
      end

      def grouped_noise_with_members(items)
        groups = group_noise(items)
        by_group = groups.to_h { |group| [ group.fetch("group_id"), group.merge("members" => []) ] }
        items.each do |item|
          group = groups.find do |candidate|
            candidate["kind"] == item["kind"] && candidate["summary"] == item["summary"] &&
              candidate["source_kind"] == item["source_kind"] &&
              Time.iso8601(item.fetch("ordering_at")).between?(
                Time.iso8601(candidate.fetch("first_at")),
                Time.iso8601(candidate.fetch("last_at"))
              )
          end
          by_group.fetch(group.fetch("group_id"))["members"] << item if group
        end
        by_group.values
      end

      def sort_key(item)
        [ item.fetch("ordering_at"), item.fetch("event_id"), item.fetch("source") ]
      end

      def safe_details(payload)
        payload.each_with_object({}) do |(key, value), result|
          next unless SAFE_DETAIL_KEYS.include?(key.to_s)
          next unless value.nil? || value.is_a?(String) || value.is_a?(Numeric) ||
            value == true || value == false

          result[key.to_s] = value.is_a?(String) ? safe_reason(value, fallback: nil) : value
        end
      end

      def safe_reason(value, fallback:)
        text = Hive::SecretPatterns.redact(value.to_s).scrub
        text = fallback.to_s if text.empty?
        text = text.byteslice(0, 4 * 1024).to_s.scrub
        text.gsub(%r{(?<![A-Za-z0-9])/(?:[^\s/]+/)*[^\s]*}, "[REDACTED:path]")
      end

      def label(kind)
        kind.to_s.tr("_", " ").sub(/\A./, &:upcase)
      end

      def parse_time(value, source, diagnostics)
        Time.iso8601(value.to_s).utc
      rescue ArgumentError, TypeError
        diagnostics << diagnostic(source, "invalid_timestamp", nil)
        nil
      end

      def iso(time)
        time.utc.iso8601(6)
      end

      def safe_identifier(value, prefix:)
        identifier = value.to_s
        return identifier if identifier.match?(%r{\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}\z})

        "#{prefix}-#{Digest::SHA256.hexdigest(identifier)[0, 16]}"
      end

      def stringify(value)
        value.to_h.transform_keys(&:to_s)
      end

      def diagnostic(source, reason, detail)
        result = { "source" => source, "reason" => reason }
        result["detail"] = detail if detail
        result
      end

      def cap_diagnostic(name, limit, observed)
        {
          "source" => "task_journal", "reason" => "limit_exhausted",
          "cap" => name, "limit" => limit, "observed" => observed
        }
      end
    end
  end
end
