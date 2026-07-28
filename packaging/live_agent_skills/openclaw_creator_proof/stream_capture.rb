module HiveLiveAgentProof
  module OpenClawCreatorProof
    class StreamCapture
      MINIMUM_SCAN_WINDOW = 512

      attr_reader :retained, :bytes, :findings

      def initialize(
        limit:,
        exact_secrets:,
        secret_patterns: HiveLiveAgentProof::SECRET_PATTERNS
      )
        @limit = Integer(limit)
        @exact_secrets = exact_secrets.reject(&:empty?).map { |secret| secret.to_s.b }
        @secret_patterns = secret_patterns
        @scan_window = [ MINIMUM_SCAN_WINDOW, *@exact_secrets.map(&:bytesize) ].max
        @retained = +"".b
        @bytes = 0
        @digest = Digest::SHA256.new
        @tail = +"".b
        @findings = Set.new
      end

      def update(chunk)
        raw = chunk.to_s.b
        @bytes += raw.bytesize
        @digest.update(raw)
        remaining = @limit - @retained.bytesize
        @retained << raw.byteslice(0, remaining) if remaining.positive?
        scan = @tail + raw
        utf8 = scan.dup.force_encoding(Encoding::UTF_8).scrub
        @secret_patterns.each do |pattern|
          @findings << "pattern:#{pattern.source}" if pattern.match?(utf8)
        end
        @exact_secrets.each_with_index do |secret, index|
          @findings << "exact-secret:#{index}" if scan.include?(secret)
        end
        retained_tail = [ scan.bytesize, @scan_window ].min
        @tail = scan.byteslice(scan.bytesize - retained_tail, retained_tail).to_s.b
      end

      def record
        {
          "sha256" => @digest.hexdigest,
          "bytes" => @bytes,
          "retained_bytes" => @retained.bytesize,
          "truncated" => @bytes > @retained.bytesize
        }
      end
    end
  end
end
