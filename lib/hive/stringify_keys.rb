module Hive
  module StringifyKeys
    module_function

    def call(value)
      case value
      when Hash then value.to_h { |key, child| [ key.to_s, call(child) ] }
      when Array then value.map { |child| call(child) }
      else value
      end
    end
  end
end
