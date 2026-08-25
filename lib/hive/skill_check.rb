require "json"
require "pathname"
require "uri"

module Hive
  # Per-agent verification that a configured native skill
  # invocation actually resolves to a file on disk. `Hive::AgentProfile`
  # delegates to its built-in or AgentSupport skill facet so the profile
  # interface stays uniform.
  #
  # Each profile-specific module exposes
  # `verify(invocation, project_root: nil)` returning a 2-element array:
  #
  #   [:present, "<resolved path or descriptor>"]
  #     — invocation maps to a real on-disk file.
  #
  #   [:missing, "<install hint>"]
  #     — invocation is a real shape (`/foo` or `/plug:foo`) but no
  #       installed file matches it.
  #
  #   [:not_applicable, "<why>"]
  #     — this invocation form cannot be checked for this agent
  #       (e.g. pi only resolves skills as `/skill:<name>`).
  #
  #   [:shadowed, "<conflicting path>"]
  #     — the requested native package is configured, but a higher-precedence
  #       project/user skill would win at runtime.
  module SkillCheck
    # Parsed invocation. These forms are accepted:
    #   /name           -> Invocation.new(plugin: nil, name: "name")
    #   /plugin:name    -> Invocation.new(plugin: "plugin", name: "name")
    #   $name           -> Invocation.new(plugin: nil, name: "name")
    Invocation = Struct.new(:plugin, :name, keyword_init: true)
    Resolution = Data.define(:status, :path, :message, :candidates, :parse_errors)

    # Raises ArgumentError on malformed input so callers can surface the
    # error rather than silently treating garbage as a valid skill.
    def self.parse(invocation)
      raise ArgumentError, "expected /name, /plugin:name, or $name, got nil" if invocation.nil?

      str = invocation.to_s
      if (mention = str.match(%r{\A\$([^:/$\s]+)\z}))
        return Invocation.new(plugin: nil, name: mention[1])
      end
      m = str.match(%r{\A/(?:([^:/\s]+):)?([^:/\s]+)\z})
      raise ArgumentError, "expected /name, /plugin:name, or $name, got #{str.inspect}" unless m

      Invocation.new(plugin: m[1], name: m[2])
    end

    # Helper: returns the first existing path from `candidates`, or nil
    # if none exist. `Pathname#exist?` follows symlinks — that's the
    # right behavior for claude's `~/.claude/skills/<name>` symlinks
    # into `~/.agents/skills/<name>/`.
    def self.first_existing(candidates)
      candidates.each do |path|
        pn = Pathname.new(path)
        return pn.to_s if pn.exist?
      end
      nil
    end

    # Escapes glob metacharacters (`*`, `?`, `[`, `]`, `{`, `}`, `\`) so
    # a name or plugin segment is treated literally inside a `Dir[]`
    # call. Without this, an invocation like `/foo*` would silently
    # match plugin caches whose name starts with `foo` and report
    # the wrong file as "present". Components passed to `Dir[]` should
    # be wrapped in this whenever they come from a user-controlled
    # source (config, prompt, parsed invocation).
    def self.glob_escape(component)
      component.to_s.gsub(/[\\{}\[\]*?]/) { |char| "\\#{char}" }
    end

    def self.same_source?(actual, expected) = normalize_source(actual) == normalize_source(expected)
    def self.normalize_source(value) = value.to_s.strip
      .sub(%r{\Ahttps://github\.com/}i, "").sub(/\.git\z/i, "").downcase
  end
end
