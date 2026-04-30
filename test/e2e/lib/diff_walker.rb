module Hive
  module E2E
    class DiffWalker
      def render(errors, parse_error: nil)
        return "parse_error: #{parse_error}\n" if parse_error
        return "" if errors.nil? || errors.empty?

        errors.map { |error| render_error(error) }.join("\n")
      end

      private

      def render_error(error)
        keyword = value(error, "keywordLocation") || value(error, :keywordLocation) || value(error, "schema_pointer") || "schema"
        instance = value(error, "instanceLocation") || value(error, :instanceLocation) || value(error, "data_pointer") || "/"
        message = value(error, "error") || value(error, :error) || error.inspect

        "#{instance} (schema #{keyword})\n  error: #{message}\n"
      end

      def value(hash, key)
        hash[key] if hash.respond_to?(:[])
      end
    end
  end
end
