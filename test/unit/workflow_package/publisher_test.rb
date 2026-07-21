require "test_helper"
require "hive/workflow_package/publisher"

class WorkflowPackagePublisherTest < Minitest::Test
  include HiveTestHelper

  Package = Hive::WorkflowPackage::Publisher::Package
  Status = Data.define(:ok) do
    def success? = ok
  end

  def test_builds_only_the_canonical_immutable_version_payload_deterministically
    with_authored_workflow do |project, authored_dir|
      File.write(File.join(authored_dir, "ignored.txt"), "do not publish\n")
      manifests = 2.times.map do
        Dir.mktmpdir("publisher-test-") do |destination|
          package = publisher(project).package(destination: destination)
          assert_equal %w[README.md instructions/work.md manifest.yml workflow.yml],
                       Dir.glob(File.join(destination, "**", "*"), File::FNM_DOTMATCH)
                          .select { |path| File.file?(path) }
                          .map { |path| path.delete_prefix("#{destination}/") }.sort
          assert_includes File.read(File.join(destination, "workflow.yml")), "instructions/work.md"
          document = YAML.safe_load(File.binread(File.join(destination, "manifest.yml")))
          assert_equal "honeycomb-manifest/v1", document.fetch("schema")
          assert_equal "demo", document.fetch("name")
          assert_equal "1.2.3", document.fetch("version")
          assert document.fetch("files").keys.all? { |path| path.start_with?("packages/demo/1.2.3/") }
          assert_equal package.release_digest, document.fetch("release_sha256")
          assert_equal package.package_digest, Digest::SHA256.file(File.join(destination, "manifest.yml")).hexdigest
          File.binread(File.join(destination, "manifest.yml"))
        end
      end

      assert_equal manifests.first, manifests.last
    end
  end

  def test_secret_fails_preflight_without_leaking_secret_material
    secret = "sk-ant-#{'x' * 30}"
    with_authored_workflow(instruction: "Use #{secret}\n") do |project, _authored_dir|
      error = Dir.mktmpdir("publisher-test-") do |destination|
        assert_raises(Hive::WorkflowPackage::PackageError) do
          publisher(project).package(destination: destination)
        end
      end
      refute_includes error.message, secret
    end
  end

  def test_missing_or_placeholder_metadata_stops_before_submission
    with_authored_workflow do |project, authored_dir|
      File.write(File.join(authored_dir, "honeycomb.yml"), "summary: Describe what this workflow does\nauthor:\n  name: Your name\n")
      assert_raises(Hive::ConfigError) do
        Dir.mktmpdir("publisher-test-") { |destination| publisher(project).package(destination: destination) }
      end
    end
  end

  def test_pull_request_client_reuses_a_duplicate_open_submission
    calls = []
    runner = lambda do |args, chdir:|
      calls << [ args, chdir ]
      out = case args.take(3)
      when [ "gh", "api", "user" ] then JSON.generate("login" => "alice")
      when [ "gh", "pr", "list" ] then JSON.generate([ { "url" => "https://example.test/pr/7" } ])
      else ""
      end
      [ out, "", Status.new(ok: true) ]
    end
    client = Hive::WorkflowPackage::Publisher::RegistryPullRequest.new(runner: runner)
    package = Package.new(name: "demo", version: "1.2.3", root: Dir.pwd,
                          manifest_digest: "a" * 64, warnings: [])

    assert_equal "https://example.test/pr/7", client.open(package)
    refute calls.any? { |(args, _)| args.take(3) == [ "gh", "repo", "clone" ] }
  end

  def test_pull_request_client_uses_clean_checkout_body_file_and_fork_head
    with_tmp_dir do |package_root|
      File.write(File.join(package_root, "manifest.json"), "{}\n")
      calls = []
      body = nil
      runner = lambda do |args, chdir:|
        calls << [ args, chdir ]
        output = case args.take(3)
        when [ "gh", "api", "user" ]
          JSON.generate("login" => "alice")
        when [ "gh", "pr", "list" ]
          "[]"
        when [ "gh", "pr", "create" ]
          body = File.read(args.fetch(args.index("--body-file") + 1))
          "https://example.test/pr/8\n"
        else
          ""
        end
        [ output, "", Status.new(ok: true) ]
      end
      client = Hive::WorkflowPackage::Publisher::RegistryPullRequest.new(runner: runner)
      package = Package.new(name: "demo", version: "1.2.3", root: package_root,
                            manifest_digest: "b" * 64, warnings: [])

      assert_equal "https://example.test/pr/8", client.open(package)
      push = calls.find { |(args, _)| args.take(2) == [ "git", "push" ] }.first
      create = calls.find { |(args, _)| args.take(3) == [ "gh", "pr", "create" ] }.first
      assert_includes push, "honeycomb-demo-1.2.3-#{'b' * 12}"
      assert_includes create, "alice:honeycomb-demo-1.2.3-#{'b' * 12}"
      assert_includes body, "pending registry checks and trusted non-author review"
    end
  end

  def test_publish_delegates_to_the_registry_submission
    submitted = nil
    submission = Object.new
    receipt = Object.new
    submission.define_singleton_method(:submit) { |package| submitted = package; Struct.new(:receipt).new(receipt) }
    resolver = Object.new
    resolver.define_singleton_method(:resolve) { |value| value.equal?(receipt) ? "submitted" : raise("wrong receipt") }
    package = Package.new(name: "demo", version: "1.2.3", root: Dir.pwd,
                          manifest_digest: "a" * 64, warnings: [])
    instance = Hive::WorkflowPackage::Publisher.new(
      "demo", project_root: Dir.pwd, version: "1.2.3", submission: submission, resolver: resolver
    )

    assert_equal "submitted", instance.publish(package)
    assert_same package, submitted
  end

  def test_package_rejects_invalid_identity_and_nonempty_destination
    with_tmp_dir do |project|
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::Publisher.new("Bad Name", project_root: project, version: "1.0.0")
                                                .package(destination: File.join(project, "out"))
      end
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::Publisher.new("demo", project_root: project, version: "latest")
                                                .package(destination: File.join(project, "out"))
      end
      destination = File.join(project, "occupied")
      FileUtils.mkdir_p(destination)
      File.write(File.join(destination, "file"), "occupied")
      assert_raises(Hive::ConfigError) { publisher(project).package(destination: destination) }
    end
  end

  def test_package_reports_missing_and_invalid_authored_inputs
    with_authored_workflow do |project, authored_dir|
      workflows = File.dirname(authored_dir)
      descriptor = File.join(workflows, "demo.yml")
      FileUtils.rm_f(descriptor)
      assert_raises(Hive::ConfigError) do
        Dir.mktmpdir { |destination| publisher(project).package(destination: destination) }
      end
      instance = publisher(project)
      with_replaced_singleton_method(
        Hive::Workflows::DescriptorParser, :parse_file, ->(_path) { true }
      ) do
        assert_raises(Hive::ConfigError) { instance.send(:load_descriptor) }
      end

      File.write(descriptor, "id: [invalid")
      with_replaced_singleton_method(
        Hive::Workflows::DescriptorParser, :parse_file, ->(_path) { true }
      ) do
        assert_raises(Hive::ConfigError) { instance.send(:load_descriptor) }
      end

      metadata = File.join(authored_dir, "honeycomb.yml")
      FileUtils.rm_f(metadata)
      assert_raises(Hive::ConfigError) { instance.send(:load_metadata) }
      File.write(metadata, "summary: [invalid")
      assert_raises(Hive::ConfigError) { instance.send(:load_metadata) }
    end
  end

  def test_package_requires_nonempty_and_readable_readme
    with_authored_workflow do |project, authored_dir|
      instance = publisher(project)
      metadata = YAML.safe_load(File.read(File.join(authored_dir, "honeycomb.yml")))
      readme = File.join(authored_dir, "README.md")
      File.write(readme, "  \n")
      assert_raises(Hive::ConfigError) { instance.send(:validate_authored_metadata!, metadata) }

      File.write(readme, "# Demo\n")
      original = File.method(:read)
      File.define_singleton_method(:read) do |path, *args|
        raise Errno::EACCES if path == readme

        original.call(path, *args)
      end
      begin
        assert_raises(Hive::ConfigError) { instance.send(:validate_authored_metadata!, metadata) }
      ensure
        File.define_singleton_method(:read, original)
      end
    end
  end

  def test_instruction_rewrite_rejects_collisions_and_invalid_files
    with_authored_workflow do |project, authored_dir|
      instance = publisher(project)
      instance.define_singleton_method(:resolve_instruction) do |value|
        value == "one" ? [ "/source/one", "same.md" ] : [ "/source/two", "same.md" ]
      end
      descriptor = { "stages" => [ { "instruction" => "one" }, { "instruction" => "two" } ] }
      assert_raises(Hive::ConfigError) { instance.send(:rewrite_instructions, descriptor) }
      assert_equal "scalar", instance.send(:deep_transform, "scalar") { |_key, value| value }

      clean = publisher(project)
      assert_raises(Hive::ConfigError) { clean.send(:resolve_instruction, nil) }
      assert_raises(Hive::ConfigError) { clean.send(:resolve_instruction, "../outside.md") }
      FileUtils.rm_f(File.join(authored_dir, "work.md"))
      assert_raises(Hive::ConfigError) { clean.send(:resolve_instruction, "./demo/work.md") }
      File.write(File.join(authored_dir, "target.md"), "target")
      File.symlink("target.md", File.join(authored_dir, "work.md"))
      assert_raises(Hive::ConfigError) { clean.send(:resolve_instruction, "./demo/work.md") }
    end
  end

  def test_copy_authored_file_rejects_links_and_missing_files
    with_tmp_dir do |dir|
      target = File.join(dir, "target")
      File.write(target, "content")
      link = File.join(dir, "link")
      File.symlink("target", link)
      instance = publisher(dir)

      assert_raises(Hive::ConfigError) do
        instance.send(:copy_authored_file, link, File.join(dir, "copy"), label: "README.md")
      end
      assert_raises(Hive::ConfigError) do
        instance.send(:copy_authored_file, File.join(dir, "missing"), File.join(dir, "copy"), label: "README.md")
      end
    end
  end

  def test_pull_request_helper_rejects_invalid_remote_responses_and_command_failures
    invalid_viewer = runner_for([ [ "", "", Status.new(ok: true) ], [ "not-json", "", Status.new(ok: true) ] ])
    assert_raises(Hive::WorkflowPackage::PublishError) do
      Hive::WorkflowPackage::Publisher::RegistryPullRequest.new(runner: invalid_viewer)
                                                       .open(sample_package)
    end

    invalid_duplicate = runner_for([ [ "not-json", "", Status.new(ok: true) ] ])
    client = Hive::WorkflowPackage::Publisher::RegistryPullRequest.new(runner: invalid_duplicate)
    assert_raises(Hive::WorkflowPackage::PublishError) { client.send(:existing_pr, "alice", "branch") }

    failing = ->(_args, chdir:) { raise Errno::ENOENT }
    client = Hive::WorkflowPackage::Publisher::RegistryPullRequest.new(runner: failing)
    assert_raises(Hive::WorkflowPackage::PublishError) { client.send(:run, [ "gh" ]) }
  end

  def test_pull_request_helper_creates_missing_fork_and_renders_warning_evidence
    calls = []
    runner = lambda do |args, chdir:|
      calls << args
      status = args.take(3) == [ "gh", "repo", "view" ] ? Status.new(ok: false) : Status.new(ok: true)
      [ "", "", status ]
    end
    client = Hive::WorkflowPackage::Publisher::RegistryPullRequest.new(runner: runner)

    assert_equal "alice/honeycomb", client.send(:ensure_fork, "alice")
    assert calls.any? { |args| args.take(3) == [ "gh", "repo", "fork" ] }
    body = client.send(:pr_body, sample_package(warnings: [ { "rule_id" => "security.warning", "path" => "workflow.yml" } ]))
    assert_includes body, "security.warning"
  end

  def test_pull_request_helper_rejects_package_and_catalog_version_collisions
    client = Hive::WorkflowPackage::Publisher::RegistryPullRequest.new(runner: runner_for([]))
    with_tmp_dir do |checkout|
      package_dir = File.join(checkout, "workflows", "demo")
      FileUtils.mkdir_p(package_dir)
      manifest = File.join(package_dir, "manifest.json")
      File.write(manifest, JSON.generate("name" => "other", "version" => "0.1.0"))
      assert_raises(Hive::WorkflowPackage::PublishError) do
        client.send(:reject_version_collision!, checkout, sample_package)
      end

      File.write(manifest, JSON.generate("name" => "demo", "version" => "1.2.3"))
      assert_raises(Hive::WorkflowPackage::PublishError) do
        client.send(:reject_version_collision!, checkout, sample_package)
      end

      FileUtils.rm_f(manifest)
      File.write(File.join(checkout, "catalog.json"), JSON.generate(
        "workflows" => { "demo" => { "versions" => { "1.2.3" => {} } } }
      ))
      assert_raises(Hive::WorkflowPackage::PublishError) do
        client.send(:reject_version_collision!, checkout, sample_package)
      end

      File.write(File.join(checkout, "catalog.json"), "{not-json")
      assert_raises(Hive::WorkflowPackage::PublishError) do
        client.send(:reject_version_collision!, checkout, sample_package)
      end
    end
  end

  private

  def sample_package(warnings: [])
    Package.new(name: "demo", version: "1.2.3", root: Dir.pwd,
                manifest_digest: "a" * 64, warnings: warnings)
  end

  def runner_for(results)
    queue = results.dup
    lambda do |_args, chdir:|
      queue.shift || [ "", "", Status.new(ok: true) ]
    end
  end

  def publisher(project)
    Hive::WorkflowPackage::Publisher.new("demo", project_root: project, version: "1.2.3")
  end

  def with_authored_workflow(instruction: "Inspect the task and write a concise result.\n")
    with_tmp_dir do |project|
      workflows = File.join(project, ".hive-state", "workflows")
      authored = File.join(workflows, "demo")
      FileUtils.mkdir_p(authored)
      File.write(File.join(project, ".hive-state", "config.yml"),
                 Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
      File.write(File.join(workflows, "demo.yml"), <<~YAML)
        id: demo
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            instruction: ./demo/work.md
            mapping_role: development
            mapping_contract: demo-work-v1
            permissions: read-only
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      File.write(File.join(authored, "work.md"), instruction)
      File.write(File.join(authored, "README.md"), <<~MARKDOWN)
        # Demo

        ## Behavior
        Produces a concise result.
        ## Prerequisites
        Requires readable task files.
        ## Inputs
        Reads the task brief.
        ## Outputs
        Writes a concise result.
        ## Permissions and Risks
        Uses read-only file access.
        ## Recovery
        Retry from the same immutable inputs.
      MARKDOWN
      File.write(File.join(authored, "honeycomb.yml"), <<~YAML)
        description: Produce a concise result
        author:
          name: Test Author
          url: https://example.test/authors/test
        license: MIT
        hive_min_version: #{Hive::VERSION}
        source:
          url: https://example.test/source/demo
          revision: #{"a" * 40}
        assets: []
      YAML
      yield project, authored
    end
  end
end
