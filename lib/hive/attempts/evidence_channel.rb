require "digest"
require "json"
require "hive/attempts/record"
require "hive/output_reference"

module Hive
  module Attempts
    # Capability-bound, write-once transport for a sanitized provider signal.
    # Signals remain attempt evidence so a provider-class retry can name the
    # route that failed; they do not update shared provider usability state.
    module EvidenceChannel
      MAX_BYTES = 4 * 1024
      SIGNAL_KEYS = %w[failure_class provenance reset_hint_seconds scope].freeze
      SCOPE_KEYS = %w[kind model provider_account_id].freeze
      ROUTE_KEYS = %w[adapter launch_binding_id model provider_account_id route_id].freeze

      class Writer
        def self.for_fd(value, route:)
          io = IO.for_fd(Integer(value), "w", autoclose: true)
          io.close_on_exec = true
          new(io: io, route: route)
        rescue ArgumentError, TypeError, Errno::EBADF
          raise RepositoryError, "attempt evidence descriptor is unavailable"
        end

        def initialize(io:, route:)
          @io = io
          @route = route
          @written = false
        end

        def write(signal)
          return false if @written || @io.closed?

          normalized = EvidenceChannel.validate_signal(signal, route: @route)
          payload = JSON.generate(normalized)
          raise RepositoryError, "attempt provider evidence is too large" if payload.bytesize > MAX_BYTES

          @io.write("#{payload}\n")
          @io.flush
          @written = true
          @io.close
          true
        rescue Errno::EPIPE, IOError
          @written = true
          false
        end

        def close
          @io.close unless @io.closed?
        rescue IOError
          nil
        end
      end

      module_function

      def read(io, route:)
        bytes = io.read(MAX_BYTES + 2)
        return nil if bytes.nil? || bytes.empty? || bytes.bytesize > MAX_BYTES + 1
        return nil unless bytes.end_with?("\n") && bytes.count("\n") == 1

        validate_signal(JSON.parse(bytes), route: route)
      rescue JSON::ParserError, RepositoryError, IOError, SystemCallError
        nil
      ensure
        io&.close unless io&.closed?
      end

      def validate_signal(signal, route:)
        unless signal.is_a?(Hash) && signal.keys.map(&:to_s).sort == SIGNAL_KEYS.sort
          raise RepositoryError, "attempt provider evidence has unexpected fields"
        end
        value = signal.to_h { |key, child| [ key.to_s, child ] }
        normalized_route = validate_route(route)
        scope = validate_scope(value.fetch("scope"))
        allowed = scope.fetch("kind") == "provider_account" ?
          Record::PROVIDER_FAILURE_CLASSES : Record::MODEL_FAILURE_CLASSES
        failure_class = value.fetch("failure_class").to_s
        unless allowed.include?(failure_class)
          raise RepositoryError, "attempt provider evidence class is invalid"
        end
        provenance = value.fetch("provenance").to_s
        unless Record::TRUSTED_PROVENANCE.include?(provenance)
          raise RepositoryError, "attempt provider evidence provenance is invalid"
        end
        unless scope.fetch("provider_account_id") == normalized_route.fetch("provider_account_id") &&
               (scope.fetch("kind") == "provider_account" ||
                scope.fetch("model") == normalized_route.fetch("model"))
          raise RepositoryError, "attempt provider evidence scope does not match its route"
        end
        hint = value["reset_hint_seconds"]
        unless hint.nil? || (hint.is_a?(Integer) && hint.between?(0, Record::MAX_RESET_HINT_SECONDS))
          raise RepositoryError, "attempt provider evidence reset hint is invalid"
        end

        {
          "failure_class" => failure_class.freeze,
          "scope" => deep_freeze(scope),
          "provenance" => provenance.freeze,
          "reset_hint_seconds" => hint
        }.freeze
      end

      def materialize(signal, record:, source_reference:)
        return nil unless signal

        routing = record.respond_to?(:[]) ? record["routing"] : record.fetch("routing")
        route = validate_route(routing.fetch("route"))
        normalized = validate_signal(signal, route: route)
        Hive::OutputReference.validate_shape!(source_reference)
        fields = {
          "failure_class" => normalized.fetch("failure_class"),
          "scope" => normalized.fetch("scope"),
          "provenance" => normalized.fetch("provenance"),
          "route_id" => route.fetch("route_id"),
          "reset_hint_seconds" => normalized.fetch("reset_hint_seconds")
        }
        deep_freeze(
          fields.merge(
            "fingerprint" => Digest::SHA256.hexdigest(JSON.generate(canonical_value(fields))),
            "source_reference" => deep_copy(source_reference)
          )
        )
      rescue KeyError, Hive::InvalidOutputReference => error
        raise RepositoryError, "attempt provider evidence rejected: #{error.class.name.split('::').last}"
      end

      def validate_scope(value)
        unless value.is_a?(Hash) && value.keys.map(&:to_s).sort == SCOPE_KEYS
          raise RepositoryError, "attempt provider evidence scope is invalid"
        end
        scope = value.to_h { |key, child| [ key.to_s, child ] }
        kind = scope.fetch("kind").to_s
        account = identifier(scope.fetch("provider_account_id"), "provider account")
        model = scope["model"]
        unless %w[provider_account model].include?(kind) &&
               ((kind == "provider_account" && model.nil?) ||
                (kind == "model" && !model.nil?))
          raise RepositoryError, "attempt provider evidence scope is invalid"
        end

        {
          "kind" => kind.freeze,
          "provider_account_id" => account,
          "model" => model && identifier(model, "model")
        }
      end
      private_class_method :validate_scope

      def validate_route(value)
        unless value.is_a?(Hash) && (ROUTE_KEYS - value.keys).empty?
          raise RepositoryError, "attempt provider route is invalid"
        end
        value.to_h do |key, child|
          [ key.to_s, ROUTE_KEYS.include?(key.to_s) ? identifier(child, "route") : child ]
        end
      end
      private_class_method :validate_route

      def identifier(value, label)
        string = value.to_s
        unless !string.empty? && string.bytesize <= Record::MAX_IDENTIFIER_BYTES &&
               string.valid_encoding? && !string.match?(/[\u0000-\u001f\u007f]/)
          raise RepositoryError, "attempt provider #{label} is invalid"
        end
        string.freeze
      end
      private_class_method :identifier

      def canonical_value(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [ key, canonical_value(value.fetch(key)) ] }
        else
          value
        end
      end
      private_class_method :canonical_value

      def deep_copy(value)
        case value
        when Hash
          value.to_h { |key, child| [ key.to_s.dup, deep_copy(child) ] }
        when String
          value.dup
        else
          value
        end
      end
      private_class_method :deep_copy

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| key.freeze; deep_freeze(child) }
        when String
          value.freeze
        end
        value.freeze
      end
      private_class_method :deep_freeze
    end
  end
end
