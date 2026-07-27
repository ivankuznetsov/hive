# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require_relative "paths"

module HiveReleaseCandidate
  class AssetVerifier
    SHA256 = /\A[0-9a-f]{64}\z/.freeze

    attr_reader :cache_root

    def initialize(cache_root:)
      @cache_root = File.expand_path(cache_root)
      validate_cache_root!
    end

    def inventory(descriptors)
      validate_descriptors!(descriptors)
      descriptors.map do |descriptor|
        path = File.join(cache_root, descriptor.fetch("filename"))
        if safe_regular_file?(path)
          verify!(descriptor).merge("status" => "verified")
        elsif File.exist?(path) || File.symlink?(path)
          {
            "filename" => descriptor.fetch("filename"),
            "status" => "invalid",
            "path" => path,
            "reason" => "baseline_asset_unsafe"
          }
        else
          {
            "filename" => descriptor.fetch("filename"),
            "status" => "missing",
            "path" => path,
            "fetch_argv" => fetch_argv(descriptor)
          }
        end
      rescue Error => e
        {
          "filename" => descriptor.fetch("filename"),
          "status" => "invalid",
          "path" => path,
          "reason" => "baseline_asset_verification_failed",
          "diagnostic" => e.message
        }
      end
    end

    def verify_set!(descriptors, exact_directory: false)
      validate_descriptors!(descriptors)
      expected = descriptors.map { |descriptor| descriptor.fetch("filename") }.sort
      if exact_directory
        actual = Dir.children(cache_root).sort
        raise Error, "baseline cache contains unmanifested files" unless actual == expected
      end

      descriptors.map { |descriptor| verify!(descriptor) }
    end

    def verify!(descriptor)
      validate_descriptor!(descriptor)
      filename = descriptor.fetch("filename")
      path = File.join(cache_root, filename)
      unless safe_regular_file?(path)
        raise Error, "baseline asset is missing or not an owned regular file: #{filename}"
      end
      stat = File.lstat(path)
      unless stat.size == descriptor.fetch("size")
        raise Error, "baseline asset size mismatch for #{filename}"
      end
      digest = Digest::SHA256.file(path).hexdigest
      unless digest == descriptor.fetch("sha256")
        raise Error, "baseline asset digest mismatch for #{filename}"
      end
      {
        "filename" => filename,
        "path" => path,
        "size" => stat.size,
        "sha256" => digest
      }
    end

    def validate_archive_entries!(names)
      names.each do |name|
        path = Pathname.new(name.to_s)
        normalized = path.cleanpath.to_s
        if name.to_s.empty? || path.absolute? || normalized == ".." ||
           normalized.start_with?("../") || name.to_s.include?("\\")
          raise Error, "unsafe archive entry #{name.inspect}"
        end
      end
      true
    end

    def verify_authenticated_package!(package, signature_verifier:)
      unless package.is_a?(Hash) && package["artifact"].is_a?(Hash) &&
             package["authentication"].is_a?(Hash)
        raise Error, "authenticated package descriptor is invalid"
      end
      authentication = package.fetch("authentication")
      required = %w[certificate checksum identity issuer signature]
      unless authentication.keys.sort == required
        raise Error, "package authentication descriptor is incomplete"
      end
      paths = %w[checksum signature certificate].to_h do |kind|
        descriptor = authentication.fetch(kind)
        verified = verify!(descriptor)
        [ kind, verified.fetch("path") ]
      end
      unless signature_verifier.call(
        checksum: paths.fetch("checksum"),
        signature: paths.fetch("signature"),
        certificate: paths.fetch("certificate"),
        issuer: authentication.fetch("issuer"),
        identity: authentication.fetch("identity")
      )
        raise Error, "baseline checksum signature authentication failed"
      end
      verified = verify!(package.fetch("artifact"))
      checksum_lines = File.readlines(paths.fetch("checksum"), chomp: true)
      matching = checksum_lines.filter_map do |line|
        match = line.match(/\A([0-9a-f]{64})  (?:\.\/)?([^\s\/]+)\z/)
        match&.captures
      end.select { |_digest, filename| filename == verified.fetch("filename") }
      unless matching == [ [ verified.fetch("sha256"), verified.fetch("filename") ] ]
        raise Error, "authenticated checksum does not bind the baseline artifact exactly once"
      end
      verified.merge(
        "checksum" => paths.fetch("checksum"),
        "signature" => paths.fetch("signature"),
        "certificate" => paths.fetch("certificate")
      )
    end

    private

    def validate_cache_root!
      cursor = cache_root
      loop do
        if File.symlink?(cursor)
          raise Error, "baseline cache path cannot contain a symlink: #{cursor}"
        end
        parent = File.dirname(cursor)
        break if parent == cursor
        cursor = parent
      end
      return unless File.exist?(cache_root) || File.symlink?(cache_root)

      stat = File.lstat(cache_root)
      raise Error, "baseline cache root cannot be a symlink" if stat.symlink?
      raise Error, "baseline cache root must be a directory" unless stat.directory?
      raise Error, "baseline cache root is not owned by the current user" unless stat.uid == Process.uid
    end

    def validate_descriptors!(descriptors)
      unless descriptors.is_a?(Array) && descriptors.uniq { |item| item["filename"] }.length == descriptors.length
        raise Error, "baseline asset descriptors must have unique filenames"
      end
      descriptors.each { |descriptor| validate_descriptor!(descriptor) }
    end

    def validate_descriptor!(descriptor)
      unless descriptor.is_a?(Hash)
        raise Error, "baseline asset descriptor must be a mapping"
      end
      required = %w[filename repository sha256 size tag url]
      missing = required - descriptor.keys
      raise Error, "baseline asset descriptor is missing #{missing.join(', ')}" unless missing.empty?
      filename = descriptor.fetch("filename")
      unless filename.is_a?(String) && filename == File.basename(filename) &&
             !%w[. ..].include?(filename) && !filename.include?("\\")
        raise Error, "unsafe baseline asset filename #{filename.inspect}"
      end
      repository = descriptor.fetch("repository")
      tag = descriptor.fetch("tag")
      expected_url = "https://github.com/#{repository}/releases/download/#{tag}/#{filename}"
      raise Error, "baseline asset URL is not canonical" unless descriptor.fetch("url") == expected_url
      raise Error, "baseline asset digest is invalid" unless SHA256.match?(descriptor.fetch("sha256").to_s)
      unless descriptor.fetch("size").is_a?(Integer) && descriptor.fetch("size").positive?
        raise Error, "baseline asset size is invalid"
      end
    end

    def safe_regular_file?(path)
      stat = File.lstat(path)
      stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def fetch_argv(descriptor)
      [
        "gh", "release", "download", descriptor.fetch("tag"),
        "--repo", descriptor.fetch("repository"),
        "--pattern", descriptor.fetch("filename"),
        "--dir", cache_root
      ]
    end
  end
end
