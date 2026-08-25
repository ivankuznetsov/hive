require "hive/skill_check"
require "open3"
require "timeout"

module Hive::AgentSupport::Pi::Skills
  Resolution = Hive::SkillCheck::Resolution

  module_function

  NPM_ROOT_TIMEOUT_SEC = 2

  # Pi resolves `/skill:<name>` across user, cross-agent, project, settings,
  # npm, git, and package-manifest locations. Other invocation shapes are
  # intentionally not applicable because `skill:` is Pi's resource marker.
  def verify(invocation, project_root: nil) = resolve(invocation, project_root:)
    .then { |resolution| [ resolution.status, resolution.message ] }

  def resolve(invocation, project_root: nil, environment: ENV)
    inv = Hive::SkillCheck.parse(invocation)
    unless inv.plugin == "skill"
      message = "pi resolves skills as `/skill:<name>`, but got " \
                "#{invocation.inspect}. The invocation form is wrong for pi's " \
                "skill resolver — either change the agent profile's " \
                "`skill_syntax_format` to `/skill:%{skill}` or install a pi " \
                "extension that registers `#{invocation}` as a slash command."
      return Resolution.new(status: :not_applicable, path: nil, message: message,
                            candidates: [].freeze, parse_errors: [].freeze)
    end

    home = environment["HOME"] || Dir.home
    agent_dir = resolve_agent_dir(environment)
    parse_errors = []
    candidates = build_candidates(inv, home: home, agent_dir: agent_dir,
                                  project_root: project_root, parse_errors: parse_errors)
    path = Hive::SkillCheck.first_existing(candidates)
    return Resolution.new(status: :present, path: path, message: path,
                          candidates: candidates.freeze, parse_errors: parse_errors.freeze) if path

    message = install_hint(inv, parse_errors: parse_errors)
    Resolution.new(status: :missing, path: nil, message: message,
                   candidates: candidates.freeze, parse_errors: parse_errors.freeze)
  rescue ArgumentError => e
    message = "pi: #{e.message}"
    Resolution.new(status: :missing, path: nil, message: message,
                   candidates: [].freeze, parse_errors: [].freeze)
  end

  def resolve_agent_dir(environment = ENV)
    home = environment["HOME"] || Dir.home
    configured = environment["PI_CODING_AGENT_DIR"].to_s
    File.expand_path(configured.empty? ? File.join(home, ".pi", "agent") : configured)
  end

  def live_inventory(bin:, native_spec:, issues:, run:, package_version:, failure:)
    result = run[[ bin, "list" ]]
    issues << [ "incompatible", "pi package inventory failed: #{failure[result]}" ] unless result.success?
    lines = result.stdout.lines
    source_index = lines.index { |line| Hive::SkillCheck.same_source?(line.strip, native_spec.source) }
    install_path = lines[(source_index + 1)..]&.find { |line| !line.strip.empty? }&.strip if source_index
    package = package_record(
      native_spec, install_path, lines[source_index].strip, package_version
    ) if source_index
    { "package" => package, "marketplace" => nil }
  end

  def filesystem_inventory(native_spec:, root:, package_version:)
    install_path = install_path(root, native_spec.source)
    {
      "package" => install_path && package_record(
        native_spec, install_path, install_source(root, install_path), package_version
      ),
      "marketplace" => nil
    }.freeze
  end

  def package_record(native_spec, install_path, source, package_version)
    {
      "id" => native_spec.package, "version" => package_version[install_path],
      "enabled" => true, "install_path" => install_path, "source" => source
    }.freeze
  end

  def install_path(root, source)
    git_root = File.join(root, "git")
    direct = direct_install_path(git_root, source)
    return direct if direct && File.directory?(direct)
    return unless File.directory?(git_root)

    git_package_roots(git_root).sort.find do |path|
      Hive::SkillCheck.same_source?(install_source(root, path), source)
    end
  end

  def direct_install_path(git_root, source)
    uri = URI.parse(source.to_s)
    return unless uri.is_a?(URI::HTTP) && uri.host

    segments = uri.path.delete_prefix("/").sub(/\.git\z/i, "").split("/")
    return if segments.empty? || segments.any? { |part| !part.match?(/\A[A-Za-z0-9._-]+\z/) }

    File.join(git_root, uri.host, *segments)
  rescue URI::InvalidURIError
    nil
  end

  def install_source(root, install_path)
    git_root = File.join(root, "git")
    jailed = jail_path(install_path, [ git_root ]) or return

    "https://#{jailed.delete_prefix(File.expand_path(git_root) + File::SEPARATOR)}"
  end

  def build_candidates(inv, home:, agent_dir: File.join(home, ".pi", "agent"), project_root:, parse_errors: [])
    paths = []
    paths.concat(skill_location_candidates(File.join(agent_dir, "skills"), inv.name, include_root_md: true))
    paths.concat(skill_location_candidates(File.join(home, ".agents/skills"), inv.name, include_root_md: false))

    if project_root
      project = File.expand_path(project_root)
      paths.concat(skill_location_candidates(File.join(project, ".pi/skills"), inv.name, include_root_md: true))
      project_ancestors(project).each do |dir|
        paths.concat(skill_location_candidates(File.join(dir, ".agents/skills"), inv.name, include_root_md: false))
      end
    end

    settings_paths = [ File.join(agent_dir, "settings.json") ]
    if project_root
      settings_paths << File.join(File.expand_path(project_root), ".pi/settings.json")
    end
    paths.concat(settings_paths.flat_map do |settings_path|
      settings = read_json(settings_path, errors: parse_errors)
      settings ? settings_skill_candidates(
        settings, settings_path, home, inv.name, project_root: project_root
      ) : []
    end)

    paths.concat(package_candidates(home: home, agent_dir: agent_dir, project_root: project_root,
                                    settings_paths: settings_paths, name: inv.name,
                                    parse_errors: parse_errors))
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
    [
      File.join(root, name, "SKILL.md"),
      (File.join(root, "#{name}.md") if include_root_md),
      (File.join(root, "SKILL.md") if File.basename(root) == name),
      *Dir[File.join(root, "**", escaped, "SKILL.md")],
      *(include_root_md ? Dir[File.join(root, "#{escaped}.md")] : [])
    ].compact
  end

  def project_ancestors(project_root)
    Pathname.new(File.expand_path(project_root)).ascend.each_with_object([]) do |dir, paths|
      paths << dir.to_s
      break paths if dir.join(".git").exist?
    end
  end

  def package_candidates(home:, agent_dir: File.join(home, ".pi", "agent"), project_root:, settings_paths:, name:, parse_errors: [])
    paths = []
    node_roots = [
      File.join(home, ".pi/npm/node_modules"),
      File.join(agent_dir, "npm/node_modules"),
      global_npm_root,
      (File.join(File.expand_path(project_root), ".pi/npm/node_modules") if project_root)
    ].compact.uniq

    paths.concat(node_roots.flat_map { |root| node_modules_skill_candidates(root, name) })

    git_roots = [ File.join(agent_dir, "git") ]
    git_roots << File.join(File.expand_path(project_root), ".pi/git") if project_root
    paths.concat(git_roots.flat_map { |root| git_skill_candidates(root, name) })

    package_roots = node_roots.flat_map { |root| node_package_roots(root) } +
      git_roots.flat_map { |root| git_package_roots(root) } +
      settings_paths.flat_map do |path|
        settings_package_roots(path, home, project_root:, parse_errors:)
      end
    package_roots.compact.uniq.each do |package_root|
      paths.concat(package_root_candidates(package_root, name, parse_errors: parse_errors))
    end
    paths
  end

  def global_npm_root
    out, _err, status = Timeout.timeout(NPM_ROOT_TIMEOUT_SEC) do
      # npm writes a debug log under ~/.npm even for this read-only query.
      # Point its cache at the platform null device so doctor/setup previews
      # cannot modify the user's home merely by resolving Pi packages.
      Open3.capture3({ "npm_config_cache" => File::NULL }, "npm", "root", "-g")
    end
    return nil unless status.success?

    root = out.lines.first&.strip
    root unless root.nil? || root.empty?
  rescue Errno::ENOENT, SystemCallError, Timeout::Error
    nil
  end

  def package_root_candidates(package_root, name, parse_errors: [])
    skill_location_candidates(File.join(package_root, "skills"), name, include_root_md: true) +
      manifest_skill_candidates(package_root, name, parse_errors: parse_errors)
  end

  def node_modules_skill_candidates(node_root, name)
    escaped = Hive::SkillCheck.glob_escape(name)
    [ File.join(node_root, "*", "skills"), File.join(node_root, "@*", "*", "skills") ]
      .flat_map do |root|
        Dir[File.join(root, "**", escaped, "SKILL.md")] +
          Dir[File.join(root, "#{escaped}.md")]
      end
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
    paths = GIT_REPO_PREFIX_GLOBS.flat_map do |prefix|
      Dir[File.join(git_root, prefix, "skills", "**", escaped, "SKILL.md")] +
        Dir[File.join(git_root, prefix, "skills", "#{escaped}.md")]
    end
    paths.reject { |path| path.include?("/node_modules/") }
  end

  def node_package_roots(node_root)
    (Dir[File.join(node_root, "*", "package.json")] +
      Dir[File.join(node_root, "@*", "*", "package.json")]).map { |path| File.dirname(path) }
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
      local_path(source, settings_dir, home)&.then { |path| jail_path(path, jails) }
    end
  end

  def settings_skill_candidates(settings, settings_path, home, name, project_root: nil)
    settings_dir = File.dirname(settings_path)
    jails = settings_skill_jail_roots(settings_dir, home, project_root: project_root)
    Array(settings["skills"]).flat_map do |entry|
      local_path(entry, settings_dir, home)&.then do |path|
        jail_path(path, jails)&.then do |jailed|
          path_candidates(jailed, name, include_root_md: true)
        end
      end || []
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
    [ settings_dir, home, (File.expand_path(project_root) if project_root) ].compact.uniq
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
    resolved if Array(jail_roots).compact.any? do |root|
      resolved.start_with?(File.expand_path(root.to_s) + File::SEPARATOR)
    end
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

  def contains_glob?(path) = path.match?(/[{}\[\]*?]/)

  # `errors` (when provided) collects "<path>: <message>" strings for
  # JSON::ParserError so install_hint can surface the failed parses
  # to the operator. SystemCallError still swallows silently —
  # missing or unreadable files are not failures from doctor's
  # perspective; only malformed-but-present JSON is.
  def read_json(path, errors: nil)
    JSON.parse(File.binread(path))
  rescue JSON::ParserError => e
    errors&.push("#{path}: #{e.message.lines.first&.strip}")
    nil
  rescue SystemCallError
    nil
  end
end
