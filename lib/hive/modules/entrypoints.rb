module Hive
  module Modules
    module Entrypoints
      @handlers = {}

      module_function

      def register(id, callable = nil, &block)
        handler = callable || block
        unless id.to_s.match?(/\A[a-z0-9][a-z0-9.-]*\z/) && handler.respond_to?(:call)
          raise ArgumentError, "module entrypoint registration is malformed"
        end
        @handlers[id.to_s] = handler
      end

      def fetch(id)
        @handlers.fetch(id.to_s) do
          raise Hive::ConfigError, "module entrypoint #{id.inspect} is not registered"
        end
      end

      def reset!
        @handlers.clear
      end
    end
  end
end
