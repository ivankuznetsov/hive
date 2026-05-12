require "json"
require "open3"
require "pathname"
require "timeout"

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
  #     — this invocation form cannot be checked for this agent
  #       (e.g. pi only resolves skills as `/skill:<name>`).
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
          plugin = Hive::SkillCheck.glob_escape(inv.plugin)
          name = Hive::SkillCheck.glob_escape(inv.name)
          # Cache layout: <marketplace>/<plugin>/<version>/skills/<name>/SKILL.md
          cache_skill_glob = File.join(home, ".claude/plugins/cache/*", plugin, "*", "skills", name, "SKILL.md")
          cache_cmd_glob   = File.join(home, ".claude/plugins/cache/*", plugin, "*", "commands", "#{name}.md")
          # Marketplace source layout: <marketplace>/plugins/<plugin>/skills/<name>/SKILL.md
          mp_skill_glob = File.join(home, ".claude/plugins/marketplaces/*/plugins", plugin, "skills", name, "SKILL.md")
          mp_cmd_glob   = File.join(home, ".claude/plugins/marketplaces/*/plugins", plugin, "commands", "#{name}.md")
          (Dir[cache_skill_glob] + Dir[cache_cmd_glob] + Dir[mp_skill_glob] + Dir[mp_cmd_glob])
        else
          name = Hive::SkillCheck.glob_escape(inv.name)
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
          paths.concat(Dir[File.join(home, ".claude/plugins/cache/*/*/*/skills", name, "SKILL.md")])
          paths.concat(Dir[File.join(home, ".claude/plugins/cache/*/*/*/commands", "#{name}.md")])
          paths.concat(Dir[File.join(home, ".claude/plugins/marketplaces/*/plugins/*/skills", name, "SKILL.md")])
          paths.concat(Dir[File.join(home, ".claude/plugins/marketplaces/*/plugins/*/commands", "#{name}.md")])
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
          plugin = Hive::SkillCheck.glob_escape(inv.plugin)
          name = Hive::SkillCheck.glob_escape(inv.name)
          # Cache layout produced by `codex plugin install`:
          # ~/.codex/plugins/cache/<owner>-<marketplace>/<plugin>/<version>/skills/<name>/SKILL.md
          glob = File.join(home, ".codex/plugins/cache/*", plugin, "*", "skills", name, "SKILL.md")
          Dir[glob]
        else
          name = Hive::SkillCheck.glob_escape(inv.name)
          paths = []
          if project_root
            paths << File.join(project_root, ".codex/skills/#{inv.name}/SKILL.md")
          end
          paths << File.join(home, ".codex/skills/#{inv.name}/SKILL.md")
          paths << File.join(home, ".codex/skills/.system/#{inv.name}/SKILL.md")
          # Plugin fallback: codex resolves `/foo` against any installed
          # plugin's skill named `foo` in addition to user-level
          # ~/.codex/skills/. Mirrors claude's behaviour.
          paths.concat(Dir[File.join(home, ".codex/plugins/cache/*/*/*/skills", name, "SKILL.md")])
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

      NPM_ROOT_TIMEOUT_SEC = 2

      # Pi has a real skill-discovery model. It loads user skills,
      # cross-agent skills, project skills, package resources, and
      # explicit settings entries. Directories containing SKILL.md are
      # discovered recursively; `.pi/skills` and `~/.pi/agent/skills`
      # also accept root-level `<name>.md` skills.
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
        parse_errors = []
        candidates = build_candidates(inv, home: home, project_root: project_root, parse_errors: parse_errors)
        path = Hive::SkillCheck.first_existing(candidates)
        return [ :present, path ] if path

        [ :missing, install_hint(inv, parse_errors: parse_errors) ]
      rescue ArgumentError => e
        [ :missing, "pi: #{e.message}" ]
      end

      def build_candidates(inv, home:, project_root:, parse_errors: [])
        paths = []
        paths.concat(skill_location_candidates(File.join(home, ".pi/agent/skills"), inv.name, include_root_md: true))
        paths.concat(skill_location_candidates(File.join(home, ".agents/skills"), inv.name, include_root_md: false))

        if project_root
          project = File.expand_path(project_root)
          paths.concat(skill_location_candidates(File.join(project, ".pi/skills"), inv.name, include_root_md: true))
          project_ancestors(project).each do |dir|
            paths.concat(skill_location_candidates(File.join(dir, ".agents/skills"), inv.name, include_root_md: false))
          end
        end

        settings_paths = [ File.join(home, ".pi/agent/settings.json") ]
        if project_root
          settings_paths << File.join(File.expand_path(project_root), ".pi/settings.json")
        end
        settings_paths.each do |settings_path|
          settings = read_json(settings_path, errors: parse_errors)
          next unless settings

          paths.concat(settings_skill_candidates(settings, settings_path, home, inv.name, project_root: project_root))
        end

        paths.concat(package_candidates(home: home, project_root: project_root, settings_paths: settings_paths, name: inv.name, parse_errors: parse_errors))
        paths.compact.uniq
      end

      def install_hint(inv, parse_errors: [])
        hint = "pi: /skill:#{inv.name} not found in pi skill locations " \
          "(~/.pi/agent/skills, ~/.agents/skills, project .pi/skills, " \
          "project/ancestor .agents/skills), settings skills, or installed " \
          "pi packages' skills/ directories. Install via `pi install <package>` (npm, git, or " \
          "local source), add a settings skill path, or drop a SKILL.md/.md " \
          "skill in one of the discovery paths."
        unless parse_errors.empty?
          summary = parse_errors.first(3).join("; ")
          suffix = parse_errors.size > 3 ? " (and #{parse_errors.size - 3} more)" : ""
          hint += " Note: failed to parse #{parse_errors.size} settings/manifest file(s): #{summary}#{suffix}. Fix the malformed JSON to enable those discovery paths."
        end
        hint
      end

      def skill_location_candidates(root, name, include_root_md:)
        escaped = Hive::SkillCheck.glob_escape(name)
        paths = []
        paths << File.join(root, name, "SKILL.md")
        paths << File.join(root, "#{name}.md") if include_root_md
        paths << File.join(root, "SKILL.md") if File.basename(root) == name
        paths.concat(Dir[File.join(root, "**", escaped, "SKILL.md")])
        paths.concat(Dir[File.join(root, "#{escaped}.md")]) if include_root_md
        paths
      end

      def project_ancestors(project_root)
        dirs = []
        dir = File.expand_path(project_root)
        loop do
          dirs << dir
          break if File.exist?(File.join(dir, ".git"))

          parent = File.dirname(dir)
          break if parent == dir

          dir = parent
        end
        dirs
      end

      def package_candidates(home:, project_root:, settings_paths:, name:, parse_errors: [])
        paths = []
        node_roots = [
          File.join(home, ".pi/npm/node_modules"),
          File.join(home, ".pi/agent/npm/node_modules"),
          global_npm_root
        ]
        if project_root
          project = File.expand_path(project_root)
          node_roots << File.join(project, ".pi/npm/node_modules")
        end
        node_roots = node_roots.compact.uniq

        node_roots.each do |node_root|
          paths.concat(node_modules_skill_candidates(node_root, name))
        end

        git_roots = [ File.join(home, ".pi/agent/git") ]
        git_roots << File.join(File.expand_path(project_root), ".pi/git") if project_root
        git_roots.each do |git_root|
          paths.concat(git_skill_candidates(git_root, name))
        end

        package_roots = node_roots.flat_map { |root| node_package_roots(root) }
        package_roots.concat(git_roots.flat_map { |root| git_package_roots(root) })
        package_roots.concat(settings_paths.flat_map do |path|
          settings_package_roots(path, home, project_root: project_root, parse_errors: parse_errors)
        end)
        package_roots.compact.uniq.each do |package_root|
          paths.concat(package_root_candidates(package_root, name, parse_errors: parse_errors))
        end
        paths
      end

      def global_npm_root
        out, _err, status = Timeout.timeout(NPM_ROOT_TIMEOUT_SEC) do
          Open3.capture3("npm", "root", "-g")
        end
        return nil unless status.success?

        root = out.lines.first&.strip
        root unless root.nil? || root.empty?
      rescue Errno::ENOENT, SystemCallError, Timeout::Error
        nil
      end

      def package_root_candidates(package_root, name, parse_errors: [])
        paths = skill_location_candidates(File.join(package_root, "skills"), name, include_root_md: true)
        paths.concat(manifest_skill_candidates(package_root, name, parse_errors: parse_errors))
        paths
      end

      def node_modules_skill_candidates(node_root, name)
        escaped = Hive::SkillCheck.glob_escape(name)
        paths = []
        [ File.join(node_root, "*", "skills"), File.join(node_root, "@*", "*", "skills") ].each do |skills_root|
          paths.concat(Dir[File.join(skills_root, "**", escaped, "SKILL.md")])
          paths.concat(Dir[File.join(skills_root, "#{escaped}.md")])
        end
        paths
      end

      # Pi's git cache has a known bounded shape — `<git_root>/<host>/<repo>/`
      # in flat layouts, `<git_root>/<host>/<user>/<repo>/` for github-style
      # caches. We enumerate 1–4 fixed prefix levels so the upper search
      # depth is O(1) regardless of how big any single repo's working tree
      # is. The lower `**` under each candidate `skills/` is fine — pi
      # skills nest arbitrarily deep beneath that anchor.
      GIT_REPO_PREFIX_GLOBS = %w[
        */
        */*/
        */*/*/
        */*/*/*/
      ].freeze

      def git_skill_candidates(git_root, name)
        escaped = Hive::SkillCheck.glob_escape(name)
        paths = []
        GIT_REPO_PREFIX_GLOBS.each do |prefix|
          paths.concat(Dir[File.join(git_root, prefix, "skills", "**", escaped, "SKILL.md")])
          paths.concat(Dir[File.join(git_root, prefix, "skills", "#{escaped}.md")])
        end
        paths.reject { |path| path.include?("/node_modules/") }
      end

      def node_package_roots(node_root)
        package_jsons = Dir[File.join(node_root, "*", "package.json")]
        package_jsons.concat(Dir[File.join(node_root, "@*", "*", "package.json")])
        package_jsons.map { |path| File.dirname(path) }
      end

      def git_package_roots(git_root)
        # Bounded prefix scan — see GIT_REPO_PREFIX_GLOBS rationale.
        # package.json sits at a repo root, not deep in submodules, so we
        # never recurse with `**`.
        paths = GIT_REPO_PREFIX_GLOBS.flat_map do |prefix|
          Dir[File.join(git_root, prefix, "package.json")]
        end
        paths.reject { |path| path.include?("/node_modules/") }
          .map { |path| File.dirname(path) }
      end

      def settings_package_roots(settings_path, home, project_root: nil, parse_errors: [])
        settings = read_json(settings_path, errors: parse_errors)
        return [] unless settings

        settings_dir = File.dirname(settings_path)
        jails = settings_skill_jail_roots(settings_dir, home, project_root: project_root)
        Array(settings["packages"]).filter_map do |entry|
          source = entry.is_a?(Hash) ? entry["source"] : entry
          path = local_path(source, settings_dir, home)
          next nil unless path

          jail_path(path, jails)
        end
      end

      def settings_skill_candidates(settings, settings_path, home, name, project_root: nil)
        settings_dir = File.dirname(settings_path)
        jails = settings_skill_jail_roots(settings_dir, home, project_root: project_root)
        Array(settings["skills"]).flat_map do |entry|
          path = local_path(entry, settings_dir, home)
          next [] unless path

          jailed = jail_path(path, jails)
          next [] unless jailed

          path_candidates(jailed, name, include_root_md: true)
        end
      end

      def manifest_skill_candidates(package_root, name, parse_errors: [])
        package_json = File.join(package_root, "package.json")
        data = read_json(package_json, errors: parse_errors)
        skills = data&.dig("pi", "skills")
        return [] unless skills

        package_jail = File.expand_path(package_root)
        Array(skills).flat_map do |entry|
          next [] unless entry.is_a?(String)

          trimmed = entry.strip
          next [] if trimmed.empty? || trimmed.start_with?("!", "-")

          trimmed = trimmed.delete_prefix("+")
          pattern = absolute_or_relative_path(trimmed, package_root)
          # Each pi.skills entry must resolve strictly under package_root.
          # A literal-path entry that escapes (e.g., "../../../") is
          # dropped entirely; a glob entry (e.g., "*-skills") is expanded
          # then jailed per match.
          if contains_glob?(pattern)
            Dir[pattern].filter_map { |match| jail_path(match, package_jail) }
                        .flat_map { |path| path_candidates(path, name, include_root_md: true) }
          else
            jailed = jail_path(pattern, package_jail)
            jailed ? path_candidates(jailed, name, include_root_md: true) : []
          end
        end
      end

      # Allowed roots for paths read out of a settings.json `skills` /
      # `packages` entry. Strict prefix containment — an entry that
      # resolves to one of these roots exactly (e.g., `~/` or `./`) is
      # rejected, because globbing recursively from `home` or the
      # settings dir is a DoS in disguise.
      def settings_skill_jail_roots(settings_dir, home, project_root: nil)
        roots = [ settings_dir, home ]
        roots << File.expand_path(project_root) if project_root
        roots.compact.uniq
      end

      # Returns `path` (expanded) when it lies strictly inside any of
      # `jail_roots`; otherwise nil. Strict means the resolved path must
      # share a `<root>/` prefix — equality with a root is rejected so
      # operator-supplied entries like `~/` cannot widen the scan to
      # the whole home directory. Path segments containing `..` are
      # collapsed by `File.expand_path`, so traversal entries are caught
      # automatically.
      def jail_path(path, jail_roots)
        return nil unless path

        resolved = File.expand_path(path.to_s)
        Array(jail_roots).each do |root|
          next unless root

          expanded = File.expand_path(root.to_s)
          return resolved if resolved.start_with?(expanded + File::SEPARATOR)
        end
        nil
      end

      def path_candidates(path, name, include_root_md:)
        if path.end_with?(".md")
          skill_file_matches?(path, name) ? [ path ] : []
        else
          skill_location_candidates(path, name, include_root_md: include_root_md)
        end
      end

      def local_path(value, base_dir, home)
        return nil unless value.is_a?(String)

        trimmed = value.strip
        return nil if trimmed.empty? || trimmed.start_with?("npm:", "git:", "http://", "https://", "ssh://", "git://")

        absolute_or_relative_path(trimmed, base_dir, home: home)
      end

      def absolute_or_relative_path(path, base_dir, home: ENV["HOME"] || Dir.home)
        if path == "~"
          home
        elsif path.start_with?("~/")
          File.join(home, path.delete_prefix("~/"))
        elsif Pathname.new(path).absolute?
          path
        else
          File.expand_path(path, base_dir)
        end
      end

      def skill_file_matches?(path, name)
        return true if File.basename(path, ".md") == name
        return false unless File.file?(path)

        content = File.read(path, 4096)
        frontmatter = content.match(/\A---\s*\n(.*?)\n---/m)&.[](1)
        return false unless frontmatter

        frontmatter.match?(/^\s*name:\s*["']?#{Regexp.escape(name)}["']?\s*$/)
      rescue SystemCallError
        false
      end

      def contains_glob?(path)
        path.match?(/[{}\[\]*?]/)
      end

      # `errors` (when provided) collects "<path>: <message>" strings for
      # JSON::ParserError so install_hint can surface the failed parses
      # to the operator. SystemCallError still swallows silently —
      # missing or unreadable files are not failures from doctor's
      # perspective; only malformed-but-present JSON is.
      def read_json(path, errors: nil)
        return nil unless File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        errors&.push("#{path}: #{e.message.lines.first&.strip}")
        nil
      rescue SystemCallError
        nil
      end
    end
  end
end
