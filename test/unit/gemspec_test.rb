require "test_helper"

class GemspecTest < Minitest::Test
  GEMSPEC_PATH = File.expand_path("../../hive.gemspec", __dir__)

  def test_gem_package_includes_babysitter_dry_run_stubs
    spec = Gem::Specification.load(GEMSPEC_PATH)

    assert_includes spec.files, "bin/hive-babysitter-skip-log.rb"
    assert_includes spec.files, "bin/hive-babysitter-stub-gh"
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
end
