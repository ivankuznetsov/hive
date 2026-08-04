# frozen_string_literal: true

require "digest"
require "pathname"
require "rubygems/package"
require "zlib"
require_relative "workflow_creator"

module HiveLiveAgentProof
  class WorkflowCreatorArchive
    class Error < StandardError; end
    MESSAGE = "workflow-creator archive is not safely admissible"
    MAX_ARCHIVE_BYTES = 268_435_456
    MAX_ENTRY_BYTES = 268_435_456
    MAX_TOTAL_BYTES = 1_073_741_824
    MAX_ENTRIES = 16_384
    MAX_PATH_BYTES = 240
    MAX_PATH_DEPTH = 32
    MAX_COMPRESSION_RATIO = 100
    MAX_SECONDS = 5.0
    CHUNK_BYTES = 65_536
    READ_FLAGS = if defined?(File::NOFOLLOW) && defined?(File::NONBLOCK)
      File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    end

    class << self
      def admit!(archive:, label:, available_bytes:, available_entries:, clock: nil)
        inputs = WorkflowCreator::Values.capture(
          "archive" => archive, "label" => label,
          "available_bytes" => available_bytes, "available_entries" => available_entries
        ).value
        validate_inputs!(inputs)
        timer = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        started = timestamp(timer)
        result = inspect_archive(inputs.fetch("archive"), inputs.fetch("label"), timer, started)
        filesystem_budget!(result, inputs.fetch("available_bytes"), inputs.fetch("available_entries"))
        WorkflowCreator::Values.capture(result)
      rescue StandardError
        raise Error, MESSAGE, cause: nil
      end
      private

      def validate_inputs!(inputs)
        labels = WorkflowCreator::Vocabulary.fetch("archive_labels")
        integers = inputs.values_at("available_bytes", "available_entries")
        valid = labels.include?(inputs.fetch("label"))
        valid &&= integers.all? { |value| value.instance_of?(Integer) && value >= 0 }
        valid &&= READ_FLAGS
        raise Error, MESSAGE unless valid
      end

      def inspect_archive(path, label, timer, started)
        File.open(path, READ_FLAGS) do |file|
          stat = file.stat
          valid_file!(stat)
          digest = digest_file(file, timer, started)
          file.rewind
          paths, total = read_entries(file, timer, started)
          verify_identity!(file, stat)
          validate_tree!(paths, total, stat.size)
          archive_record(label, digest, stat.size, paths.length, total)
        end
      end

      def valid_file!(stat)
        valid = stat.file? && stat.nlink == 1 && stat.uid == Process.uid && (stat.mode & 0o022).zero?
        valid &&= stat.size.between?(1, MAX_ARCHIVE_BYTES)
        raise Error, MESSAGE unless valid
      end

      def digest_file(file, timer, started)
        digest = Digest::SHA256.new
        while (chunk = file.read(CHUNK_BYTES))
          digest.update(chunk)
          time_remaining!(timer, started)
        end
        digest.hexdigest
      end

      def read_entries(file, timer, started)
        paths = {}
        total = 0
        gzip = Zlib::GzipReader.new(file)
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            raise Error, MESSAGE if paths.length >= MAX_ENTRIES
            kind = entry_kind(entry)
            path = normalized_path(entry.full_name, directory: kind == :directory)
            raise Error, MESSAGE if paths.key?(path)
            size = entry.header.size
            raise Error, MESSAGE unless size.instance_of?(Integer) && size.between?(0, MAX_ENTRY_BYTES)
            total += size
            raise Error, MESSAGE if total > MAX_TOTAL_BYTES
            paths[path] = kind
            consume(entry, timer, started) if kind == :file
            time_remaining!(timer, started)
          end
        end
        [ paths, total ]
      ensure
        gzip&.finish
      end

      def entry_kind(entry)
        case entry.header.typeflag
        when "0", "\0" then :file
        when "5" then :directory
        else raise Error, MESSAGE
        end
      end

      def normalized_path(raw, directory:)
        path = raw.dup.force_encoding(Encoding::UTF_8)
        path = path.delete_suffix("/") if directory
        owned = WorkflowCreator::Values.capture(path).value
        safe = owned.bytesize <= MAX_PATH_BYTES
        safe &&= WorkflowCreator::TextSafety.safe_relative_path?(owned)
        safe &&= Pathname.new(owned).cleanpath.to_s == owned
        safe &&= owned.count("/") + 1 <= MAX_PATH_DEPTH
        raise Error, MESSAGE unless safe
        owned
      end

      def consume(entry, timer, started)
        until entry.eof?
          remaining = entry.size - entry.pos
          chunk = entry.read([ CHUNK_BYTES, remaining ].min)
          raise Error, MESSAGE if chunk.nil? || chunk.empty?
          time_remaining!(timer, started)
        end
      end

      def validate_tree!(paths, total, compressed)
        ordered = paths.keys.sort
        ordered.each_cons(2) do |left, right|
          raise Error, MESSAGE if paths.fetch(left) == :file && right.start_with?("#{left}/")
        end
        valid = !ordered.empty? && total.positive?
        valid &&= total <= compressed * MAX_COMPRESSION_RATIO
        raise Error, MESSAGE unless valid
      end

      def filesystem_budget!(result, available_bytes, available_entries)
        valid = result.fetch("uncompressed_bytes") <= available_bytes
        valid &&= result.fetch("entry_count") <= available_entries
        raise Error, MESSAGE unless valid
      end

      def verify_identity!(file, original)
        current = file.stat
        fields = %i[dev ino uid mode nlink size mtime ctime]
        raise Error, MESSAGE unless fields.map { |field| current.public_send(field) } ==
                                    fields.map { |field| original.public_send(field) }
      end

      def archive_record(label, digest, size, entries, total)
        {
          "label" => label, "artifact_sha256" => digest, "artifact_size" => size,
          "policy_sha256" => WorkflowCreator::Vocabulary.fetch("archive_policy_sha256"),
          "entry_count" => entries, "uncompressed_bytes" => total, "status" => "passed"
        }
      end

      def timestamp(timer)
        value = timer.call
        raise Error, MESSAGE unless value.is_a?(Numeric) && value.finite?
        value
      end

      def time_remaining!(timer, started)
        elapsed = timestamp(timer) - started
        raise Error, MESSAGE unless elapsed.between?(0, MAX_SECONDS)
      end
    end
  end
end
