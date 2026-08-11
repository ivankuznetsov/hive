require "digest"
require "json"
require "time"

module Hive
  module CanonicalJSON
    module_function

    def generate(value)
      JSON.generate(normalize(value))
    end

    def digest(value)
      Digest::SHA256.hexdigest(value.is_a?(String) ? value : generate(value))
    end

    def normalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h do |key|
          original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          [ key, normalize(value.fetch(original)) ]
        end
      when Array
        value.map { |child| normalize(child) }
      when Symbol
        value.to_s
      when Time
        value.utc.iso8601(6)
      else
        value
      end
    end
  end
end
