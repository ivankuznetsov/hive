module HiveLiveAgentProof
  module OpenClawCreatorGatewayRuntime
    class CandidateIdentity
      def initialize(candidate:, expected_digest:, installation_identity:)
        @candidate = candidate
        @expected_digest = expected_digest
        @installation_identity = installation_identity
      end

      def valid?
        return basic_candidate_valid? unless @installation_identity

        identity = OpenClawCreatorProof::InstallationIdentity.validate_live!(
          record: @installation_identity,
          expected:
            OpenClawCreatorProof::InstallationIdentity.expectations_from(
              @installation_identity
            )
        )
        candidate_path_valid? &&
          identity.fetch("realpath") == File.realpath(@candidate) &&
          identity.fetch("sha256") == @expected_digest
      rescue OpenClawCreatorProof::InstallationIdentity::Invalid,
             KeyError, SystemCallError, Timeout::Error
        false
      end

      private

      def basic_candidate_valid?
        candidate_path_valid? &&
          Digest::SHA256.file(@candidate).hexdigest == @expected_digest
      end

      def candidate_path_valid?
        File.file?(@candidate) && !File.symlink?(@candidate) &&
          File.executable?(@candidate)
      end
    end
  end
end
