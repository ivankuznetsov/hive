require "test_helper"
require "digest"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/publisher"
require "hive/workflow_package/registry_gateway"

class WorkflowPackageRegistryGatewayTest < Minitest::Test
  include HiveTestHelper

  Status = Data.define(:success?)
  OK = Status.new(success?: true)
  FAILED = Status.new(success?: false)

  def test_verifies_fork_parent_and_owner_from_current_github_evidence
    calls = []
    runner = lambda do |args, chdir:|
      calls << [ args, chdir ]
      body = JSON.generate(
        "nameWithOwner" => "alice/honeycomb",
        "parent" => { "nameWithOwner" => "ivankuznetsov/honeycomb" }
      )
      [ body, "", Status.new(success?: true) ]
    end
    gateway = Hive::WorkflowPackage::RegistryGateway.new(runner: runner)

    assert gateway.verify_fork!(
      "alice/honeycomb", parent: "ivankuznetsov/honeycomb", owner: "alice"
    )
    assert_equal(
      [ "gh", "repo", "view", "alice/honeycomb", "--json", "nameWithOwner,parent" ],
      calls.first.first
    )
    assert_raises(Hive::WorkflowPackage::PublishConflict) do
      gateway.verify_fork!(
        "alice/honeycomb", parent: "other/registry", owner: "alice"
      )
    end
  end

  def test_pull_request_and_commit_parent_are_observed_separately
    runner = lambda do |args, chdir:|
      raise "unexpected chdir" unless chdir.nil?
      body =
        if args.include?("repos/alice/honeycomb/git/commits/#{'a' * 40}")
          JSON.generate("parents" => [ { "sha" => "b" * 40 } ])
        else
          JSON.generate([ {
            "number" => 7,
            "url" => "https://github.com/ivankuznetsov/honeycomb/pull/7",
            "state" => "OPEN", "isDraft" => false, "mergedAt" => nil,
            "headRepository" => { "nameWithOwner" => "alice/honeycomb" },
            "headRefName" => "contribution/demo", "headRefOid" => "a" * 40,
            "baseRefName" => "main", "body" => "metadata"
          } ])
        end
      [ body, "", Status.new(success?: true) ]
    end

    gateway = Hive::WorkflowPackage::RegistryGateway.new(runner: runner)
    pr = gateway.pull_requests("ivankuznetsov/honeycomb").fetch(0)

    assert_equal "contribution/demo", pr.head_branch
    refute pr.draft
    assert_equal "b" * 40, gateway.commit_parent_oid(pr.head_repository, pr.head_oid)
  end

  def test_pull_request_discovery_paginates_all_rest_pages_and_requires_boolean_draft
    calls = []
    rest = lambda do |number, draft: false|
      {
        "number" => number,
        "html_url" => "https://github.com/owner/registry/pull/#{number}",
        "state" => "open", "draft" => draft, "merged_at" => nil, "body" => "",
        "head" => {
          "ref" => "contribution/demo-#{number}", "sha" => "a" * 40,
          "repo" => { "full_name" => "alice/registry" }
        },
        "base" => { "ref" => "main" }
      }
    end
    runner = lambda do |args, chdir:|
      calls << args
      raise "unexpected chdir" unless chdir.nil?
      [ JSON.generate([ [ rest.call(1) ], [ rest.call(101) ] ]), "", OK ]
    end
    prs = Hive::WorkflowPackage::RegistryGateway.new(runner: runner)
                                                .pull_requests("owner/registry")
    assert_equal [ 1, 101 ], prs.map(&:number)
    assert_equal(
      [ "gh", "api", "--paginate", "--slurp",
        "repos/owner/registry/pulls?state=all&per_page=100" ],
      calls.first
    )

    malformed = rest.call(2)
    malformed.delete("draft")
    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      gateway_returning(JSON.generate([ [ malformed ] ])).pull_requests("owner/registry")
    end
  end

  def test_authentication_base_permission_and_branch_observations
    calls = []
    runner = lambda do |args, chdir:|
      calls << [ args, chdir ]
      output =
        case args
        when [ "gh", "auth", "status" ] then ""
        when [ "gh", "api", "user" ] then JSON.generate("login" => "alice")
        when [ "gh", "api", "repos/owner/registry/git/ref/heads/main" ]
          JSON.generate("object" => { "sha" => "a" * 40 })
        when [ "gh", "api", "repos/owner/registry/collaborators/alice/permission" ]
          JSON.generate("permission" => "write")
        when [ "git", "ls-remote", "--heads", "https://github.com/owner/registry.git",
               "refs/heads/contribution/demo" ]
          "#{'b' * 40}\trefs/heads/contribution/demo\n"
        else
          raise "unexpected command: #{args.inspect}"
        end
      [ output, "", OK ]
    end
    gateway = Hive::WorkflowPackage::RegistryGateway.new(runner: runner)

    assert_equal "alice", gateway.authenticate!
    assert_equal "a" * 40, gateway.base_oid("owner/registry", "main")
    assert gateway.direct_permission?("owner/registry", "alice")
    assert_equal "b" * 40, gateway.branch_oid("owner/registry", "contribution/demo")
    assert calls.all? { |_args, chdir| chdir.nil? }
  end

  def test_authentication_and_read_only_observations_fail_closed_on_bad_evidence
    gateway = gateway_returning(JSON.generate("login" => "bad login"))
    assert_raises(Hive::WorkflowPackage::PublishAuthenticationError) { gateway.authenticate! }

    gateway = gateway_returning("", error: "auth failed", status: FAILED)
    assert_raises(Hive::WorkflowPackage::PublishAuthenticationError) { gateway.authenticate! }

    gateway = gateway_returning(JSON.generate("object" => { "sha" => "short" }))
    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      gateway.base_oid("owner/registry", "main")
    end
    assert_raises(Hive::ConfigError) { gateway.base_oid("not-a-repository", "main") }

    gateway = gateway_returning("", error: "HTTP 404 Not Found", status: FAILED)
    refute gateway.direct_permission?("owner/registry", "alice")
    gateway = gateway_returning("", error: "HTTP 503", status: FAILED)
    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      gateway.direct_permission?("owner/registry", "alice")
    end
    gateway = gateway_returning("{not-json")
    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      gateway.direct_permission?("owner/registry", "alice")
    end

    assert_nil gateway_returning("").branch_oid("owner/registry", "topic")
    gateway = gateway_returning("malformed branch evidence\n")
    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      gateway.branch_oid("owner/registry", "topic")
    end
  end

  def test_fork_creation_waits_for_verified_parent_and_has_a_bounded_timeout
    calls = []
    sleeps = []
    views = 0
    runner = lambda do |args, chdir:|
      calls << args
      raise "unexpected chdir" unless chdir.nil?
      if args[0, 3] == [ "gh", "repo", "view" ]
        views += 1
        if views == 1
          [ "", "HTTP 404 Not Found", FAILED ]
        else
          [
            JSON.generate(
              "nameWithOwner" => "alice/honeycomb",
              "parent" => { "nameWithOwner" => "owner/honeycomb" }
            ),
            "",
            OK
          ]
        end
      else
        assert_equal(
          [ "gh", "repo", "fork", "owner/honeycomb", "--clone=false", "--remote=false" ],
          args
        )
        [ "", "", OK ]
      end
    end
    gateway = Hive::WorkflowPackage::RegistryGateway.new(
      runner: runner, sleeper: ->(seconds) { sleeps << seconds }
    )

    assert_equal "alice/honeycomb", gateway.ensure_fork("owner/honeycomb", "alice")
    assert_equal [ 1 ], sleeps
    assert_equal 1, calls.count { |args| args.include?("fork") }

    timeout_gateway = Hive::WorkflowPackage::RegistryGateway.new(
      runner: lambda { |args, chdir:|
        raise "unexpected chdir" unless chdir.nil?
        args.include?("fork") ? [ "", "", OK ] : [ "", "HTTP 404 Not Found", FAILED ]
      },
      sleeper: ->(_seconds) { }
    )
    assert_raises(Hive::WorkflowPackage::PublishAmbiguousError) do
      timeout_gateway.ensure_fork("owner/honeycomb", "alice")
    end
  end

  def test_fork_and_pull_request_evidence_reject_malformed_results
    bad_fork = gateway_returning(
      JSON.generate(
        "nameWithOwner" => "mallory/honeycomb",
        "parent" => { "nameWithOwner" => "owner/honeycomb" }
      )
    )
    assert_raises(Hive::WorkflowPackage::PublishConflict) do
      bad_fork.verify_fork!("alice/honeycomb", parent: "owner/honeycomb", owner: "alice")
    end

    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      gateway_returning(JSON.generate("unexpected" => true)).pull_requests("owner/registry")
    end
    malformed_pr = JSON.generate([ {
      "number" => "seven", "url" => "invalid", "state" => "OPEN",
      "isDraft" => false, "headRepository" => nil
    } ])
    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      gateway_returning(malformed_pr).pull_requests("owner/registry")
    end

    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      gateway_returning("{}").commit_parent_oid("owner/registry", "short")
    end
    gateway = gateway_returning(JSON.generate("parents" => [ { "sha" => "a" * 40 }, { "sha" => "b" * 40 } ]))
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      gateway.commit_parent_oid("owner/registry", "c" * 40)
    end
  end

  def test_version_and_remote_tree_are_bound_to_exact_package_bytes
    with_package do |package|
      manifest_bytes = File.binread(File.join(package.root, "manifest.yml"))
      runner = package_observation_runner(package, manifest_bytes)
      gateway = Hive::WorkflowPackage::RegistryGateway.new(runner: runner)

      assert_equal(
        { package_digest: package.package_digest, release_digest: package.release_digest },
        gateway.version_present?("owner/registry", "main", package)
      )
      assert gateway.verify_remote_package!("owner/registry", "topic", package)
      correct_tree = JSON.parse(
        package_observation_runner(package, manifest_bytes).call(
          [ "gh", "api", "repos/owner/registry/git/trees/topic?recursive=1" ],
          chdir: nil
        ).first
      )
      changed_sha = Marshal.load(Marshal.dump(correct_tree))
      changed_sha.fetch("tree").first["sha"] = "f" * 40
      assert_raises(Hive::WorkflowPackage::PublishConflict) do
        Hive::WorkflowPackage::RegistryGateway.new(
          runner: package_observation_runner(package, manifest_bytes, tree: changed_sha)
        ).verify_remote_package!("owner/registry", "topic", package)
      end
      changed_mode = Marshal.load(Marshal.dump(correct_tree))
      changed_mode.fetch("tree").first["mode"] =
        changed_mode.fetch("tree").first.fetch("mode") == "100644" ? "100755" : "100644"
      assert_raises(Hive::WorkflowPackage::PublishConflict) do
        Hive::WorkflowPackage::RegistryGateway.new(
          runner: package_observation_runner(package, manifest_bytes, tree: changed_mode)
        ).verify_remote_package!("owner/registry", "topic", package)
      end
      assert_raises(Hive::WorkflowPackage::PublishConflict) do
        gateway.verify_remote_package!(
          "owner/registry", "topic", package.with(package_digest: "f" * 64)
        )
      end

      absent = gateway_returning("", error: "HTTP 404 Not Found", status: FAILED)
      assert_nil absent.version_present?("owner/registry", "main", package)

      malformed = gateway_returning("--- []\n")
      assert_raises(Hive::WorkflowPackage::PublishConflict) do
        malformed.version_present?("owner/registry", "main", package)
      end

      unavailable = gateway_returning("", error: "HTTP 503", status: FAILED)
      assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
        unavailable.version_present?("owner/registry", "main", package)
      end
    end
  end

  def test_remote_tree_rejects_incomplete_special_and_mismatched_inventory
    with_package do |package|
      manifest_bytes = File.binread(File.join(package.root, "manifest.yml"))
      [
        [
          { "tree" => [], "truncated" => true },
          Hive::WorkflowPackage::PublishOfflineError
        ],
        [
          {
            "tree" => [
              {
                "path" => "#{package.registry_path}/manifest.yml",
                "type" => "commit", "mode" => "160000"
              }
            ],
            "truncated" => false
          },
          Hive::WorkflowPackage::PublishConflict
        ],
        [
          {
            "tree" => [
              {
                "path" => "#{package.registry_path}/manifest.yml",
                "type" => "blob", "mode" => "100644"
              }
            ],
            "truncated" => false
          },
          Hive::WorkflowPackage::PublishConflict
        ]
      ].each do |tree, expected|
        runner = package_observation_runner(package, manifest_bytes, tree: tree)
        assert_raises(expected) do
          Hive::WorkflowPackage::RegistryGateway.new(runner: runner)
                                                .verify_remote_package!("owner/registry", "topic", package)
        end
      end
    end
  end

  def test_prepare_commit_retains_and_reuses_one_exact_commit
    with_package do |package|
      with_tmp_dir do |objects_root|
        base_oid = "a" * 40
        commit_oid = "b" * 40
        branch = "contribution/demo"
        runner, calls = commit_runner(base_oid: base_oid, commit_oid: commit_oid)
        gateway = Hive::WorkflowPackage::RegistryGateway.new(
          runner: runner, objects_root: objects_root
        )

        checkout, oid = gateway.prepare_commit(
          package, repository: "owner/registry", base_branch: "main", base_oid: base_oid,
          head_repository: "alice/registry", branch: branch
        )
        assert_equal commit_oid, oid
        assert File.file?(File.join(checkout, package.registry_path, "manifest.yml"))
        assert_equal 0o700, File.stat(checkout).mode & 0o777

        retained_checkout, retained_oid = gateway.prepare_commit(
          package, repository: "owner/registry", base_branch: "main", base_oid: base_oid,
          head_repository: "alice/registry", branch: branch
        )
        assert_equal [ checkout, commit_oid ], [ retained_checkout, retained_oid ]
        assert_equal 1, calls.count { |args| args[0, 2] == [ "git", "clone" ] }
        set_urls = calls.select { |args| args.include?("set-url") }
        assert_operator set_urls.length, :>=, 2
        assert set_urls.all? { |args| args.last == "https://github.com/alice/registry.git" }

        File.write(File.join(checkout, package.registry_path, "README.md"), "tampered\n")
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          gateway.prepare_commit(
            package, repository: "owner/registry", base_branch: "main", base_oid: base_oid,
            head_repository: "alice/registry", branch: branch
          )
        end
      end
    end
  end

  def test_prepare_commit_rejects_inconsistent_or_unsafe_recovery_state
    with_package do |package|
      with_tmp_dir do |target|
        FileUtils.mkdir_p(File.join(target, "objects"))
        objects_root = File.join(target, "objects-link")
        File.symlink(File.join(target, "objects"), objects_root)
        gateway = Hive::WorkflowPackage::RegistryGateway.new(
          runner: ->(_args, chdir:) { raise "unexpected runner call in #{chdir}" },
          objects_root: objects_root
        )
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          prepare_commit(gateway, package)
        end
      end

      with_tmp_dir do |objects_root|
        File.chmod(0o755, objects_root)
        gateway = Hive::WorkflowPackage::RegistryGateway.new(
          runner: ->(_args, chdir:) { raise "unexpected runner call in #{chdir}" },
          objects_root: objects_root
        )
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          prepare_commit(gateway, package)
        end
      ensure
        File.chmod(0o700, objects_root) if objects_root && File.directory?(objects_root)
      end

      with_tmp_dir do |objects_root|
        real_checkout = File.join(objects_root, "elsewhere")
        FileUtils.mkdir_p(File.join(real_checkout, ".git"))
        File.symlink(real_checkout, File.join(objects_root, commit_key(package)))
        gateway = Hive::WorkflowPackage::RegistryGateway.new(
          runner: ->(_args, chdir:) { raise "unexpected runner call in #{chdir}" },
          objects_root: objects_root
        )
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          prepare_commit(gateway, package)
        end
      end

      with_tmp_dir do |objects_root|
        checkout = File.join(objects_root, commit_key(package))
        external_git_dir = File.join(objects_root, "external-git")
        FileUtils.mkdir_p(checkout)
        FileUtils.mkdir_p(external_git_dir)
        File.symlink(external_git_dir, File.join(checkout, ".git"))
        gateway = Hive::WorkflowPackage::RegistryGateway.new(
          runner: ->(_args, chdir:) { raise "unexpected runner call in #{chdir}" },
          objects_root: objects_root
        )
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          prepare_commit(gateway, package)
        end
      end

      with_tmp_dir do |objects_root|
        key = commit_key(package)
        File.write(File.join(objects_root, key), "not a repository")
        gateway = Hive::WorkflowPackage::RegistryGateway.new(
          runner: ->(_args, chdir:) { raise "unexpected runner call in #{chdir}" },
          objects_root: objects_root
        )
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          prepare_commit(gateway, package)
        end
      end

      with_tmp_dir do |objects_root|
        FileUtils.mkdir_p(File.join(objects_root, commit_key(package), ".git"))
        runner, = commit_runner
        gateway = Hive::WorkflowPackage::RegistryGateway.new(
          runner: runner, objects_root: objects_root
        )
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          prepare_commit(gateway, package)
        end
      end

      [
        { actual_base: "c" * 40, error: Hive::WorkflowPackage::PublishRecoveryError },
        { seed_target: true, error: Hive::WorkflowPackage::PublishConflict },
        { status_output: "A  README.md\n", error: Hive::WorkflowPackage::PublishRecoveryError },
        { commit_oid: "invalid", error: Hive::WorkflowPackage::PublishRecoveryError }
      ].each do |options|
        with_tmp_dir do |objects_root|
          runner, = commit_runner(**options.except(:error))
          gateway = Hive::WorkflowPackage::RegistryGateway.new(
            runner: runner, objects_root: objects_root
          )
          assert_raises(options.fetch(:error)) { prepare_commit(gateway, package) }
        end
      end

      with_tmp_dir do |parent|
        objects_root = File.join(parent, "objects")
        runner, = commit_runner
        gateway = Hive::WorkflowPackage::RegistryGateway.new(
          runner: runner, objects_root: objects_root
        )
        with_replaced_singleton_method(
          FileUtils, :mkdir_p, ->(*_args, **_kwargs) { raise Errno::EACCES, "denied" }
        ) do
          error = assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
            prepare_commit(gateway, package)
          end
          assert_match(/could not be retained: Errno::EACCES/, error.message)
        end
      end
    end
  end

  def test_push_and_pull_request_mutations_are_bounded_and_non_draft
    with_package do |package|
      calls = []
      body = nil
      runner = lambda do |args, chdir:|
        calls << [ args, chdir ]
        if args[0, 3] == [ "gh", "pr", "create" ]
          body_path = args.fetch(args.index("--body-file") + 1)
          body = File.read(body_path)
          [ "created\nhttps://github.com/owner/registry/pull/9\n", "", OK ]
        else
          [ "", "", OK ]
        end
      end
      gateway = Hive::WorkflowPackage::RegistryGateway.new(runner: runner)

      assert gateway.push_expected_absent("/checkout", "contribution/demo", "a" * 40)
      push = calls.map(&:first).find { |args| args.include?("push") }
      assert_includes push, "--force-with-lease=refs/heads/contribution/demo:"
      assert_equal(
        "https://github.com/owner/registry/pull/9",
        gateway.create_pull_request(
          repository: "owner/registry", base_branch: "main",
          head_repository: "alice/registry", branch: "contribution/demo", package: package
        )
      )
      assert_includes body, package.release_digest
      refute calls.flatten.include?("--force")
      refute calls.flatten.include?("--draft")

      failed_push = gateway_returning("", error: "lost response", status: FAILED)
      assert_raises(Hive::WorkflowPackage::PublishAmbiguousError) do
        failed_push.push_expected_absent("/checkout", "topic", "a" * 40)
      end
      missing_url = gateway_returning("pull request created without a URL")
      assert_raises(Hive::WorkflowPackage::PublishAmbiguousError) do
        missing_url.create_pull_request(
          repository: "owner/registry", base_branch: "main",
          head_repository: "alice/registry", branch: "topic", package: package
        )
      end
    end
  end

  def test_transport_and_json_failures_are_redacted
    invalid_json = gateway_returning("{not-json")
    assert_raises(Hive::WorkflowPackage::PublishAuthenticationError) { invalid_json.authenticate! }

    unavailable = Hive::WorkflowPackage::RegistryGateway.new(
      runner: ->(_args, chdir:) { raise IOError, "socket secret in #{chdir.inspect}" }
    )
    error = assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      unavailable.base_oid("owner/registry", "main")
    end
    assert_equal "registry transport is unavailable", error.message

    lookup_failed = gateway_returning("", error: "HTTP 500", status: FAILED)
    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      lookup_failed.ensure_fork("owner/registry", "alice")
    end
    malformed_lookup = gateway_returning("{not-json")
    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      malformed_lookup.ensure_fork("owner/registry", "alice")
    end
  end

  private

  def gateway_returning(output, error: "", status: OK)
    Hive::WorkflowPackage::RegistryGateway.new(
      runner: ->(_args, chdir:) { raise "unexpected chdir" unless chdir.nil?; [ output, error, status ] },
      sleeper: ->(_seconds) { }
    )
  end

  def package_observation_runner(package, manifest_bytes, tree: nil)
    tree ||= {
      "tree" => Hive::WorkflowPackage::Manifest.inventory(
        package.root, exclude: [], require_utf8: false
      ).map { |entry| entry.fetch("path") }.map do |relative|
        bytes = File.binread(File.join(package.root, relative))
        {
          "path" => "#{package.registry_path}/#{relative}",
          "type" => "blob",
          "mode" => File.executable?(File.join(package.root, relative)) ? "100755" : "100644",
          "sha" => Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0#{bytes}")
        }
      end,
      "truncated" => false
    }
    lambda do |args, chdir:|
      raise "unexpected chdir" unless chdir.nil?
      if args.include?("Accept: application/vnd.github.raw+json")
        [ manifest_bytes, "", OK ]
      elsif args.any? { |arg| arg.include?("/git/trees/") }
        [ JSON.generate(tree), "", OK ]
      else
        raise "unexpected package observation command: #{args.inspect}"
      end
    end
  end

  def commit_runner(base_oid: "a" * 40, actual_base: nil, commit_oid: "b" * 40,
                    status_output: nil, seed_target: false)
    actual_base ||= base_oid
    status_output ||= "A  packages/demo/1.0.0/manifest.yml\n"
    committed = false
    calls = []
    runner = lambda do |args, chdir:|
      raise "unexpected chdir" unless chdir.nil?
      calls << args
      if args[0, 2] == [ "git", "clone" ]
        checkout = args.last
        FileUtils.mkdir_p(File.join(checkout, ".git"))
        FileUtils.mkdir_p(File.join(checkout, "packages", "demo", "1.0.0")) if seed_target
      elsif args.include?("commit")
        committed = true
      end

      output =
        if args.include?("status")
          status_output
        elsif args.include?("diff-tree")
          commit_tree_paths(args.fetch(2))
        elsif args.include?("ls-tree")
          commit_tree_lines(args.fetch(2))
        elsif args.include?("rev-parse")
          ref = args.last
          if ref == "HEAD"
            committed ? commit_oid : actual_base
          elsif ref.end_with?("^")
            base_oid
          else
            commit_oid
          end
        else
          ""
        end
      [ "#{output}\n", "", OK ]
    end
    [ runner, calls ]
  end

  def commit_tree_paths(checkout)
    root = File.join(checkout, "packages", "demo", "1.0.0")
    return "" unless File.directory?(root)
    Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }.sort.map do |path|
      path.delete_prefix("#{checkout}/")
    end.join("\n")
  end

  def commit_tree_lines(checkout)
    root = File.join(checkout, "packages", "demo", "1.0.0")
    return "" unless File.directory?(root)
    Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }.sort.map do |path|
      bytes = File.binread(path)
      mode = File.executable?(path) ? "100755" : "100644"
      relative = path.delete_prefix("#{checkout}/")
      "#{mode} blob #{Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0#{bytes}")}\t#{relative}"
    end.join("\n")
  end

  def prepare_commit(gateway, package)
    gateway.prepare_commit(
      package, repository: "owner/registry", base_branch: "main", base_oid: "a" * 40,
      head_repository: "alice/registry", branch: "contribution/demo"
    )
  end

  def commit_key(package)
    Digest::SHA256.hexdigest(
      [ "owner/registry", package.name, package.version, package.release_digest ].join("\0")
    )
  end

  def with_package
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "instructions"))
      File.write(File.join(root, "README.md"), "# Demo\n")
      File.write(File.join(root, "instructions", "work.md"), "Read files only.\n")
      File.write(File.join(root, "workflow.yml"), <<~YAML)
        id: demo
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            instruction: instructions/work.md
            mapping_role: development
            mapping_contract: demo-work-v1
            permissions: read-only
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      manifest = package_manifest(root)
      manifest["release_sha256"] = Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalYAML.dump_manifest(manifest, include_release: false)
      )
      File.binwrite(
        File.join(root, "manifest.yml"),
        Hive::WorkflowPackage::CanonicalYAML.dump_manifest(manifest)
      )
      package = Hive::WorkflowPackage::Publisher::Package.new(
        name: "demo", version: "1.0.0", root: root,
        package_digest: Digest::SHA256.file(File.join(root, "manifest.yml")).hexdigest,
        release_digest: manifest.fetch("release_sha256"), warnings: [], findings: [],
        lint_contract: {
          "version" => "v1", "upstream_commit" => "a" * 40,
          "upstream_policy_sha256" => "b" * 64, "fixture_corpus_sha256" => "c" * 64,
          "expected_output_sha256" => "d" * 64, "contract_sha256" => "e" * 64
        }
      )
      yield package
    end
  end

  def package_manifest(root)
    prefix = "packages/demo/1.0.0/"
    files = %w[README.md instructions/work.md workflow.yml].to_h do |relative|
      [ "#{prefix}#{relative}", Digest::SHA256.file(File.join(root, relative)).hexdigest ]
    end
    {
      "schema" => "honeycomb-manifest/v1", "name" => "demo", "version" => "1.0.0",
      "description" => "Demo",
      "author" => { "name" => "Test", "url" => "https://example.test/test" },
      "license" => "MIT", "hive_min_version" => "0.4.3",
      "source" => { "url" => "https://example.test/source", "revision" => "c" * 40 },
      "permissions" => {
        "risk" => "low", "capabilities" => [ "filesystem-read" ],
        "network_hosts" => [], "filesystem_read" => [ "repository", "task" ],
        "filesystem_write" => [], "secrets" => []
      },
      "files" => files,
      "x-hive" => { "external_skills" => [], "optional_inputs" => [], "tools" => [] }
    }
  end
end
