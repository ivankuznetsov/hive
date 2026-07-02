require "base64"
require "openssl"
require "securerandom"

module Hive
  module Screenote
    module PKCE
      VERIFIER_BYTES = 64

      module_function

      def verifier(random: SecureRandom)
        random.urlsafe_base64(VERIFIER_BYTES, false)
      end

      def challenge(verifier)
        Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier), padding: false)
      end
    end
  end
end
