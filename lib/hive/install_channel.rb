require "fileutils"
require "rbconfig"
require "hive/paths"

module Hive
  module InstallChannel
    # `dev` is the synthetic git-clone fallback: it's never written to
    # an install-channel marker — `detect` returns it when no marker
    # exists, signalling "running from a working checkout, no
    # release-channel updater to delegate to".
    VALID = %w[brew aur bash dev].freeze

    module_function

    def write(channel, path: marker_path)
      validate!(channel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{channel}\n")
      channel
    end

    def detect(marker_paths: default_marker_paths)
      marker_paths.each do |path|
        channel = safe_read(path)
        return channel if channel
      end
      "dev"
    end

    def detected_prefix(marker_paths: default_marker_paths)
      marker_paths.each do |path|
        channel = safe_read(path)
        next unless channel

        return read_prefix(path)
      end
      nil
    end

    def read(path)
      return nil unless path && File.exist?(path)

      channel = File.read(path).strip
      validate!(channel)
      channel
    end

    def read_prefix(marker_path)
      path = File.join(File.dirname(marker_path), "install-prefix")
      return nil unless File.exist?(path)

      prefix = File.read(path).strip
      return nil if prefix.empty?

      File.expand_path(prefix)
    end

    def marker_path
      File.join(Hive::Paths.data_home, "install-channel")
    end

    # Optional override for callers that installed via `install.sh
    # --prefix=<dir>`; install.sh writes the marker under that prefix
    # rather than the XDG default, so `hive update` needs an extra
    # probe.
    def prefix_marker_paths
      prefix = ENV["HIVE_PREFIX"]
      return [] if prefix.nil? || prefix.empty?

      [ File.join(File.expand_path(prefix), "hive", "install-channel") ]
    end

    def default_marker_paths
      [
        marker_path,
        *prefix_marker_paths,
        *homebrew_marker_paths,
        "/usr/share/hive/install-channel"
      ].uniq
    end

    # macOS-only: returning brew marker probes on a Linux/AUR host
    # would let a stray `HOMEBREW_PREFIX=/tmp/evil` or `/usr/local`
    # marker shadow the real `/usr/share/hive/install-channel`. Skip
    # brew probes entirely when we're not on macOS (or when brew isn't
    # actually installed under a known prefix).
    def homebrew_marker_paths
      return [] unless macos?

      prefixes = []
      env_prefix = ENV["HOMEBREW_PREFIX"]
      if env_prefix && !env_prefix.empty? && valid_homebrew_prefix?(env_prefix)
        prefixes << env_prefix
      end
      prefixes.concat(%w[/opt/homebrew /usr/local])
      prefixes.uniq.map { |prefix| File.join(prefix, "share/hive/install-channel") }
    end

    def macos?
      RbConfig::CONFIG["host_os"] =~ /darwin/i
    end

    # Refuse paths that look attacker-shaped: must be absolute, no
    # `..` segments, and the bin/brew binary must exist under it.
    def valid_homebrew_prefix?(prefix)
      return false unless prefix.start_with?("/")
      return false if prefix.include?("..")

      File.executable?(File.join(prefix, "bin", "brew"))
    end

    def validate!(channel)
      return if VALID.include?(channel)

      raise Hive::ConfigError, "unknown hive install channel #{channel.inspect} (expected: #{VALID.join(', ')})"
    end

    # Surface a malformed marker as an actionable, fail-closed error.
    # A corrupt high-priority marker must not silently fall through to a
    # stale lower-priority marker and route `hive update` to the wrong
    # channel.
    def safe_read(path)
      read(path)
    rescue Hive::ConfigError => e
      raise Hive::ConfigError,
            "invalid install-channel marker at #{path}: #{e.message}; remove it and re-install to fix"
    end
  end
end
