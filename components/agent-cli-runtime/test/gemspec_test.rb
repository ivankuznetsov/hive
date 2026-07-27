require_relative "test_helper"

class AgentCliRuntimeGemspecTest < Minitest::Test
  GEMSPEC = File.expand_path("../agent-cli-runtime.gemspec", __dir__)

  def test_public_identity_and_inventory
    spec = Gem::Specification.load(GEMSPEC)

    assert_equal "agent-cli-runtime", spec.name
    assert_equal Gem::Version.new("0.1.0"), spec.version
    assert_equal Gem::Requirement.new(">= 3.4.0"), spec.required_ruby_version
    assert_equal [ "agent-runtime" ], spec.executables
    assert_equal "MIT", spec.license
    %w[
      README.md
      CHANGELOG.md
      LICENSE.txt
      lib/agent_cli_runtime.rb
      lib/agent_cli_runtime/version.rb
      exe/agent-runtime
    ].each { |path| assert_includes spec.files, path }
  end

  def test_every_non_core_direct_dependency_is_declared
    spec = Gem::Specification.load(GEMSPEC)

    assert_equal %w[json open3 timeout], spec.runtime_dependencies.map(&:name).sort
  end

  def test_public_links_use_the_distribution_mirror_and_canonical_issue_tracker
    spec = Gem::Specification.load(GEMSPEC)

    assert_equal "https://github.com/ivankuznetsov/agent-cli-runtime",
                 spec.homepage
    assert_equal spec.homepage, spec.metadata.fetch("homepage_uri")
    assert_equal spec.homepage, spec.metadata.fetch("source_code_uri")
    assert_equal "#{spec.homepage}/blob/main/CHANGELOG.md",
                 spec.metadata.fetch("changelog_uri")
    assert_equal "#{spec.homepage}/blob/main/README.md",
                 spec.metadata.fetch("documentation_uri")
    assert_equal "https://github.com/ivankuznetsov/hive/issues",
                 spec.metadata.fetch("bug_tracker_uri")
  end
end
