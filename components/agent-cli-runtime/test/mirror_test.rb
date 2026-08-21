require_relative "test_helper"
require "find"
require "rbconfig"
require "yaml"

class AgentCliRuntimeMirrorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  MIRROR = File.join(ROOT, "mirror")
  SYNC = File.join(MIRROR, "sync.rb")
  WORKFLOW = File.join(MIRROR, "sync-from-hive.yml")
  RELEASE_WORKFLOW = File.join(MIRROR, "mirror-release.yml")
  RELEASE_NOTES = File.join(MIRROR, "release-notes.rb")
  SOURCE_SHA = "a" * 40
  CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
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

  def test_actual_projection_matches_an_independently_reconstructed_tree
    Dir.mktmpdir("agent-cli-runtime-mirror") do |dir|
      destination = File.join(dir, "destination")
      FileUtils.mkdir_p(File.join(destination, ".git"))

      out, err, status = Open3.capture3(
        RbConfig.ruby, SYNC, ROOT, destination, SOURCE_SHA
      )

      assert status.success?, "#{out}\n#{err}"
      assert_equal expected_projection, tree_snapshot(destination)
    end
  end

  def test_actual_projection_builds_and_installs_as_a_standalone_package
    Dir.mktmpdir("agent-cli-runtime-mirror") do |dir|
      destination = File.join(dir, "destination")
      dist = File.join(dir, "dist")
      git!(dir, "init", "--quiet", destination)

      out, err, status = Open3.capture3(
        RbConfig.ruby, SYNC, ROOT, destination, SOURCE_SHA
      )
      assert status.success?, "#{out}\n#{err}"
      git!(destination, "add", ".")
      git!(
        destination,
        "-c", "user.name=Agent CLI Runtime Test",
        "-c", "user.email=agent-cli-runtime@example.invalid",
        "commit", "--quiet", "-m", "projected package"
      )

      build_out, build_err, build_status = Open3.capture3(
        unbundled_environment,
        RbConfig.ruby, File.join(destination, "bin", "build-candidate"), dist
      )
      assert build_status.success?, "#{build_out}\n#{build_err}"
      manifest = JSON.parse(build_out.lines.last)
      refute manifest.fetch("source_dirty")
      gem_path = manifest.fetch("gem_path")
      assert_equal "agent-cli-runtime-0.2.3.gem", File.basename(gem_path)

      verify_out, verify_err, verify_status = Open3.capture3(
        unbundled_environment,
        RbConfig.ruby, File.join(destination, "bin", "verify-candidate"),
        gem_path, manifest.fetch("sha256")
      )
      assert verify_status.success?, "#{verify_out}\n#{verify_err}"
      assert_equal "0.2.3", JSON.parse(verify_out).fetch("version")
    end
  end

  def test_release_notes_extract_matching_dated_version
    changelog = <<~MARKDOWN
      # Changelog

      ## Unreleased

      - Future work.

      ## 0.2.0 - 2026-08-15

      - Add first-class OpenCode compatibility.
      - Preserve nullable usage evidence.

      ## 0.1.1 - 2026-08-12

      - Older work.
    MARKDOWN

    notes, out, err, status = build_release_notes(changelog, "v0.2.0")

    assert status.success?, "#{out}\n#{err}"
    assert_includes notes, "## Highlights"
    assert_includes notes, "Add first-class OpenCode compatibility."
    assert_includes notes, "Preserve nullable usage evidence."
    assert_includes notes, "gem install agent-cli-runtime --version 0.2.0"
    refute_includes notes, "Future work."
    refute_includes notes, "Older work."
  end

  def test_release_notes_accept_exact_version_heading
    changelog = <<~MARKDOWN
      # Changelog

      ## 0.2.0

      - Exact heading notes.
    MARKDOWN

    notes, out, err, status = build_release_notes(changelog, "v0.2.0")

    assert status.success?, "#{out}\n#{err}"
    assert_includes notes, "Exact heading notes."
  end

  def test_release_notes_reject_absent_version
    notes, _out, err, status = build_release_notes(
      "## 0.1.1\n\n- Older work.\n",
      "v0.2.0"
    )

    refute status.success?
    assert_nil notes
    assert_match(/no section for 0\.2\.0/, err)
  end

  def test_release_notes_reject_whitespace_only_section
    changelog = "## 0.2.0 - 2026-08-15\n \t \n\n" \
                "## 0.1.1\n\n- Older work.\n"

    notes, _out, err, status = build_release_notes(changelog, "v0.2.0")

    refute status.success?
    assert_nil notes
    assert_match(/section for 0\.2\.0 has no content/, err)
  end

  def test_release_notes_stop_at_next_version_boundary
    changelog = <<~MARKDOWN
      ## 0.2.0 - 2026-08-15

      ### OpenCode

      - Selected work.

      ## 0.1.1 - 2026-08-12

      - Must not cross the version boundary.
    MARKDOWN

    notes, out, err, status = build_release_notes(changelog, "v0.2.0")

    assert status.success?, "#{out}\n#{err}"
    assert_includes notes, "### OpenCode"
    assert_includes notes, "Selected work."
    refute_includes notes, "Must not cross the version boundary."
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
      "hive/components/agent-cli-runtime/mirror/release-notes.rb"
    )
    assert_includes(
      release_workflow,
      '"$RUNNER_TEMP/release-snapshot/CHANGELOG.md"'
    )
    refute_includes release_workflow, "mirror/CHANGELOG.md"
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
    assert_before(
      release_workflow,
      "Existing mirror tag $VERSION exactly matches the canonical snapshot.",
      "- name: Prepare snapshot-bound release notes"
    )
    assert_before(
      release_workflow,
      "- name: Prepare snapshot-bound release notes",
      tag_push
    )
    assert_before release_workflow, tag_push, "gh release create"
  end

  private

  def build_release_notes(changelog, version)
    Dir.mktmpdir("agent-cli-runtime-release-notes") do |dir|
      changelog_path = File.join(dir, "CHANGELOG.md")
      output_path = File.join(dir, "release-notes.md")
      File.write(changelog_path, changelog)

      out, err, status = Open3.capture3(
        RbConfig.ruby,
        RELEASE_NOTES,
        version,
        changelog_path,
        output_path
      )
      notes = File.read(output_path) if File.file?(output_path)
      return [ notes, out, err, status ]
    end
  end

  def expected_projection
    expected = {}
    Find.find(ROOT) do |path|
      relative = path.delete_prefix("#{ROOT}/")
      next if path == ROOT
      if relative == "mirror"
        Find.prune
        next
      end
      next unless File.file?(path)

      expected[relative] = file_identity(path)
    end
    {
      "sync-from-hive.yml" => ".github/workflows/sync-from-hive.yml",
      "mirror-release.yml" => ".github/workflows/mirror-release.yml",
      "CONTRIBUTING.md" => "CONTRIBUTING.md",
      "SECURITY.md" => "SECURITY.md"
    }.each do |source, target|
      expected[target] = file_identity(File.join(MIRROR, source))
    end
    manifest = JSON.pretty_generate(
      repository: "ivankuznetsov/hive",
      component_path: "components/agent-cli-runtime",
      source_commit: SOURCE_SHA
    ) + "\n"
    expected[".mirror-source.json"] = [
      Digest::SHA256.hexdigest(manifest), "100644"
    ]
    expected.sort.to_h
  end

  def tree_snapshot(root)
    snapshot = {}
    Find.find(root) do |path|
      relative = path.delete_prefix("#{root}/")
      next if path == root
      if relative == ".git"
        Find.prune
        next
      end
      next unless File.file?(path)

      snapshot[relative] = file_identity(path)
    end
    snapshot.sort.to_h
  end

  def file_identity(path)
    executable = (File.stat(path).mode & 0o111).zero? ? "100644" : "100755"
    [ Digest::SHA256.file(path).hexdigest, executable ]
  end

  def git!(directory, *arguments)
    out, err, status = Open3.capture3("git", "-C", directory, *arguments)
    assert status.success?, err
    out
  end

  def unbundled_environment
    ENV.keys.grep(/\A(?:BUNDLE|BUNDLER_)/).to_h do |key|
      [ key, nil ]
    end.merge(
      "GEM_HOME" => nil,
      "GEM_PATH" => nil,
      "RUBYGEMS_GEMDEPS" => nil,
      "RUBYLIB" => nil,
      "RUBYOPT" => nil
    )
  end

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
