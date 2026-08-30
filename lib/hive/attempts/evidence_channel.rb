require "json"
require "hive/provider_health/evidence"

module Hive
  module Attempts
    # Capability-bound, write-once transport for a sanitized provider signal.
    # The descriptor is separate from stdout/stderr and is inherited only by
    # the authenticated durable Hive worker. Provider subprocesses cannot
    # inherit it after Context installs the close-on-exec writer.
    module EvidenceChannel
      MAX_BYTES = 4 * 1024
      SIGNAL_KEYS = %w[failure_class provenance reset_hint_seconds scope].freeze

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
        scope = Hive::ProviderHealth.scope_from_h(value.fetch("scope"))
        route_identity = route_identity(route)
        allowed = scope.provider_account? ?
          Hive::ProviderHealth::PROVIDER_FAILURE_CLASSES : Hive::ProviderHealth::MODEL_FAILURE_CLASSES
        unless allowed.include?(value.fetch("failure_class").to_s)
          raise RepositoryError, "attempt provider evidence class is invalid"
        end
        unless Hive::ProviderHealth::TRUSTED_PROVENANCE.include?(value.fetch("provenance").to_s)
          raise RepositoryError, "attempt provider evidence provenance is invalid"
        end
        unless scope.account_id == route_identity.account_id &&
               (!scope.model? || scope.model_id == route_identity.model_id)
          raise RepositoryError, "attempt provider evidence scope does not match its route"
        end
        hint = value["reset_hint_seconds"]
        unless hint.nil? || (hint.is_a?(Integer) && hint.between?(0, Hive::ProviderHealth::MAX_RESET_HINT_SECONDS))
          raise RepositoryError, "attempt provider evidence reset hint is invalid"
        end

        {
          "failure_class" => value.fetch("failure_class").to_s.freeze,
          "scope" => scope.to_h,
          "provenance" => value.fetch("provenance").to_s.freeze,
          "reset_hint_seconds" => hint
        }.freeze
      rescue KeyError, Hive::ProviderHealth::Error => e
        raise RepositoryError, "attempt provider evidence rejected: #{e.class.name.split('::').last}"
      end

      def materialize(signal, record:, source_reference:)
        return nil unless signal

        routing = if record.respond_to?(:[])
          record["routing"]
        else
          record.fetch("routing")
        end
        route = route_identity(routing.fetch("route"))
        scope = Hive::ProviderHealth.scope_from_h(signal.fetch("scope"))
        Hive::ProviderHealth::Evidence.new(
          scope: scope,
          failure_class: signal.fetch("failure_class"),
          provenance: signal.fetch("provenance"),
          route: route,
          reset_hint_seconds: signal.fetch("reset_hint_seconds"),
          source_reference: source_reference,
          attempt_id: record.attempt_id
        ).to_h
      end

      def route_identity(route)
        Hive::ProviderHealth::RouteIdentity.from_h(route)
      rescue KeyError, Hive::ProviderHealth::Error => e
        raise RepositoryError, "attempt provider route rejected: #{e.class.name.split('::').last}"
      end
      private_class_method :route_identity
    end
  end
end
