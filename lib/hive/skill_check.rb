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
          "claude: /#{inv.name} not found under ~/.claude/{commands,skills}/ " \
            "(or <project>/.claude/...). Install as a user-level slash command " \
            "(write ~/.claude/commands/#{inv.name}.md) or as a skill " \
            "(write ~/.claude/skills/#{inv.name}/SKILL.md)."
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
          "codex: /#{inv.name} not found under ~/.codex/skills/ or skills/.system/. " \
            "Codex has no user-level slash-command directory; either install a " \
            "skill named #{inv.name.inspect} or override the stage's skill in " \
            "config.yml (e.g. `plan.skill: /compound-engineering:ce-plan`)."
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
