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

      # Pi exposes `pi install <source>` for MCP-style extensions but
      # has no slash-command-resolution model: a `/foo` token in the
      # prompt is just text the model reads. The honest answer for any
      # invocation is `:not_applicable`, not `:present` (which would
      # over-promise) or `:missing` (which would imply the user needs
      # to install something).
      def verify(_invocation, project_root: nil)
        _ = project_root
        [ :not_applicable,
          "pi has no slash-command resolver — the invocation is passed " \
            "to the model as ordinary prompt text. If your pi-side prompt " \
            "still works without an installed skill, this is fine; otherwise " \
            "switch the stage's agent to claude or codex via config.yml." ]
      end
    end
  end
end
