require "fileutils"
require "hive/paths"

module Hive
  module InstallChannel
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
        channel = read(path)
        return channel if channel
      end
      "dev"
    end

    def read(path)
      return nil unless path && File.exist?(path)

      channel = File.read(path).strip
      validate!(channel)
      channel
    end

    def marker_path
      File.join(Hive::Paths.data_home, "install-channel")
    end

    def default_marker_paths
      [
        marker_path,
        *homebrew_marker_paths,
        "/usr/share/hive/install-channel"
      ].uniq
    end

    def homebrew_marker_paths
      prefixes = []
      prefixes << ENV["HOMEBREW_PREFIX"] if ENV["HOMEBREW_PREFIX"] && !ENV["HOMEBREW_PREFIX"].empty?
      prefixes.concat(%w[/opt/homebrew /usr/local])
      prefixes.map { |prefix| File.join(prefix, "share/hive/install-channel") }
    end

    def validate!(channel)
      return if VALID.include?(channel)

      raise Hive::ConfigError, "unknown hive install channel #{channel.inspect} (expected: #{VALID.join(', ')})"
    end
  end
end
