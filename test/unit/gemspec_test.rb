require "test_helper"

class GemspecTest < Minitest::Test
  GEMSPEC_PATH = File.expand_path("../../hive.gemspec", __dir__)

  def test_gem_package_includes_babysitter_dry_run_stubs
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "bin/hive-babysitter-skip-log.rb"
    assert_includes spec.files, "bin/hive-babysitter-stub-gh.rb"
    assert_includes spec.files, "bin/hive-babysitter-stub-git"
  end

  def test_gem_package_includes_launcher_scripts
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "lib/hive/scripts/interactive_claude_wrapper.sh"
    assert_includes spec.files, "lib/hive/scripts/stop_hook.sh"
  end

  def test_gem_package_includes_builtin_bench_instructions
    spec = Gem::Specification.load(GEMSPEC_PATH)

    %w[extract generate judge publish].each do |stage|
      assert_includes spec.files, "templates/builtins/bench/#{stage}.md"
    end
  end

  def test_gem_package_includes_agent_skills_manifest
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "config/agent-skills.yml"
  end

  def test_gem_package_includes_every_canonical_hive_skill_asset
    spec = Gem::Specification.load(GEMSPEC_PATH)
    root = File.expand_path("../..", __dir__)
    expected = Dir.glob(File.join(root, "skills", "hive", "**", "*"), File::FNM_DOTMATCH)
                  .select { |path| File.file?(path) }
                  .map { |path| path.delete_prefix("#{root}/") }

    refute_empty expected
    expected.each { |path| assert_includes spec.files, path }
  end

  def test_gem_package_includes_workflow_creator_references
    spec = Gem::Specification.load(GEMSPEC_PATH)
    references = %w[
      workflow-creator.md
      workflow-creator-example.md
      workflow-schema.md
      workflow-stage-design.md
      workflow-checkpoints.md
      workflow-permissions.md
      workflow-testing.md
      workflow-common-mistakes.md
    ]

    references.each do |name|
      assert_includes spec.files, "skills/hive/references/#{name}"
    end
  end

  def test_gem_package_includes_metadata_for_managed_web_path_dependency
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "hive.gemspec",
                    "an installed hive-cli root must remain a valid Bundler path dependency"
  end

  def test_gem_executables_exclude_bash_hv_launcher
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.executables, "hive"
    refute_includes spec.executables, "hv"
    assert_includes spec.files, "bin/hv"
  end

  def test_runtime_dependencies_include_architecture_patrol_schema_validator
    spec = Gem::Specification.load(GEMSPEC_PATH)
    dependency = spec.runtime_dependencies.find { |candidate| candidate.name == "json_schemer" }

    refute_nil dependency
    assert dependency.requirement.satisfied_by?(Gem::Version.new("2.5.0"))
  end

  def test_runtime_dependencies_include_base64_used_by_pkce
    spec = Gem::Specification.load(GEMSPEC_PATH)

    refute_nil spec.runtime_dependencies.find { |candidate| candidate.name == "base64" }
  end

  # Ruby 3.4 unbundled or stopped guaranteeing several gems Hive's lib/ code
  # requires directly (base64, bigdecimal, rexml, ...). Twice this has been
  # fixed by adding an explicit gemspec declaration only after a stock install
  # crashed with LoadError (base64, then rexml), and each time the knowledge
  # lived only in comments and wiki pages. This guard turns it into a CI
  # failure: every `require "<name>"` in lib/ whose top-level name is a Ruby
  # 3.4 bundled-or-removed gem must appear somewhere in the runtime dependency
  # closure resolved from hive.gemspec.
  BUNDLED_OR_REMOVED_GEMS = %w[
    abbrev base64 bigdecimal csv drb getoptlong mutex_m nkf observer
    resolv-replace rexml rinda syslog
  ].freeze

  def test_runtime_dependencies_include_fiddle_for_managed_storage
    spec = Gem::Specification.load(GEMSPEC_PATH)
    dependency = spec.runtime_dependencies.find do |candidate|
      candidate.name == "fiddle"
    end

    refute_nil dependency
    assert dependency.requirement.satisfied_by?(Gem::Version.new("1.1.0"))
  end

  def test_runtime_dependencies_include_the_managed_web_locked_bundler
    spec = Gem::Specification.load(GEMSPEC_PATH)
    dependency = spec.runtime_dependencies.find { |candidate| candidate.name == "bundler" }

    refute_nil dependency
    assert_equal Gem::Requirement.new("= 2.7.2"), dependency.requirement
  end

  def test_runtime_dependencies_exclude_prdigest
    spec = Gem::Specification.load(GEMSPEC_PATH)
    dependency = spec.runtime_dependencies.find { |candidate| candidate.name == "prdigest" }

    assert_nil dependency
  end

  # The web tier is a Rails app under web/, supported only in the Docker
  # image or a source checkout — the gem must stay a lean CLI and not
  # package the app or its old Sinatra-era assets.
  def test_gem_package_excludes_the_rails_web_app
    spec = Gem::Specification.load(GEMSPEC_PATH)

    refute spec.files.any? { |f| f.start_with?("web/") },
           "the Rails app must not ship inside the gem"
    refute spec.files.any? { |f| f.start_with?("public/") },
           "no Sinatra-era static assets should be packaged"
  end

  def test_lib_requires_of_bundled_or_removed_gems_are_in_the_runtime_dependency_closure
    spec = Gem::Specification.load(GEMSPEC_PATH)
    closure = resolve_runtime_dependency_closure(spec)
    offenders = []

    lib_requires.each do |path, name|
      next unless BUNDLED_OR_REMOVED_GEMS.include?(name)
      next if closure.include?(name)

      offenders << %{#{path}: require "#{name}" is not covered by the hive.gemspec runtime dependency closure}
    end

    assert_empty offenders,
                 "lib/ requires Ruby 3.4 bundled-or-removed gems outside the " \
                 "declared runtime dependency closure; add an explicit " \
                 "spec.add_dependency to hive.gemspec:\n#{offenders.join("\n")}"
  end

  private

  def lib_requires
    root = File.expand_path("../..", __dir__)
    Dir.glob(File.join(root, "lib", "**", "*.rb")).sort.flat_map do |path|
      File.readlines(path).filter_map do |line|
        match = line.match(/\A\s*require\s+["']([^"'.][^"']*)["']/)
        next unless match

        [path.delete_prefix("#{root}/"), match[1].split("/").first]
      end
    end
  end

  def resolve_runtime_dependency_closure(spec)
    closure = {}
    queue = spec.runtime_dependencies.map(&:name)
    until queue.empty?
      name = queue.shift
      next if closure.key?(name)

      closure[name] = true
      begin
        Gem::Specification.find_by_name(name).runtime_dependencies.each do |dep|
          queue << dep.name
        end
      rescue Gem::Exception
        # A not-installed dependency cannot contribute transitive names here;
        # bundler resolves it for real installs, and direct declarations are
        # still caught because spec.runtime_dependencies seeds this closure.
      end
    end
    closure.keys
  end
end
