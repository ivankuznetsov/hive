require "hive/mcp/backend"
require "hive/mcp/catalog"

module Hive
  module Mcp
    # Validates connector arguments, then calls the in-process Hive backend.
    class Dispatcher
      class UnknownTool < StandardError; end
      class InvalidArguments < StandardError; end

      def initialize(backend: Backend.new)
        @backend = backend
      end

      def catalog
        Catalog::TOOLS.map do |name, spec|
          {
            "name" => name,
            "description" => spec[:description],
            "inputSchema" => {
              "type" => "object",
              "properties" => spec[:properties],
              "required" => spec[:required],
              "additionalProperties" => false
            }
          }
        end
      end

      def call(name, arguments)
        checked = validate!(name, arguments)
        @backend.public_send(name, checked)
      end

      private

      def validate!(name, arguments)
        spec = Catalog::TOOLS[name]
        raise UnknownTool, "unknown tool #{name.inspect}" unless spec

        arguments = {} if arguments.nil?
        unless arguments.is_a?(Hash)
          raise InvalidArguments, "arguments must be an object"
        end

        extra = arguments.keys - spec[:properties].keys
        unless extra.empty?
          raise InvalidArguments, "unknown arguments: #{extra.join(', ')}"
        end

        spec[:required].each do |key|
          next if present?(arguments[key])

          raise InvalidArguments, "missing required argument #{key}"
        end

        spec[:properties].each do |key, property|
          next unless arguments.key?(key) && !arguments[key].nil?

          check_property!(key, arguments[key], property)
        end
        arguments
      end

      def present?(value)
        return false if value.nil?
        return !value.empty? if value.is_a?(String)

        true
      end

      def check_property!(key, value, property)
        case property["type"]
        when "string"
          unless value.is_a?(String) && value.valid_encoding? && !value.include?("\0")
            raise InvalidArguments, "#{key} must be a string"
          end
          min = property["minLength"]
          max = property["maxLength"]
          raise InvalidArguments, "#{key} is too short" if min && value.length < min
          raise InvalidArguments, "#{key} is too long" if max && value.bytesize > max
          if (pattern = property["pattern"]) && !value.match?(Regexp.new(pattern))
            raise InvalidArguments, "#{key} has the wrong shape"
          end
          if property["enum"] && !property["enum"].include?(value)
            raise InvalidArguments, "#{key} must be one of #{property['enum'].join(', ')}"
          end
        when "boolean"
          raise InvalidArguments, "#{key} must be a boolean" unless value == true || value == false
        else
          raise InvalidArguments, "#{key} has an unsupported schema"
        end
      end
    end
  end
end
