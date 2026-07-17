require "digest"
require "securerandom"

module Hive
  module Attempts
    # One-time launch authority. Only the digest is durable; the random secret
    # crosses process boundaries through inherited file descriptors.
    module Capability
      SECRET_BYTES = 32
      SECRET_PATTERN = /\A[0-9a-f]{#{SECRET_BYTES * 2}}\z/
      DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

      module_function

      def generate
        ::SecureRandom.hex(SECRET_BYTES)
      end

      def digest(secret)
        ::Digest::SHA256.hexdigest(secret.to_s)
      end

      def valid_digest?(value)
        value.is_a?(String) && DIGEST_PATTERN.match?(value)
      end

      def valid_secret?(value)
        value.is_a?(String) && SECRET_PATTERN.match?(value)
      end

      def matches?(expected_digest, secret)
        return false unless valid_digest?(expected_digest) && valid_secret?(secret)

        actual = digest(secret)
        mismatch = 0
        expected_digest.bytes.zip(actual.bytes) { |left, right| mismatch |= left ^ right }
        mismatch.zero?
      end
    end
  end
end
