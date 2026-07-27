require_relative "test_helper"
require "rbconfig"
require "yaml"

class AgentCliRuntimeMirrorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  MIRROR = File.join(ROOT, "mirror")
  SYNC = File.join(MIRROR, "sync.rb")
  WORKFLOW = File.join(MIRROR, "sync-from-hive.yml")
  RELEASE_WORKFLOW = File.join(MIRROR, "mirror-release.yml")
  SOURCE_SHA = "a" * 40
  CHECKOUT_ACTION = "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"
  RUBY_ACTION = "ruby/setup-ruby@95ef2b042f9d7a56d8268cba8559e2842e2ad01b"

  def test_sync_materializes_package_at_root_and_installs_mirror_admin
    Dir.mktmpdir("agent-cli-runtime-mirror") do |dir|
      source = File.join(dir, "source")
      destination = File.join(dir, "destination")
      build_source(source)
      build_destination(destination)

      out, err, status = Open3.capture3(
        RbConfig.ruby, SYNC, source, destination, SOURCE_SHA
      )

      assert status.success?, "#{out}\n#{err}"
      assert_equal "package\n", File.read(File.join(destination, "README.md"))
      assert_equal "runtime\n",
                   File.read(File.join(destination, "lib", "runtime.rb"))
      refute_path_exists File.join(destination, "stale.txt")
      refute_path_exists File.join(destination, "mirror")
      assert_path_exists File.join(destination, ".git", "keep")
      assert_equal "workflow\n",
                   File.read(
                     File.join(
                       destination, ".github", "workflows",
                       "sync-from-hive.yml"
                     )
                   )
      assert_equal "release workflow\n",
                   File.read(
                     File.join(
                       destination, ".github", "workflows",
                       "mirror-release.yml"
                     )
                   )
      refute_path_exists File.join(destination, ".github", "mirror")
      refute_path_exists(
        File.join(destination, ".github", "workflows", "old.yml")
      )
      assert_equal "contributing\n",
                   File.read(File.join(destination, "CONTRIBUTING.md"))
      assert_equal "security\n",
                   File.read(File.join(destination, "SECURITY.md"))

      manifest = JSON.parse(
        File.read(File.join(destination, ".mirror-source.json"))
      )
      assert_equal(
        {
          "repository" => "ivankuznetsov/hive",
          "component_path" => "components/agent-cli-runtime",
          "source_commit" => SOURCE_SHA
        },
        manifest
      )
    end
  end

  def test_sync_rejects_source_symlinks
    Dir.mktmpdir("agent-cli-runtime-mirror") do |dir|
      source = File.join(dir, "source")
      destination = File.join(dir, "destination")
      build_source(source)
      build_destination(destination)
      File.symlink("/tmp", File.join(source, "unsafe"))

      _out, err, status = Open3.capture3(
        RbConfig.ruby, SYNC, source, destination, SOURCE_SHA
      )

      refute status.success?
      assert_match(/source contains a symlink/, err)
      assert_path_exists File.join(destination, "stale.txt")
    end
  end

  def test_sync_rejects_missing_admin_before_mutating_destination
    Dir.mktmpdir("agent-cli-runtime-mirror") do |dir|
      source = File.join(dir, "source")
      destination = File.join(dir, "destination")
      build_source(source)
      FileUtils.rm_r(File.join(source, "mirror"))
      build_destination(destination)
      File.write(File.join(destination, "CONTRIBUTING.md"), "existing\n")
      File.write(File.join(destination, "SECURITY.md"), "existing\n")

      _out, err, status = Open3.capture3(
        RbConfig.ruby, SYNC, source, destination, SOURCE_SHA
      )

      refute status.success?
      assert_match(/source mirror administration is incomplete/, err)
      assert_match(/sync-from-hive\.yml/, err)
      assert_path_exists File.join(destination, "stale.txt")
      assert_equal(
        "old\n",
        File.read(
          File.join(destination, ".github", "workflows", "old.yml")
        )
      )
      assert_equal(
        "existing\n",
        File.read(File.join(destination, "CONTRIBUTING.md"))
      )
      assert_equal(
        "existing\n",
        File.read(File.join(destination, "SECURITY.md"))
      )
    end
  end

  def test_sync_rejects_partial_admin_before_mutating_destination
    Dir.mktmpdir("agent-cli-runtime-mirror") do |dir|
      source = File.join(dir, "source")
      destination = File.join(dir, "destination")
      build_source(source)
      FileUtils.rm(File.join(source, "mirror", "SECURITY.md"))
      build_destination(destination)

      _out, err, status = Open3.capture3(
        RbConfig.ruby, SYNC, source, destination, SOURCE_SHA
      )

      refute status.success?
      assert_match(/source mirror administration is incomplete/, err)
      assert_match(/SECURITY\.md/, err)
      assert_path_exists File.join(destination, "stale.txt")
      assert_path_exists(
        File.join(destination, ".github", "workflows", "old.yml")
      )
    end
  end

  def test_release_snapshot_omits_mirror_administration
    Dir.mktmpdir("agent-cli-runtime-mirror") do |dir|
      source = File.join(dir, "source")
      destination = File.join(dir, "destination")
      build_source(source)
      build_destination(destination)

      out, err, status = Open3.capture3(
        RbConfig.ruby, SYNC, source, destination, SOURCE_SHA, "--release"
      )

      assert status.success?, "#{out}\n#{err}"
      assert_equal "package\n", File.read(File.join(destination, "README.md"))
      refute_path_exists File.join(destination, "mirror")
      refute_path_exists File.join(destination, ".github")
      refute_path_exists File.join(destination, "CONTRIBUTING.md")
      refute_path_exists File.join(destination, "SECURITY.md")
      assert_path_exists File.join(destination, ".mirror-source.json")
    end
  end

  def test_mirror_files_are_not_packaged_in_the_gem
    spec = Gem::Specification.load(
      File.join(ROOT, "agent-cli-runtime.gemspec")
    )

    refute spec.files.any? { |path| path.start_with?("mirror/") }
  end

  def test_workflow_is_one_way_and_repository_scoped
    assert_instance_of Psych::Nodes::Document, YAML.parse_file(WORKFLOW)
    assert_instance_of(
      Psych::Nodes::Document,
      YAML.parse_file(RELEASE_WORKFLOW)
    )

    workflow = File.read(WORKFLOW)

    assert_includes workflow, "github.repository == 'ivankuznetsov/agent-cli-runtime'"
    assert_includes workflow, "contents: read"
    assert_includes workflow, "ssh-key: ${{ secrets.MIRROR_DEPLOY_KEY }}"
    assert_includes workflow, "repository: ivankuznetsov/hive"
    assert_actions_are_pinned(workflow)
    assert_equal 2, workflow.scan("uses: #{CHECKOUT_ACTION}").length
    assert_equal 1, workflow.scan("uses: #{RUBY_ACTION}").length
    assert_includes(
      workflow,
      "ruby hive/components/agent-cli-runtime/mirror/sync.rb"
    )
    refute_includes workflow, "mirror/.github/mirror/sync.rb"
    assert_includes workflow, "cd mirror"
    assert_includes workflow, "fetch-depth: 1"
    assert_includes workflow, "fetch-depth: 0"
    assert_includes workflow, "sparse-checkout: components/agent-cli-runtime"

    release_workflow = File.read(RELEASE_WORKFLOW)
    assert_includes release_workflow, "contents: write"
    assert_includes(
      release_workflow,
      "ssh-key: ${{ secrets.MIRROR_DEPLOY_KEY }}"
    )
    assert_actions_are_pinned(release_workflow)
    assert_equal 2, release_workflow.scan("uses: #{CHECKOUT_ACTION}").length
    assert_equal 1, release_workflow.scan("uses: #{RUBY_ACTION}").length
    assert_includes(
      release_workflow,
      'echo "tag_ref=refs/tags/components/agent-cli-runtime/$VERSION"'
    )
    assert_includes release_workflow, "ref: ${{ steps.request.outputs.tag_ref }}"
    assert_before(
      release_workflow,
      "- name: Validate the release request",
      "- name: Check out the canonical component tag"
    )
    assert_includes release_workflow, "bin/release-preflight"
    assert_includes release_workflow, "--release"
    assert_equal 1, release_workflow.scan('ruby "$sync"').length
    assert_includes release_workflow, "git -C hive archive"
    assert_includes release_workflow, "--exclude=mirror"
    assert_includes release_workflow, 'cd "$snapshot"'
    assert_includes release_workflow, "rm -rf --ignore-unmatch ."
    assert_includes(
      release_workflow,
      "sparse-checkout: components/agent-cli-runtime"
    )
    assert_includes release_workflow, "gh release create"
    assert_includes release_workflow, '--notes-file "$notes"'
    assert_includes(
      release_workflow,
      "https://rubygems.org/api/v1/versions/agent-cli-runtime.json"
    )
    assert_includes release_workflow, "--connect-timeout 5"
    assert_includes release_workflow, "--max-time 20"
    assert_includes release_workflow, "--retry 3"
    assert_includes(
      release_workflow,
      "EXPECTED_VERSION: ${{ steps.release.outputs.version }}"
    )
    assert_includes(
      release_workflow,
      "+refs/heads/main:refs/remotes/origin/main"
    )
    assert_includes release_workflow, 'includes.include?("refs/tags/v*")'
    assert_includes release_workflow, "%w[update deletion non_fast_forward]"
    assert_includes release_workflow, 'expected_tree="$(git -C "$expected" write-tree)"'
    assert_includes release_workflow, '"refs/tags/$VERSION^{tree}"'
    assert_includes release_workflow, 'test "$actual_tree" = "$expected_tree"'
    assert_includes release_workflow, 'test "$tag_tree" = "$expected_tree"'

    tag_push = 'git -C mirror push origin "refs/tags/$VERSION"'
    local_tag = 'git -C mirror tag "$VERSION"'
    assert_before(
      release_workflow,
      "https://rubygems.org/api/v1/versions/agent-cli-runtime.json",
      tag_push
    )
    assert_before release_workflow, "bin/release-preflight", tag_push
    assert_before release_workflow, "Require immutable mirror release tags", tag_push
    assert_before(
      release_workflow,
      "https://rubygems.org/api/v1/versions/agent-cli-runtime.json",
      local_tag
    )
    assert_before release_workflow, "bin/release-preflight", local_tag
    assert_before(
      release_workflow,
      "git -C hive archive",
      'expected_tree="$(git -C "$expected" write-tree)"'
    )
    assert_last_before(
      release_workflow,
      'test "$actual_tree" = "$expected_tree"',
      local_tag
    )
    assert_before(
      release_workflow,
      'test "$actual_tree" = "$expected_tree"',
      tag_push
    )
    assert_before(
      release_workflow,
      'test "$tag_tree" = "$expected_tree"',
      tag_push
    )
    assert_before(
      release_workflow,
      "- name: Verify the release snapshot",
      tag_push
    )
  end

  private

  def assert_actions_are_pinned(content)
    action_refs = content.scan(/^\s*uses:\s+([^\s#]+)/).flatten

    refute_empty action_refs
    action_refs.each do |action_ref|
      assert_match(/@[0-9a-f]{40}\z/, action_ref)
    end
  end

  def assert_before(content, first, second)
    first_index = content.index(first)
    second_index = content.index(second)

    refute_nil first_index, "missing first workflow contract: #{first}"
    refute_nil second_index, "missing second workflow contract: #{second}"
    assert_operator first_index, :<, second_index
  end

  def assert_last_before(content, first, second)
    first_index = content.rindex(first)
    second_index = content.index(second)

    refute_nil first_index, "missing first workflow contract: #{first}"
    refute_nil second_index, "missing second workflow contract: #{second}"
    assert_operator first_index, :<, second_index
  end

  def build_source(source)
    FileUtils.mkdir_p(File.join(source, "lib"))
    FileUtils.mkdir_p(File.join(source, "mirror"))
    File.write(File.join(source, "README.md"), "package\n")
    File.write(File.join(source, "lib", "runtime.rb"), "runtime\n")
    File.write(
      File.join(source, "mirror", "sync-from-hive.yml"),
      "workflow\n"
    )
    File.write(
      File.join(source, "mirror", "mirror-release.yml"),
      "release workflow\n"
    )
    File.write(
      File.join(source, "mirror", "CONTRIBUTING.md"),
      "contributing\n"
    )
    File.write(File.join(source, "mirror", "SECURITY.md"), "security\n")
    File.write(File.join(source, "mirror", "sync.rb"), "sync\n")
  end

  def build_destination(destination)
    FileUtils.mkdir_p(File.join(destination, ".git"))
    FileUtils.mkdir_p(File.join(destination, ".github", "workflows"))
    File.write(File.join(destination, ".git", "keep"), "keep\n")
    File.write(File.join(destination, "stale.txt"), "stale\n")
    File.write(
      File.join(destination, ".github", "workflows", "old.yml"),
      "old\n"
    )
  end
end
