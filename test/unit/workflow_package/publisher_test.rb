require "test_helper"
require "hive/workflow_package/publisher"

class WorkflowPackagePublisherTest < Minitest::Test
  include HiveTestHelper

  Package = Hive::WorkflowPackage::Publisher::Package
  Status = Data.define(:ok) do
    def success? = ok
  end

  def test_packages_only_descriptor_referenced_instructions_readme_and_metadata_deterministically
    with_authored_workflow do |project, authored_dir|
      File.write(File.join(authored_dir, "ignored.txt"), "do not publish\n")
      manifests = 2.times.map do
        Dir.mktmpdir("publisher-test-") do |destination|
          package = publisher(project).package(destination: destination)
          assert_equal %w[README.md honeycomb.yml instructions/work.md manifest.json workflow.yml],
                       Dir.glob(File.join(destination, "**", "*"), File::FNM_DOTMATCH)
                          .select { |path| File.file?(path) }
                          .map { |path| path.delete_prefix("#{destination}/") }.sort
          assert_includes File.read(File.join(destination, "workflow.yml")), "instructions/work.md"
          File.binread(File.join(destination, "manifest.json"))
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

  private

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
            permissions: read-only
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      File.write(File.join(authored, "work.md"), instruction)
      File.write(File.join(authored, "README.md"), "# Demo\n\nA concise workflow.\n")
      File.write(File.join(authored, "honeycomb.yml"), <<~YAML)
        summary: Produce a concise result
        author:
          name: Test Author
        dependencies: {}
        permissions:
          tools:
            - Read
          deny:
            - Bash
          directories: []
          commands: []
          domains: []
          credentials: []
      YAML
      yield project, authored
    end
  end
end
