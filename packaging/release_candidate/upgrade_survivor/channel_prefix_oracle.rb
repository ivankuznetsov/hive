# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require_relative "../paths"

module HiveReleaseCandidate
  class ChannelPrefixOracle
    CHANNELS = {
      "linux-x86_64" => "linux-bash",
      "linux-arm64" => "linux-bash",
      "macos-arm64" => "homebrew-local-formula"
    }.freeze

    def verify(prefix:, platform:, candidate_target:)
      channel = CHANNELS.fetch(platform) do
        raise UsageError, "unsupported channel-faithful platform #{platform.inspect}"
      end
      root = safe_directory!(prefix)
      manifest_path = File.join(root, ".hive-install.json")
      manifest = JSON.parse(File.binread(manifest_path))
      required = %w[
        candidate_gem_sha256 channel dependencies_current files platform
        sidecars_current stale_files wrapper_role
      ]
      unless manifest.is_a?(Hash) && manifest.keys.sort == required &&
             manifest["platform"] == platform && manifest["channel"] == channel
        raise Error, "channel install manifest is invalid"
      end
      expected_digest = candidate_target.manifest.fetch("gem_sha256")
      raise Error, "channel candidate digest mismatch" unless manifest["candidate_gem_sha256"] == expected_digest
      raise Error, "channel wrapper does not resolve candidate bytes" unless manifest["wrapper_role"] == "candidate"
      unless manifest["sidecars_current"] == true && manifest["dependencies_current"] == true
        raise Error, "channel sidecars or dependencies are stale"
      end
      unless manifest["stale_files"] == []
        raise Error, "stale channel files remain: #{manifest['stale_files'].join(', ')}"
      end

      files = manifest["files"]
      unless files.is_a?(Hash) && files.key?("bin/hive")
        raise Error, "channel manifest must bind the installed wrapper"
      end
      actual = inventory(root, excluding: [ ".hive-install.json" ])
      raise Error, "channel prefix contains stale or substituted files" unless actual == files

      manifest.merge("status" => "passed")
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
      raise Error, "channel prefix is invalid: #{e.message}"
    end

    private

    def safe_directory!(value)
      path = File.expand_path(value)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise Error, "channel prefix must be an owned directory"
      end
      path
    end

    def inventory(root, excluding:)
      paths = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
        next if [ ".", ".." ].include?(File.basename(path))
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        next if excluding.include?(relative)
        stat = File.lstat(path)
        raise Error, "channel prefix contains a symlink" if stat.symlink?
        next if stat.directory?
        raise Error, "channel prefix contains a non-regular file" unless stat.file? && stat.uid == Process.uid
        [ relative, { "size" => stat.size, "sha256" => Digest::SHA256.file(path).hexdigest } ]
      end
      paths.to_h
    end
  end
end
