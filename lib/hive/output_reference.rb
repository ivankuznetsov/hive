require "digest"
require "fileutils"
require "hive"
require "hive/stringify_keys"
require "pathname"

module Hive
  class InvalidOutputReference < Hive::Error; end

  # Integrity-bearing reference to a file below a caller-owned root. The
  # primitive validates only custody metadata; the domain using the reference
  # retains ownership of the artifact and its meaning.
  module OutputReference
    module_function

    SHA256_PATTERN = /\A[0-9a-f]{64}\z/

    def build(path, root:)
      root_path = canonical_root(root)
      file_path = File.realpath(path)
      ensure_contained!(file_path, root_path)
      raise InvalidOutputReference, "attempt output must be a regular file" unless File.file?(file_path)

      relative = Pathname.new(file_path).relative_path_from(Pathname.new(root_path)).to_s
      {
        "path" => relative,
        "size" => File.size(file_path),
        "sha256" => ::Digest::SHA256.file(file_path).hexdigest
      }.freeze
    rescue Errno::ENOENT, ArgumentError => e
      raise InvalidOutputReference, "invalid attempt output path: #{e.message}"
    end

    def validate_shape!(reference)
      unless reference.is_a?(Hash) && reference.keys.map(&:to_s).sort == %w[path sha256 size]
        raise InvalidOutputReference, "output reference must contain path, size, and sha256"
      end

      path = reference["path"] || reference[:path]
      size = reference["size"] || reference[:size]
      sha256 = reference["sha256"] || reference[:sha256]
      unless safe_relative_path?(path)
        raise InvalidOutputReference, "output reference path must be a canonical relative path"
      end
      unless size.is_a?(Integer) && size >= 0
        raise InvalidOutputReference, "output reference size must be a non-negative integer"
      end
      unless sha256.is_a?(String) && SHA256_PATTERN.match?(sha256)
        raise InvalidOutputReference, "output reference sha256 must be 64 lowercase hex characters"
      end
      true
    end

    def verify(reference, root:)
      validate_shape!(reference)
      root_path = canonical_root(root)
      candidate = File.expand_path(reference.fetch("path"), root_path)
      ensure_contained!(candidate, root_path)
      return false unless File.file?(candidate)
      return false unless File.size(candidate) == reference.fetch("size")

      ::Digest::SHA256.file(candidate).hexdigest == reference.fetch("sha256")
    rescue InvalidOutputReference, Errno::ENOENT, Errno::EACCES
      false
    end

    def read(reference, root:, max_bytes:)
      unless max_bytes.is_a?(Integer) && max_bytes.positive?
        raise InvalidOutputReference, "attempt output read bound is invalid"
      end

      value = Hive::StringifyKeys.call(reference)
      validate_shape!(value)
      root_path = File.realpath(root)
      path = File.join(root_path, value.fetch("path"))
      lexical_parent = File.dirname(path)
      parent = File.realpath(lexical_parent)
      raise InvalidOutputReference, "attempt output parent is redirected" unless parent == lexical_parent

      ensure_contained!(parent, root_path) unless parent == root_path
      flags = File::RDONLY | File::NONBLOCK
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      bytes = File.open(path, flags) do |file|
        stat = file.stat
        unless stat.file? && stat.nlink == 1
          raise InvalidOutputReference, "attempt output is not a single regular file"
        end
        raise InvalidOutputReference, "attempt output exceeds read bound" if stat.size > max_bytes

        file.read(max_bytes + 1)
      end
      unless bytes.bytesize == value.fetch("size") &&
             Digest::SHA256.hexdigest(bytes) == value.fetch("sha256")
        raise InvalidOutputReference, "attempt output reference does not verify"
      end
      bytes
    rescue SystemCallError, IOError => e
      raise InvalidOutputReference, "attempt output is unavailable: #{e.message}"
    end

    def safe_relative_path?(path)
      return false unless path.is_a?(String) && !path.empty?
      return false if path.include?("\0") || path.include?("\\")

      pathname = Pathname.new(path)
      !pathname.absolute? && pathname.cleanpath.to_s == path &&
        pathname.each_filename.none? { |part| part == ".." }
    end

    def canonical_root(root)
      FileUtils.mkdir_p(root, mode: 0o700)
      File.chmod(0o700, root)
      File.realpath(root)
    end

    def ensure_contained!(path, root)
      prefix = "#{root}#{File::SEPARATOR}"
      return if path.start_with?(prefix)

      raise InvalidOutputReference, "attempt output escapes the attempt root"
    end
  end
end
