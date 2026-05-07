require "pathname"

module Hive
  # Per-agent verification that a configured slash-command skill
  # invocation actually resolves to a file on disk. `Hive::AgentProfile`
  # delegates to one of `SkillCheck::Claude` / `SkillCheck::Codex` /
  # `SkillCheck::Pi` so the profile interface stays uniform.
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
  #     — this agent has no slash-command-with-disk-resolution model
  #       (e.g. pi, which sends the prompt verbatim and treats slash
  #       text as ordinary characters in the user message).
  module SkillCheck
    # Parsed invocation. Either form is accepted:
    #   /name           -> Invocation.new(plugin: nil, name: "name")
    #   /plugin:name    -> Invocation.new(plugin: "plugin", name: "name")
    Invocation = Struct.new(:plugin, :name, keyword_init: true)

    # Raises ArgumentError on malformed input so callers can surface the
    # error rather than silently treating garbage as a valid skill.
    def self.parse(invocation)
      raise ArgumentError, "expected /name or /plugin:name, got nil" if invocation.nil?

      str = invocation.to_s
      m = str.match(%r{\A/(?:([^:/\s]+):)?([^:/\s]+)\z})
      raise ArgumentError, "expected /name or /plugin:name, got #{str.inspect}" unless m

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
        inv = Hive::SkillCheck.parse(invocation)
        home = ENV["HOME"] || Dir.home
        candidates = build_candidates(inv, home: home, project_root: project_root)
        path = Hive::SkillCheck.first_existing(candidates)
        return [ :present, path ] if path

        [ :missing, install_hint(inv) ]
      rescue ArgumentError => e
        [ :missing, "claude: #{e.message}" ]
      end

      def build_candidates(inv, home:, project_root:)
        if inv.plugin
          # Cache layout: <marketplace>/<plugin>/<version>/skills/<name>/SKILL.md
          cache_skill_glob = File.join(home, ".claude/plugins/cache/*", inv.plugin, "*", "skills", inv.name, "SKILL.md")
          cache_cmd_glob   = File.join(home, ".claude/plugins/cache/*", inv.plugin, "*", "commands", "#{inv.name}.md")
          # Marketplace source layout: <marketplace>/plugins/<plugin>/skills/<name>/SKILL.md
          mp_skill_glob = File.join(home, ".claude/plugins/marketplaces/*/plugins", inv.plugin, "skills", inv.name, "SKILL.md")
          mp_cmd_glob   = File.join(home, ".claude/plugins/marketplaces/*/plugins", inv.plugin, "commands", "#{inv.name}.md")
          (Dir[cache_skill_glob] + Dir[cache_cmd_glob] + Dir[mp_skill_glob] + Dir[mp_cmd_glob])
        else
          paths = []
          if project_root
            paths << File.join(project_root, ".claude/commands/#{inv.name}.md")
            paths << File.join(project_root, ".claude/skills/#{inv.name}/SKILL.md")
          end
          paths << File.join(home, ".claude/commands/#{inv.name}.md")
          paths << File.join(home, ".claude/skills/#{inv.name}/SKILL.md")
          # Plugin-fallback for bare invocations: claude's runtime
          # resolves `/foo` against any installed plugin's skill named
          # `foo` (in addition to user-level commands/skills).
          paths.concat(Dir[File.join(home, ".claude/plugins/cache/*/*/*/skills/#{inv.name}/SKILL.md")])
          paths.concat(Dir[File.join(home, ".claude/plugins/cache/*/*/*/commands/#{inv.name}.md")])
          paths.concat(Dir[File.join(home, ".claude/plugins/marketplaces/*/plugins/*/skills/#{inv.name}/SKILL.md")])
          paths.concat(Dir[File.join(home, ".claude/plugins/marketplaces/*/plugins/*/commands/#{inv.name}.md")])
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
        inv = Hive::SkillCheck.parse(invocation)
        home = ENV["HOME"] || Dir.home
        candidates = build_candidates(inv, home: home, project_root: project_root)
        path = Hive::SkillCheck.first_existing(candidates)
        return [ :present, path ] if path

        [ :missing, install_hint(inv) ]
      rescue ArgumentError => e
        [ :missing, "codex: #{e.message}" ]
      end

      def build_candidates(inv, home:, project_root:)
        if inv.plugin
          # Cache layout produced by `codex plugin install`:
          # ~/.codex/plugins/cache/<owner>-<marketplace>/<plugin>/<version>/skills/<name>/SKILL.md
          glob = File.join(home, ".codex/plugins/cache/*", inv.plugin, "*", "skills", inv.name, "SKILL.md")
          Dir[glob]
        else
          paths = []
          if project_root
            paths << File.join(project_root, ".codex/skills/#{inv.name}/SKILL.md")
          end
          paths << File.join(home, ".codex/skills/#{inv.name}/SKILL.md")
          paths << File.join(home, ".codex/skills/.system/#{inv.name}/SKILL.md")
          # Plugin fallback: codex resolves `/foo` against any installed
          # plugin's skill named `foo` in addition to user-level
          # ~/.codex/skills/. Mirrors claude's behaviour.
          paths.concat(Dir[File.join(home, ".codex/plugins/cache/*/*/*/skills/#{inv.name}/SKILL.md")])
          paths
        end
      end

      def install_hint(inv)
        if inv.plugin
          "codex: /#{inv.plugin}:#{inv.name} not found under " \
            "~/.codex/plugins/cache/*/#{inv.plugin}/*/skills/. " \
            "Install via `codex plugin install <marketplace>` for the marketplace " \
            "that ships #{inv.plugin}."
        else
          "codex: /#{inv.name} not found under ~/.codex/skills/, ~/.codex/skills/.system/, " \
            "or any installed plugin's skills/<name>/SKILL.md. Codex has no user-level " \
            "slash-command directory; either install a skill named #{inv.name.inspect}, " \
            "install a plugin that ships it, or override the stage's skill in config.yml " \
            "(e.g. `plan.skill: /compound-engineering:ce-plan`)."
        end
      end
    end

    module Pi
      module_function

      # Pi has a real skill-discovery model — the earlier "no
      # slash-command resolver" framing was wrong. Pi probes (per the
      # `@mariozechner/pi-coding-agent` README "Skills" section and
      # `dist/core/package-manager.js`):
      #
      #   1. ~/.pi/agent/skills/<name>/SKILL.md         (user)
      #   2. ~/.agents/skills/<name>/SKILL.md           (cross-agent shared)
      #   3. <project>/.pi/skills/<name>/SKILL.md       (project pi-only)
      #   4. <project>/.agents/skills/<name>/SKILL.md   (project cross-agent)
      #   5. Pi packages installed via `pi install` — npm/git roots
      #      that contain a `skills/` dir; covered by globbing
      #      common locations.
      #
      # Skills are invoked at runtime as `/skill:<name>`. Hive's pi
      # profile sets `skill_syntax_format: "/skill:%{skill}"` so the
      # formatted invocation that reaches this verifier looks like
      # `/skill:foo`. `Hive::SkillCheck.parse` reads that as
      # `plugin: "skill", name: "foo"`. We accept that parse and
      # probe by `name` only — the literal `skill:` prefix is pi's
      # resource-type marker, not a plugin namespace.
      #
      # Anything that isn't `/skill:<name>` (e.g., a custom profile
      # producing bare `/<name>`) returns `:not_applicable` with a
      # message naming the form mismatch — pi has no way to resolve
      # such an invocation as a skill.
      def verify(invocation, project_root: nil)
        inv = Hive::SkillCheck.parse(invocation)
        unless inv.plugin == "skill"
          return [ :not_applicable,
                   "pi resolves skills as `/skill:<name>`, but got " \
                     "#{invocation.inspect}. The invocation form is wrong for pi's " \
                     "skill resolver — either change the agent profile's " \
                     "`skill_syntax_format` to `/skill:%{skill}` or install a pi " \
                     "extension that registers `#{invocation}` as a slash command." ]
        end

        home = ENV["HOME"] || Dir.home
        candidates = build_candidates(inv, home: home, project_root: project_root)
        path = Hive::SkillCheck.first_existing(candidates)
        return [ :present, path ] if path

        [ :missing, install_hint(inv) ]
      rescue ArgumentError => e
        [ :missing, "pi: #{e.message}" ]
      end

      def build_candidates(inv, home:, project_root:)
        name = Hive::SkillCheck.glob_escape(inv.name)
        paths = []
        if project_root
          paths << File.join(project_root, ".pi/skills/#{inv.name}/SKILL.md")
          paths.concat(Dir[File.join(project_root, ".agents/skills/#{name}/SKILL.md")])
        end
        paths << File.join(home, ".pi/agent/skills/#{inv.name}/SKILL.md")
        paths << File.join(home, ".agents/skills/#{inv.name}/SKILL.md")
        # Pi packages installed via `pi install` — global npm root
        # (`getGlobalNpmRoot` in pi's package-manager) and project
        # pi-config (`<cwd>/.pi/npm/node_modules/<package>/skills/`).
        # We glob common npm-root locations rather than inferring the
        # exact one from pi's runtime; if a pi user uses a non-
        # standard root, the skill is still findable via the project
        # `.pi/npm/...` path.
        paths.concat(Dir[File.join(home, ".pi/npm/node_modules/*/skills/#{name}/SKILL.md")])
        if project_root
          paths.concat(Dir[File.join(project_root, ".pi/npm/node_modules/*/skills/#{name}/SKILL.md")])
        end
        paths
      end

      def install_hint(inv)
        "pi: /skill:#{inv.name} not found under ~/.pi/agent/skills/#{inv.name}/SKILL.md, " \
          "~/.agents/skills/#{inv.name}/SKILL.md, <project>/.pi/skills/#{inv.name}/SKILL.md, " \
          "<project>/.agents/skills/#{inv.name}/SKILL.md, or any installed pi package's " \
          "skills/ directory. Install via `pi install <package>` (npm or git source), or " \
          "drop a SKILL.md in one of the discovery paths."
      end
    end
  end
end
