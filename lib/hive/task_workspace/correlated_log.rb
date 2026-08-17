require "base64"
require "digest"
require "json"
require "hive/output_reference"

module Hive
  module TaskWorkspace
    # Resolves one integrity-bearing attempt log reference through a bounded,
    # no-follow descriptor. The same primitive backs Web and the native CLI so
    # an agent never has to interpret or open the reference path itself.
    class CorrelatedLog
      MAX_BYTES = 8 * 1024 * 1024
      TAIL_BYTES = 256 * 1024
      TAIL_LINES = 200
      READ_BYTES = 64 * 1024
      CHANNELS = %w[stdout stderr supervisor].freeze

      def initialize(root:)
        @root = File.realpath(File.expand_path(root))
      rescue SystemCallError => e
        raise ArgumentError, "invalid attempt log root: #{e.message}"
      end

      def read(reference)
        return nil unless reference.respond_to?(:to_h)

        reference = reference.to_h.transform_keys(&:to_s)
        Hive::OutputReference.validate_shape!(reference)
        return nil if reference.fetch("size") > MAX_BYTES

        path = contained_path(reference.fetch("path"))
        before = File.lstat(path)
        return nil unless before.file? && !before.symlink?

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |io|
          opened = io.stat
          return nil unless opened.file? && opened.dev == before.dev && opened.ino == before.ino
          return nil unless opened.size == reference.fetch("size")

          digest, tail, bytes = digest_and_tail(io)
          return nil unless bytes == reference.fetch("size")
          return nil unless digest == reference.fetch("sha256")

          content = reference.fetch("path").end_with?(".frames") ?
            decode_frames(tail) : tail.force_encoding(Encoding::UTF_8).scrub
          {
            "path" => File.basename(reference.fetch("path")),
            "tail" => content.lines.last(TAIL_LINES).join,
            "reference_sha256" => reference.fetch("sha256")
          }
        end
      rescue Hive::Error, SystemCallError, IOError, JSON::ParserError,
             ArgumentError, TypeError
        nil
      end

      private

      def contained_path(relative)
        candidate = File.expand_path(relative, @root)
        parent = File.realpath(File.dirname(candidate))
        prefix = "#{@root}#{File::SEPARATOR}"
        raise Hive::InvalidOutputReference, "attempt output escapes the attempt root" unless
          parent == @root || parent.start_with?(prefix)

        candidate
      end

      def digest_and_tail(io)
        digest = Digest::SHA256.new
        tail = +"".b
        bytes = 0
        while (chunk = io.read(READ_BYTES))
          bytes += chunk.bytesize
          return [ nil, nil, bytes ] if bytes > MAX_BYTES

          digest << chunk
          tail << chunk
          tail = tail.byteslice(-TAIL_BYTES, TAIL_BYTES) if tail.bytesize > TAIL_BYTES
        end
        if bytes > tail.bytesize
          newline = tail.index("\n")
          tail = newline ? tail.byteslice((newline + 1)..) : +"".b
        end
        [ digest.hexdigest, tail, bytes ]
      end

      def decode_frames(value)
        value.lines.filter_map do |line|
          next unless line.end_with?("\n")

          frame = JSON.parse(line)
          next unless CHANNELS.include?(frame["channel"])

          Base64.strict_decode64(frame.fetch("data"))
        rescue JSON::ParserError, KeyError, ArgumentError
          nil
        end.join.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
