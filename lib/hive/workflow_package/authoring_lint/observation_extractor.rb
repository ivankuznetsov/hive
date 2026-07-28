require "shellwords"
require "uri"

module Hive
  module WorkflowPackage
    class AuthoringLint
      class ObservationExtractor
        Observation = Data.define(:host, :dynamic, :path, :line, :column, :raw)
        ObservationEvent = Data.define(
          :rule_id, :severity, :path, :line, :column, :message, :review, :evidence
        )
        ObservationBatch = Data.define(:observations)

        NETWORK_COMMAND = /\b(?:curl|wget|iwr|invoke-webrequest|Net::H[T]TP|URI[.]open|OpenURI)\b/i
        URL_PATTERN = %r{https?://[^\s"'<>|`]+}i
        CURL_VALUE_OPTIONS = %w[
          -A --data --data-ascii --data-binary --data-raw --data-urlencode --form --header
          --output --referer --request --user --user-agent -d -e -F -H -o -u -X
        ].freeze
        WGET_VALUE_OPTIONS = %w[
          --header --output-document --referer --user --user-agent -e -o -O -U
        ].freeze
        POWERSHELL_VALUE_OPTIONS = %w[
          -Headers -Method -OutFile -UserAgent
        ].map(&:downcase).freeze

        private_constant :Observation, :ObservationEvent, :ObservationBatch

        def self.network_command?(value)
          value.to_s.match?(NETWORK_COMMAND)
        end

        def initialize(limits:)
          @limits = limits
        end

        def extract(commands, event_sink:)
          @event_sink = event_sink
          observations = []
          commands.each do |command|
            before = observations.length
            command.raw.to_enum(:scan, URL_PATTERN).each do
              match = Regexp.last_match
              raw = match[0].sub(/[),.;]+\z/, "")
              append_observation(
                observations, observation(command, raw, match.begin(0) + 1)
              )
            end
            unresolved_fallback = observations.length == before
            destination = dynamic_destination(command.raw, unresolved_fallback)
            next unless self.class.network_command?(command.raw) && destination

            append_observation(
              observations, immutable_observation(
                host: destination, dynamic: true, path: command.path,
                line: command.line, column: command.column, raw: destination
              )
            )
          end
          normalized = observations
                       .uniq { |entry| [ entry.host, entry.path, entry.line, entry.column ] }
                       .sort_by { |entry| [ entry.path, entry.line, entry.column, entry.host ] }
          ObservationBatch.new(observations: normalized.freeze).freeze
        end

        private

        def value_option?(client, token)
          case client
          when "curl" then CURL_VALUE_OPTIONS.include?(token)
          when "wget" then WGET_VALUE_OPTIONS.include?(token)
          when "iwr", "invoke-webrequest"
            POWERSHELL_VALUE_OPTIONS.include?(token.downcase)
          else false
          end
        end

        def append_observation(observations, observation)
          if observations.length >= @limits.fetch("max_observations")
            @event_sink.call(event(
              "policy.observation-limit", :error, observation.path,
              observation.line, observation.column,
              "network observation count exceeds lint policy"
            ))
            return
          end
          observations << observation
        end

        def observation(command, raw, offset)
          dynamic = raw.match?(/\$|\{\{|%[A-Za-z_]+%/)
          host = dynamic ? "<dynamic>" : normalize_uri(raw)
          immutable_observation(
            host: host, dynamic: dynamic, path: command.path, line: command.line,
            column: command.column + offset - 1, raw: raw
          )
        rescue URI::InvalidURIError
          immutable_observation(
            host: "<invalid>", dynamic: true, path: command.path,
            line: command.line, column: command.column + offset - 1, raw: raw
          )
        end

        def immutable_observation(host:, dynamic:, path:, line:, column:, raw:)
          Observation.new(
            host: host.to_s.dup.freeze, dynamic: dynamic,
            path: path.to_s.dup.freeze, line: line, column: column,
            raw: raw.to_s.dup.freeze
          ).freeze
        end

        def normalize_uri(raw)
          uri = URI.parse(raw)
          raise URI::InvalidURIError if uri.userinfo || uri.host.nil?

          host = uri.host.downcase.sub(/\.$/, "")
          default_port = uri.scheme.downcase == "https" ? 443 : 80
          uri.port == default_port ? host : "#{host}:#{uri.port}"
        end

        def dynamic_destination(raw, unresolved_fallback)
          tokens = Shellwords.shellsplit(raw)
          command_index = tokens.index { |token| self.class.network_command?(token) }
          return "<unresolved>" if unresolved_fallback && command_index.nil?
          return nil unless command_index

          client = File.basename(tokens.fetch(command_index)).downcase
          arguments = tokens.drop(command_index + 1)
          index = 0
          while index < arguments.length
            token = arguments[index]
            option, attached_value = token.split("=", 2)
            if destination_option?(client, option)
              value = attached_value || arguments[index + 1]
              return "<dynamic>" if dynamic_token?(value)

              index += attached_value ? 1 : 2
              next
            end
            if token.start_with?("-")
              consumes_value = attached_value.nil? && value_option?(client, token)
              index += consumes_value ? 2 : 1
              next
            end
            return "<dynamic>" if dynamic_token?(token)

            index += 1
          end
          "<unresolved>" if unresolved_fallback
        rescue ArgumentError
          "<dynamic>"
        end

        def destination_option?(client, option)
          (client == "curl" && option == "--url") ||
            (%w[iwr invoke-webrequest].include?(client) && option.casecmp?("-Uri"))
        end

        def dynamic_token?(token)
          token.to_s.match?(/\$|\{\{|%[A-Za-z_]+%/)
        end

        def event(rule_id, severity, path, line, column, message,
                  review: false, evidence: nil)
          ObservationEvent.new(
            rule_id: rule_id.freeze, severity: severity, path: path.to_s.freeze,
            line: line, column: column, message: message.freeze,
            review: review, evidence: evidence&.freeze
          ).freeze
        end
      end
    end
  end
end
