require "json"
require "pathname"
require "uri"

module Hive
  # Per-agent verification that a configured native skill
  # invocation actually resolves to a file on disk. `Hive::AgentProfile`
  # delegates to one of `SkillCheck::Claude` / `SkillCheck::Codex` /
  # `SkillCheck::Grok` or an optional AgentSupport skill facet so the
  # profile interface stays uniform.
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

    module Codex
      module_function

      # Search order:
      #   /<plugin>:<name>
      #     1. ~/.codex/plugins/cache/*<plugin>*/<plugin>*/*/skills/<name>/SKILL.md
      #        (cache layout is <marketplace>/<plugin>/<version>/skills/<name>/)
      #   /<name>
      #     1. ~/.codex/skills/<name>/SKILL.md
      #     2. ~/.codex/skills/.system/<name>/SKILL.md
      #     3. ~/.codex/plugins/cache/*/*/*/skills/<name>/SKILL.md (plugin fallback)
      def verify(invocation, project_root: nil)
        resolution = resolve(invocation, project_root: project_root)
        [ resolution.status, resolution.message ]
      end

      def resolve(invocation, project_root: nil, environment: ENV)
        inv = Hive::SkillCheck.parse(invocation)
        home = environment["HOME"] || Dir.home
        config_dir = environment["CODEX_HOME"].to_s
        config_dir = File.join(home, ".codex") if config_dir.empty?
        config_dir = File.expand_path(config_dir)
        candidates = build_candidates(inv, config_dir: config_dir, project_root: project_root)
        path = Hive::SkillCheck.first_existing(candidates)
        return Resolution.new(status: :present, path: path, message: path,
                              candidates: candidates.freeze, parse_errors: [].freeze) if path

        message = install_hint(inv)
        Resolution.new(status: :missing, path: nil, message: message,
                       candidates: candidates.freeze, parse_errors: [].freeze)
      rescue ArgumentError => e
        message = "codex: #{e.message}"
        Resolution.new(status: :missing, path: nil, message: message,
                       candidates: [].freeze, parse_errors: [].freeze)
      end

      def build_candidates(inv, config_dir:, project_root:)
        if inv.plugin
          plugin = Hive::SkillCheck.glob_escape(inv.plugin)
          name = Hive::SkillCheck.glob_escape(inv.name)
          # Cache layout produced by `codex plugin add`:
          # ~/.codex/plugins/cache/<owner>-<marketplace>/<plugin>/<version>/skills/<name>/SKILL.md
          glob = File.join(config_dir, "plugins/cache/*", plugin, "*", "skills", name, "SKILL.md")
          Dir[glob]
        else
          name = Hive::SkillCheck.glob_escape(inv.name)
          paths = []
          if project_root
            paths << File.join(project_root, ".codex/skills/#{inv.name}/SKILL.md")
          end
          paths << File.join(config_dir, "skills/#{inv.name}/SKILL.md")
          paths << File.join(config_dir, "skills/.system/#{inv.name}/SKILL.md")
          # Plugin fallback: codex resolves `/foo` against any installed
          # plugin's skill named `foo` in addition to user-level
          # ~/.codex/skills/. Mirrors claude's behaviour.
          paths.concat(Dir[File.join(config_dir, "plugins/cache/*/*/*/skills", name, "SKILL.md")])
          paths
        end
      end

      def install_hint(inv)
        if inv.plugin
          "codex: /#{inv.plugin}:#{inv.name} not found under " \
            "~/.codex/plugins/cache/*/#{inv.plugin}/*/skills/. " \
            "Install via `codex plugin add <plugin>@<marketplace>` for the marketplace " \
            "that ships #{inv.plugin}."
        else
          "codex: /#{inv.name} not found under ~/.codex/skills/, ~/.codex/skills/.system/, " \
            "or any installed plugin's skills/<name>/SKILL.md. Codex has no user-level " \
            "slash-command directory; either install a skill named #{inv.name.inspect}, " \
            "install a plugin that ships it, or override the stage's skill in config.yml " \
            "(e.g. `plan.skill: /ce-plan`)."
        end
      end
    end

    module Grok
      module_function

      def verify(invocation, project_root: nil)
        resolution = resolve(invocation, project_root: project_root)
        [ resolution.status, resolution.message ]
      end

      def resolve(invocation, project_root: nil, environment: ENV)
        inv = Hive::SkillCheck.parse(invocation)
        home = environment["HOME"] || Dir.home
        config_dir = environment["GROK_HOME"].to_s
        config_dir = File.join(home, ".grok") if config_dir.empty?
        config_dir = File.expand_path(config_dir)
        parse_errors = []
        candidates = build_candidates(
          inv,
          config_dir: config_dir,
          project_root: project_root,
          parse_errors: parse_errors
        )
        path = Hive::SkillCheck.first_existing(candidates)
        if path
          return Resolution.new(
            status: :present,
            path: path,
            message: path,
            candidates: candidates.freeze,
            parse_errors: parse_errors.freeze
          )
        end

        Resolution.new(
          status: :missing,
          path: nil,
          message: install_hint(inv),
          candidates: candidates.freeze,
          parse_errors: parse_errors.freeze
        )
      rescue ArgumentError => e
        message = "grok: #{e.message}"
        Resolution.new(
          status: :missing,
          path: nil,
          message: message,
          candidates: [].freeze,
          parse_errors: [].freeze
        )
      end

      def build_candidates(inv, config_dir:, project_root:, parse_errors: [])
        paths = []
        plugin = inv.plugin ? Hive::SkillCheck.glob_escape(inv.plugin) : "*"
        name = Hive::SkillCheck.glob_escape(inv.name)
        if project_root
          paths << File.join(project_root, ".grok", "skills", inv.name, "SKILL.md")
          paths.concat(
            Dir[File.join(project_root, ".grok", "plugins", plugin, "skills", name, "SKILL.md")]
          )
        end
        paths << File.join(config_dir, "skills", inv.name, "SKILL.md")
        paths.concat(
          Dir[File.join(config_dir, "plugins", plugin, "skills", name, "SKILL.md")]
        )
        installed_plugin_roots(config_dir, plugin: inv.plugin, parse_errors: parse_errors).each do |root|
          candidate = File.join(root, "skills", inv.name, "SKILL.md")
          path = jailed_skill_path(candidate, root, parse_errors: parse_errors)
          paths << path if path
        end
        paths
      end

      def installed_plugin_roots(config_dir, plugin: nil, parse_errors: [])
        registry_path = File.join(config_dir, "installed-plugins", "registry.json")
        document = JSON.parse(File.binread(registry_path))
        repos = document.fetch("repos", {})
        raise TypeError, "#{registry_path} repos must be an object" unless repos.is_a?(Hash)

        repos.filter_map do |repo_key, entry|
          unless entry.is_a?(Hash)
            parse_errors << "#{registry_path} repo #{repo_key.inspect} must be an object"
            next
          end
          plugins = entry["plugins"]
          unless plugins.is_a?(Hash)
            parse_errors << "#{registry_path} repo #{repo_key.inspect} plugins must be an object"
            next
          end
          names = plugins.keys.select { |name| plugin.nil? || name == plugin }
          next if names.empty? || names.none? { |name| plugin_enabled?(config_dir, name) }

          root = entry["path"] || File.join(config_dir, "installed-plugins", repo_key)
          jailed_install_root(root, config_dir, parse_errors: parse_errors)
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        []
      rescue JSON::ParserError, TypeError, KeyError, SystemCallError => e
        parse_errors << e.message
        []
      end

      def plugin_enabled?(config_dir, plugin_name)
        content = File.binread(File.join(config_dir, "config.toml"))
        section = content.match(/^\s*\[plugins\]\s*$\n?(.*?)(?=^\s*\[[^\]]+\]\s*$|\z)/m)&.[](1).to_s
        disabled = toml_string_array(section, "disabled")
        return false if plugin_name_match?(disabled, plugin_name)

        plugin_name_match?(toml_string_array(section, "enabled"), plugin_name)
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      end

      def toml_string_array(section, key)
        raw = section.match(/^\s*#{Regexp.escape(key)}\s*=\s*(\[.*?\])/m)&.[](1)
        return [] unless raw

        raw.scan(/"((?:\\.|[^"])*)"|'([^']*)'/).map do |double_quoted, single_quoted|
          if double_quoted
            JSON.parse(%("#{double_quoted}"))
          else
            single_quoted
          end
        end
      rescue JSON::ParserError
        []
      end

      def plugin_name_match?(entries, plugin_name)
        entries.any? { |entry| entry == plugin_name || entry.end_with?("/#{plugin_name}") }
      end

      def jailed_install_root(path, config_dir, parse_errors: [])
        root = resolved_path(File.join(config_dir, "installed-plugins"))
        candidate = resolved_path(path)
        return candidate if path_within?(candidate, root)

        parse_errors << "grok plugin path #{candidate.inspect} escapes #{root}"
        nil
      end

      def jailed_skill_path(path, install_root, parse_errors: [])
        root = resolved_path(install_root)
        candidate = resolved_path(path)
        return candidate if path_within?(candidate, root)

        parse_errors << "grok skill path #{candidate.inspect} escapes #{root}"
        nil
      end

      def path_within?(path, root)
        path == root || path.start_with?(root + File::SEPARATOR)
      end

      def resolved_path(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end

      def install_hint(inv)
        skill = inv.plugin ? "/#{inv.plugin}:#{inv.name}" : "/#{inv.name}"
        "grok: #{skill} is not available from an enabled Grok skill or plugin. " \
          "Install with `grok plugin install EveryInc/compound-engineering-plugin --trust` " \
          "or enable it with `grok plugin enable compound-engineering`."
      end
    end

  end
end
