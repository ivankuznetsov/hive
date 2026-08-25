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

    module Claude
      module_function

      # Search order:
      #   /<plugin>:<name>
      #     1. ~/.claude/plugins/cache/*/<plugin>/*/skills/<name>/SKILL.md
      #        (resolved cache layout: <marketplace>/<plugin>/<version>/skills/<name>/)
      #     2. ~/.claude/plugins/cache/*/<plugin>/*/commands/<name>.md
      #     3. ~/.claude/plugins/marketplaces/*/plugins/<plugin>/skills/<name>/SKILL.md
      #        (marketplace source layout: <marketplace>/plugins/<plugin>/skills/<name>/)
      #     4. ~/.claude/plugins/marketplaces/*/plugins/<plugin>/commands/<name>.md
      #   /<name>
      #     1. <project>/.claude/commands/<name>.md       (project slash command)
      #     2. <project>/.claude/skills/<name>/SKILL.md    (project skill)
      #     3. ~/.claude/commands/<name>.md                (user slash command)
      #     4. ~/.claude/skills/<name>/SKILL.md            (user skill)
      #     5. ~/.claude/plugins/cache/*/*/*/skills/<name>/SKILL.md
      #     6. ~/.claude/plugins/cache/*/*/*/commands/<name>.md
      #     7. ~/.claude/plugins/marketplaces/*/plugins/*/skills/<name>/SKILL.md
      #     8. ~/.claude/plugins/marketplaces/*/plugins/*/commands/<name>.md
      #
      # Steps 5–8 are the plugin-fallback paths: claude resolves a bare
      # `/foo` invocation against any installed plugin's skill named
      # `foo` (in addition to user-level commands/skills). A user who
      # ran `claude plugin install some-marketplace` to bring in
      # `compound-engineering` and then writes `skill: ce-code-review`
      # in their hive config expects `/ce-code-review` to resolve
      # against the plugin's skill, even though the bare invocation
      # has no explicit `<plugin>:` prefix. The fallback matches that
      # runtime behaviour.
      def verify(invocation, project_root: nil)
        resolution = resolve(invocation, project_root: project_root)
        [ resolution.status, resolution.message ]
      end

      def resolve(invocation, project_root: nil, environment: ENV)
        inv = Hive::SkillCheck.parse(invocation)
        home = environment["HOME"] || Dir.home
        config_dir = environment["CLAUDE_CONFIG_DIR"].to_s
        config_dir = File.join(home, ".claude") if config_dir.empty?
        config_dir = File.expand_path(config_dir)
        candidates = build_candidates(inv, config_dir: config_dir, project_root: project_root)
        path = Hive::SkillCheck.first_existing(candidates)
        return Resolution.new(status: :present, path: path, message: path,
                              candidates: candidates.freeze, parse_errors: [].freeze) if path

        message = install_hint(inv)
        Resolution.new(status: :missing, path: nil, message: message,
                       candidates: candidates.freeze, parse_errors: [].freeze)
      rescue ArgumentError => e
        message = "claude: #{e.message}"
        Resolution.new(status: :missing, path: nil, message: message,
                       candidates: [].freeze, parse_errors: [].freeze)
      end

      def build_candidates(inv, config_dir:, project_root:)
        if inv.plugin
          plugin = Hive::SkillCheck.glob_escape(inv.plugin)
          name = Hive::SkillCheck.glob_escape(inv.name)
          # Cache layout: <marketplace>/<plugin>/<version>/skills/<name>/SKILL.md
          cache_skill_glob = File.join(config_dir, "plugins/cache/*", plugin, "*", "skills", name, "SKILL.md")
          cache_cmd_glob   = File.join(config_dir, "plugins/cache/*", plugin, "*", "commands", "#{name}.md")
          # Marketplace source layout: <marketplace>/plugins/<plugin>/skills/<name>/SKILL.md
          mp_skill_glob = File.join(config_dir, "plugins/marketplaces/*/plugins", plugin, "skills", name, "SKILL.md")
          mp_cmd_glob   = File.join(config_dir, "plugins/marketplaces/*/plugins", plugin, "commands", "#{name}.md")
          (Dir[cache_skill_glob] + Dir[cache_cmd_glob] + Dir[mp_skill_glob] + Dir[mp_cmd_glob])
        else
          name = Hive::SkillCheck.glob_escape(inv.name)
          paths = []
          if project_root
            paths << File.join(project_root, ".claude/commands/#{inv.name}.md")
            paths << File.join(project_root, ".claude/skills/#{inv.name}/SKILL.md")
          end
          paths << File.join(config_dir, "commands/#{inv.name}.md")
          paths << File.join(config_dir, "skills/#{inv.name}/SKILL.md")
          # Plugin-fallback for bare invocations: claude's runtime
          # resolves `/foo` against any installed plugin's skill named
          # `foo` (in addition to user-level commands/skills).
          paths.concat(Dir[File.join(config_dir, "plugins/cache/*/*/*/skills", name, "SKILL.md")])
          paths.concat(Dir[File.join(config_dir, "plugins/cache/*/*/*/commands", "#{name}.md")])
          paths.concat(Dir[File.join(config_dir, "plugins/marketplaces/*/plugins/*/skills", name, "SKILL.md")])
          paths.concat(Dir[File.join(config_dir, "plugins/marketplaces/*/plugins/*/commands", "#{name}.md")])
          paths
        end
      end

      def install_hint(inv)
        if inv.plugin
          "claude: /#{inv.plugin}:#{inv.name} not found under " \
            "~/.claude/plugins/cache/*/#{inv.plugin}/*/skills/ or " \
            "~/.claude/plugins/marketplaces/*/plugins/#{inv.plugin}/skills/. " \
            "Install via `claude plugin install <marketplace>` for the marketplace " \
            "that ships #{inv.plugin}."
        else
          "claude: /#{inv.name} not found under ~/.claude/{commands,skills}/, any " \
            "installed plugin's skills/<name>/ or commands/<name>.md, or " \
            "<project>/.claude/.... Install as a user-level slash command " \
            "(write ~/.claude/commands/#{inv.name}.md), as a user skill " \
            "(write ~/.claude/skills/#{inv.name}/SKILL.md), or via " \
            "`claude plugin install <marketplace>` for a plugin that ships #{inv.name}."
        end
      end
    end

  end
end
