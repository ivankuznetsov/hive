require "hive/honeycomb"

module Hive
  module Honeycomb
    REFERENCE_NAME_RE = /\A[a-z0-9][a-z0-9-]*\z/
    SEMVER_RE = /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
    REFERENCE_SHA_RE = /\A[0-9a-fA-F]{7,64}\z/

    Reference = Data.define(:name, :selector) do
      def self.parse(raw)
        value = raw.to_s
        match = value.match(%r{\Ahoneycomb/([^/@]+)(?:@([^@]+))?\z})
        raise ReferenceError, "invalid honeycomb reference #{raw.inspect}" unless match

        name = match[1]
        selector = match[2]
        raise ReferenceError, "invalid honeycomb workflow name #{name.inspect}" unless REFERENCE_NAME_RE.match?(name)
        validate_selector!(selector) if selector
        new(name: name, selector: selector&.downcase)
      end

      def self.validate_selector!(selector)
        if %w[latest main master head].include?(selector.downcase)
          raise ReferenceError, "mutable selector #{selector.inspect} is not allowed"
        end
        return if SEMVER_RE.match?(selector)
        return if REFERENCE_SHA_RE.match?(selector) && selector.length.between?(7, 64)

        raise ReferenceError,
              "invalid selector #{selector.inspect} (expected exact SemVer, full SHA/digest, or SHA prefix)"
      end
      private_class_method :validate_selector!

      def version_selector?
        selector && SEMVER_RE.match?(selector)
      end

      def hex_selector?
        selector && REFERENCE_SHA_RE.match?(selector)
      end
    end
  end
end
