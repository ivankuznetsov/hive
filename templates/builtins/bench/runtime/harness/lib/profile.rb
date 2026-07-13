# frozen_string_literal: true

require "open3"

module HiveBench
  # A candidate cell's invocation contract: which agent harness + which model,
  # and how to pin that model on the CLI. hive (the source project) pins a model
  # only for claude — `Hive::Agent#build_cmd` rejects model flags for codex/pi —
  # so hive-bench carries its own thin profile layer instead of reusing hive's.
  #
  # The model-pinning argv fragment is the whole point of this class; the full
  # run invocation (cwd, isolation, output capture) is the runner's job (U3).
  # `command(prompt:)` returns a headless, model-pinned argv the runner extends.
  #
  # All external effects (the version probe, PATH/auth file checks) are seams so
  # preflight is testable without the real binaries.
  class Profile
    Preflight = Data.define(:available, :reason, :version)

    attr_reader :id, :harness, :model, :bin, :version_flag, :min_version, :auth_path

    # headless_argv: ->(prompt:) => [argv...] — must bake in the model + headless flag.
    def initialize(id:, harness:, model:, bin:, headless_argv:,
                   version_flag: "--version", min_version: nil, auth_path: nil)
      @id = id
      @harness = harness
      @model = model
      @bin = bin
      @headless_argv = headless_argv
      @version_flag = version_flag
      @min_version = min_version
      @auth_path = auth_path
      freeze
    end

    def command(prompt:)
      @headless_argv.call(prompt: prompt)
    end

    # Returns a Preflight value: is this cell runnable here, and if not, exactly why?
    # Never raises — an unavailable agent reports a precise reason rather than
    # blowing up a benchmark pass (a cell that can't run is recorded, not skipped).
    #
    # which:       ->(bin)        => path|nil
    # file_exists: ->(path)       => bool
    # probe:       ->(bin, flag)  => [stdout, ok?]   (the `bin --version` call)
    def preflight(which: method(:which_default), file_exists: File.method(:file?),
                  probe: method(:probe_version_default))
      path = which.call(@bin)
      return unavailable("binary `#{@bin}` not found on PATH") if path.nil?

      if @auth_path
        expanded = File.expand_path(@auth_path)
        return unavailable("not logged in (#{@auth_path} absent) — run the #{@harness} login first") unless file_exists.call(expanded)
      end

      out, ok = probe.call(@bin, @version_flag)
      return unavailable("`#{@bin} #{@version_flag}` failed") unless ok

      version = parse_version(out)
      if @min_version && version && older?(version, @min_version)
        return unavailable("#{@harness} #{version} is older than the required #{@min_version}", version: version)
      end

      Preflight.new(available: true, reason: "ok", version: version)
    end

    private

    def unavailable(reason, version: nil)
      Preflight.new(available: false, reason: reason, version: version)
    end

    def parse_version(text)
      text.to_s[/\d+\.\d+(?:\.\d+)?/]
    end

    def older?(found, required)
      gem_version(found) < gem_version(required)
    rescue ArgumentError
      false
    end

    def gem_version(str)
      Gem::Version.new(str)
    end

    def which_default(bin)
      out, status = Open3.capture2e("sh", "-c", "command -v #{bin}")
      status.success? ? out.strip : nil
    rescue StandardError
      nil
    end

    def probe_version_default(bin, flag)
      out, _err, status = Open3.capture3(bin, flag)
      [out, status.success?]
    rescue StandardError
      ["", false]
    end
  end
end
