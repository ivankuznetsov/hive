module Hive
  # Resolves the user-facing CLI path to bake into the systemd-user /
  # launchd daemon unit. Precedence:
  #   1. HIVE_INVOKED_BIN — exported by the bash/Homebrew bin wrappers so
  #      the unit points at the stable GEM_HOME wrapper rather than the
  #      inner versioned gem shim (which `brew upgrade` / re-install would
  #      move out from under the unit).
  #   2. $PROGRAM_NAME — when hive was invoked via an absolute/relative
  #      path, trust that path.
  #   3. PATH lookup — resolve the bare `hive`/`hv` name.
  # Every candidate's basename must be in VALID_NAMES, so a wrong or
  # hostile value (a renamed program, or an env var pointing at some
  # other executable) can never be persisted into an autostart unit.
  module InvokedBinary
    ENV_KEY = "HIVE_INVOKED_BIN".freeze
    VALID_NAMES = %w[hive hv].freeze

    module_function

    def path(program_name: $PROGRAM_NAME, env: ENV)
      explicit = wrapper_path(env)
      return explicit if explicit

      raw = program_name.to_s
      name = File.basename(raw)
      return nil unless VALID_NAMES.include?(name)

      raw.include?(File::SEPARATOR) ? File.expand_path(raw) : which(name, env: env)
    end

    def which(name, env: ENV)
      env["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end

    def wrapper_path(env)
      raw = env[ENV_KEY].to_s
      return nil if raw.empty? || !raw.include?(File::SEPARATOR)
      return nil unless VALID_NAMES.include?(File.basename(raw))

      path = File.expand_path(raw)
      return path if File.file?(path) && File.executable?(path)

      nil
    end
  end
end
