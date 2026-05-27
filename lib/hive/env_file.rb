require "hive/paths"

module Hive
  # Loads simple KEY=value pairs from `~/.config/hive/.env` (or HIVE_HOME/.env
  # when HIVE_HOME collapses the XDG dirs) into ENV. Existing ENV values are
  # NOT overwritten — a manual `export HIVE_TELEGRAM_BOT_TOKEN=...` always
  # wins, so the .env file is a convenience for stable secrets without
  # touching shell rc files.
  #
  # Format:
  #
  #     # comments are allowed
  #     HIVE_TELEGRAM_BOT_TOKEN=123:abc
  #     # quoted values strip outer quotes; embedded escapes are not interpreted
  #     SOME_OTHER=value
  #
  # Blank lines and lines starting with `#` are ignored. Lines without `=` are
  # ignored. Whitespace around the key is stripped; whitespace inside the value
  # is preserved verbatim (after outer-quote stripping).
  module EnvFile
    module_function

    DEFAULT_PATH = File.join(Hive::Paths.config_home, ".env").freeze

    # Load env vars from `path` into ENV. Returns the set of keys added. Skips
    # silently if the file is missing or unreadable — this is a convenience
    # layer, not a hard config requirement.
    def load!(path: DEFAULT_PATH, env: ENV)
      return [] unless File.exist?(path)

      raw = begin
        File.read(path)
      rescue SystemCallError, IOError
        return []
      end

      added = []
      raw.each_line do |line|
        line = line.chomp
        next if line.strip.empty?
        next if line.lstrip.start_with?("#")

        key, value = line.split("=", 2)
        next unless key && value

        key = key.strip
        next if key.empty?
        next if env.key?(key)

        env[key] = strip_outer_quotes(value)
        added << key
      end
      added
    end

    def strip_outer_quotes(value)
      stripped = value.strip
      if (stripped.start_with?('"') && stripped.end_with?('"')) ||
         (stripped.start_with?("'") && stripped.end_with?("'"))
        stripped[1..-2]
      else
        stripped
      end
    end
  end
end
