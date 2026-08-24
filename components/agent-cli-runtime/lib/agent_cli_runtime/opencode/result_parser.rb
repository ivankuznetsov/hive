require "json"

module AgentCliRuntime
  module OpenCode
    module ResultParser
      MAX_RUN_BYTES = 4 * 1024 * 1024
      # Sanitized exports contain the complete session and every tool result,
      # so their bounded limit must accommodate long implementation sessions.
      MAX_EXPORT_BYTES = 64 * 1024 * 1024
      MAX_FINAL_MESSAGE_BYTES = 1024 * 1024
      MAX_EVENTS = 10_000
      MAX_UNKNOWN_EVENTS = 16
      TERMINAL_REASONS = %w[stop length content-filter].freeze
      KNOWN_EVENT_TYPES = %w[
        step_start step_finish text reasoning tool_use error
      ].freeze
      EVENT_PART_TYPES = {
        "step_start" => "step-start",
        "step_finish" => "step-finish",
        "text" => "text",
        "reasoning" => "reasoning",
        "tool_use" => "tool"
      }.freeze
      AUTH_PATTERN = /auth|credential|api[ _-]?key|unauthorized|forbidden/i
      CONFIGURATION_PATTERN =
        /\b(?:Config(?:uration)?Error|UnknownProvider|UnknownModel|ModelNotFound|RouteUnavailable|VariantUnavailable)\b|\b(?:invalid|unknown|unsupported) (?:configuration|provider|model|route|variant)\b|\b(?:provider|model|route|variant)(?: [^\n]+)? (?:not found|unavailable)\b/i
      UPSTREAM_TIMEOUT_PATTERN =
        /\b(?:upstream\s+)?(?:idle\s+)?timeout\b|\btimed out\b|error_type['"\s:=>]+timeout\b|\bcode['"\s:=>]+504\b/i
      private_constant :KNOWN_EVENT_TYPES, :EVENT_PART_TYPES,
                       :AUTH_PATTERN, :CONFIGURATION_PATTERN,
                       :UPSTREAM_TIMEOUT_PATTERN

      module_function

      def parse_run(stdout)
        bounded_input!(stdout, MAX_RUN_BYTES, "OpenCode run output")
        session_id = nil
        terminal = nil
        texts = []
        unknown = []
        error_seen = false
        event_count = 0

        stdout.each_line.with_index(1) do |line, line_number|
          next if line.strip.empty?

          event_count += 1
          malformed!("OpenCode run output contains too many events") if
            event_count > MAX_EVENTS
          event = parse_json_line(line, line_number)
          type = required_string(event, "type", "event type")
          unless KNOWN_EVENT_TYPES.include?(type)
            additive_session = validate_additive_session!(event, session_id)
            session_id ||= additive_session
            if unknown.length < MAX_UNKNOWN_EVENTS
              unknown << Redactor.diagnostic(
                "unknown OpenCode event #{type}", bytes: 128
              )
            end
            next
          end

          event_session = required_string(event, "sessionID", "event sessionID")
          session_id ||= event_session
          malformed!("OpenCode run sessionID changed within one capture") unless
            session_id == event_session

          if type == "error"
            validate_error!(event)
            error_seen = true
            next
          end

          part = required_hash(event, "part", "event part")
          validate_part!(part, type, session_id)
          message_id = required_string(part, "messageID", "part messageID")
          case type
          when "text"
            text = part["text"]
            malformed!("OpenCode text part must contain text") unless
              text.is_a?(String)
            texts << [ message_id, text ]
          when "step_finish"
            terminal = terminal_part(part, message_id)
          end
        end

        malformed!("OpenCode run emitted an error on a zero exit") if error_seen
        malformed!("OpenCode run has no recognized terminal step") unless terminal
        unless TERMINAL_REASONS.include?(terminal.fetch(:reason))
          malformed!("OpenCode terminal step has an unrecognized finish reason")
        end
        message = texts.filter_map do |message_id, text|
          text if message_id == terminal.fetch(:message_id)
        end.join
        final_message_truncated = message.bytesize > MAX_FINAL_MESSAGE_BYTES
        ParsedRun.new(
          session_id: session_id,
          terminal_message_id: terminal.fetch(:message_id),
          terminal_reason: terminal.fetch(:reason),
          final_message: bounded_string(message, MAX_FINAL_MESSAGE_BYTES),
          final_message_truncated: final_message_truncated,
          preliminary_usage: terminal.fetch(:usage),
          unknown_events: unknown.compact
        )
      rescue MalformedOutput
        raise
      rescue StandardError => e
        raise MalformedOutput, Redactor.diagnostic(e)
      end

      def normalize(captured, requested_route:, profile:)
        unless captured.is_a?(CapturedResult)
          raise ArgumentError, "captured must be an AgentCliRuntime::CapturedResult"
        end
        route = requested_route.is_a?(Route) ?
          requested_route : Route.parse(requested_route)
        termination = captured.termination
        return failure_outcome(
          profile, route, termination, :timed_out, "OpenCode run timed out"
        ) if termination.timed_out
        return failure_outcome(
          profile, route, termination, :cancelled, "OpenCode run was cancelled"
        ) if termination.cancelled
        unless termination.success?
          kind, diagnostic = classify_failure(captured)
          return failure_outcome(
            profile, route, termination, kind, diagnostic
          )
        end

        parsed = parse_run(captured.stdout)
        inspection = parse_inspection(
          captured.inspection_output,
          session_id: parsed.session_id,
          message_id: parsed.terminal_message_id
        )
        actual = inspection.fetch(:route)
        NormalizedOutcome.new(
          provider: profile.name,
          launcher_identity: profile.launcher_identity,
          kind: :completed,
          termination: termination,
          final_message: parsed.final_message,
          final_message_truncated: parsed.final_message_truncated,
          identity: RouteIdentity.new(requested: route, actual: actual),
          usage: inspection.fetch(:usage),
          diagnostic: nil,
          unknown_events: parsed.unknown_events,
          session_id: parsed.session_id,
          message_id: parsed.terminal_message_id
        )
      rescue MalformedOutput => e
        malformed_outcome(profile, requested_route, captured, e)
      end

      def parse_inspection(output, session_id:, message_id:)
        if output.nil?
          malformed!("OpenCode sanitized export evidence is required")
        end
        bounded_input!(output, MAX_EXPORT_BYTES, "OpenCode sanitized export")
        export = JSON.parse(output)
        malformed!("OpenCode sanitized export must be an object") unless
          export.is_a?(Hash)
        info = required_hash(export, "info", "export info")
        unless required_string(info, "id", "export session id") == session_id
          malformed!("OpenCode sanitized export session does not match the run")
        end
        messages = export["messages"]
        malformed!("OpenCode sanitized export messages must be an array") unless
          messages.is_a?(Array)
        assistant = nil
        messages.each do |message|
          next unless message.is_a?(Hash) && message["info"].is_a?(Hash)

          record = message.fetch("info")
          next unless record["id"] == message_id

          if assistant
            malformed!("OpenCode sanitized export must contain one terminal assistant record")
          end
          assistant = record
        end
        unless assistant
          malformed!("OpenCode sanitized export must contain one terminal assistant record")
        end
        unless assistant["role"] == "assistant" &&
               assistant["sessionID"] == session_id
          malformed!("OpenCode sanitized export terminal record is not correlated")
        end
        unless TERMINAL_REASONS.include?(assistant["finish"])
          malformed!("OpenCode sanitized export terminal record is incomplete")
        end
        provider = required_string(
          assistant, "providerID", "assistant providerID"
        )
        model = required_string(assistant, "modelID", "assistant modelID")
        tokens = assistant["tokens"]
        unless tokens.nil? || tokens.is_a?(Hash)
          malformed!("OpenCode assistant tokens must be an object")
        end
        tokens ||= {}
        cache = tokens["cache"]
        unless cache.nil? || cache.is_a?(Hash)
          malformed!("OpenCode assistant cache tokens must be an object")
        end
        cache ||= {}

        {
          route: Route.new(provider:, model:),
          usage: NormalizedUsage.new(
            input: numeric(tokens, "input", integer: true),
            output: numeric(tokens, "output", integer: true),
            cache_read: numeric(cache, "read", integer: true),
            cache_write: numeric(cache, "write", integer: true),
            reasoning: numeric(tokens, "reasoning", integer: true),
            input_includes_cache_read: cache.key?("read") ? true : nil,
            input_includes_cache_write: cache.key?("write") ? true : nil,
            output_includes_reasoning: tokens.key?("reasoning") ? false : nil,
            provider_reported_cost: numeric(assistant, "cost", integer: false)
          )
        }.freeze
      rescue JSON::ParserError => e
        raise MalformedOutput,
              Redactor.diagnostic("OpenCode sanitized export is malformed: #{e.message}")
      rescue ArgumentError => e
        raise MalformedOutput, Redactor.diagnostic(e)
      end

      def terminal_part(part, message_id)
        reason = required_string(part, "reason", "terminal reason")
        tokens = required_hash(part, "tokens", "terminal tokens")
        cache = required_hash(tokens, "cache", "terminal cache tokens")
        {
          message_id: message_id,
          reason: reason,
          usage: NormalizedUsage.new(
            input: required_numeric(tokens, "input", integer: true),
            output: required_numeric(tokens, "output", integer: true),
            cache_read: required_numeric(cache, "read", integer: true),
            cache_write: required_numeric(cache, "write", integer: true),
            reasoning: required_numeric(tokens, "reasoning", integer: true),
            input_includes_cache_read: true,
            input_includes_cache_write: true,
            output_includes_reasoning: false,
            provider_reported_cost: required_numeric(part, "cost", integer: false)
          )
        }.freeze
      rescue ArgumentError => e
        malformed!(e.message)
      end
      private_class_method :terminal_part

      def validate_part!(part, event_type, session_id)
        expected = EVENT_PART_TYPES.fetch(event_type)
        unless part["type"] == expected && part["sessionID"] == session_id
          malformed!("OpenCode #{event_type} part is not correlated")
        end
        required_string(part, "id", "part id")
      end
      private_class_method :validate_part!

      def validate_error!(event)
        error = required_hash(event, "error", "error event payload")
        required_string(error, "name", "error name")
        data = required_hash(error, "data", "error data")
        required_string(data, "message", "error message")
      end
      private_class_method :validate_error!

      def validate_additive_session!(event, session_id)
        value = event["sessionID"]
        return nil if value.nil?
        unless value.is_a?(String) && !value.empty? && !value.include?("\0")
          malformed!("OpenCode additive event sessionID must be a non-empty string")
        end
        return value if session_id.nil? || value == session_id

        malformed!("OpenCode additive event session does not match the run")
      end
      private_class_method :validate_additive_session!

      def classify_failure(captured)
        details = error_details(captured.stdout)
        diagnostic = Redactor.diagnostic(
          [ *details, captured.stderr ].reject(&:empty?).join("\n")
        ) || "OpenCode CLI exited without diagnostic evidence"
        corpus = [ *details, captured.stderr ].join(" ")
        kind =
          if corpus.match?(AUTH_PATTERN)
            :authentication_failure
          elsif corpus.match?(CONFIGURATION_PATTERN)
            :configuration_failure
          elsif corpus.match?(UPSTREAM_TIMEOUT_PATTERN)
            :timed_out
          else
            :cli_failure
          end
        [ kind, diagnostic ]
      end
      private_class_method :classify_failure

      def error_details(stdout)
        return [] if stdout.bytesize > MAX_RUN_BYTES

        stdout.each_line.filter_map do |line|
          event = JSON.parse(line)
          next unless event.is_a?(Hash) && event["type"] == "error"

          error = event["error"]
          next unless error.is_a?(Hash)

          name = error["name"].to_s
          data = error["data"]
          message = data.is_a?(Hash) ? data["message"].to_s : ""
          [ name, message ].reject(&:empty?).join(": ")
        rescue JSON::ParserError
          nil
        end
      end
      private_class_method :error_details

      def failure_outcome(profile, route, termination, kind, diagnostic)
        NormalizedOutcome.new(
          provider: profile.name,
          launcher_identity: profile.launcher_identity,
          kind: kind,
          termination: termination,
          identity: RouteIdentity.new(requested: route),
          diagnostic: Redactor.diagnostic(diagnostic)
        )
      end
      private_class_method :failure_outcome

      def malformed_outcome(profile, requested_route, captured, error)
        route = requested_route.is_a?(Route) ?
          requested_route : Route.parse(requested_route)
        NormalizedOutcome.new(
          provider: profile.name,
          launcher_identity: profile.launcher_identity,
          kind: :malformed_output,
          termination: captured.termination,
          identity: RouteIdentity.new(requested: route),
          diagnostic: Redactor.diagnostic(error)
        )
      end
      private_class_method :malformed_outcome

      def parse_json_line(line, line_number)
        value = JSON.parse(line)
        malformed!("OpenCode event on line #{line_number} must be an object") unless
          value.is_a?(Hash)
        value
      rescue JSON::ParserError
        malformed!("OpenCode run output has malformed JSON on line #{line_number}")
      end
      private_class_method :parse_json_line

      def required_hash(hash, key, label)
        value = hash[key]
        malformed!("OpenCode #{label} must be an object") unless value.is_a?(Hash)
        value
      end
      private_class_method :required_hash

      def required_string(hash, key, label)
        value = hash[key]
        unless value.is_a?(String) && !value.empty? && !value.include?("\0")
          malformed!("OpenCode #{label} must be a non-empty string")
        end
        value
      end
      private_class_method :required_string

      def required_numeric(hash, key, integer:)
        malformed!("OpenCode #{key} is required") unless hash.key?(key)
        numeric(hash, key, integer:)
      end
      private_class_method :required_numeric

      def numeric(hash, key, integer:)
        return nil unless hash.key?(key)

        value = hash[key]
        valid = integer ? value.is_a?(Integer) : value.is_a?(Numeric)
        valid &&= value.finite? if value.respond_to?(:finite?)
        unless valid && value >= 0
          malformed!("OpenCode #{key} must be a non-negative number")
        end
        value
      end
      private_class_method :numeric

      def bounded_input!(value, bytes, label)
        unless value.is_a?(String) && value.bytesize <= bytes
          malformed!("#{label} exceeds the bounded input size")
        end
      end
      private_class_method :bounded_input!

      def bounded_string(value, bytes)
        return value if value.bytesize <= bytes

        value.byteslice(0, bytes).to_s
             .force_encoding(Encoding::UTF_8)
             .scrub("?")
      end
      private_class_method :bounded_string

      def malformed!(message)
        raise MalformedOutput, Redactor.diagnostic(message)
      end
      private_class_method :malformed!
    end
  end
end
