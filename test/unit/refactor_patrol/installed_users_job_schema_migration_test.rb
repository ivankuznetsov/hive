require "test_helper"
require "json_schemer"
require "hive/refactor_patrol/installed_users_job_schema_migration"

class HiveRefactorPatrolInstalledUsersJobSchemaMigrationTest < Minitest::Test
  include HiveTestHelper

  Migration = Hive::RefactorPatrol::InstalledUsersJobSchemaMigration
  IDENTITY_OK = ->(_profile) { true }

  class Catalog
    def initialize(snapshot)
      @snapshot = snapshot
    end

    def snapshot
      @snapshot
    end
  end

  class Executor
    attr_reader :calls

    def initialize(&block)
      @block = block
      @calls = []
    end

    def call(profile)
      @calls << profile
      @block.call(profile)
    end
  end

  # Catalog ownership tests use synthetic UIDs while their temporary
  # directories necessarily belong to the test process. Preserve production
  # path-identity semantics without weakening the production ownership check.
  class CurrentUserRootBindings
    def initialize
      @delegate = Migration::ProfileRootBindings.new
    end

    def bind(home:, environment:, uid:)
      @delegate.bind(
        home: home, environment: environment, uid: Process.uid
      )
    end

    def key(binding)
      @delegate.key(binding)
    end
  end

  FakeStat = Data.define(:dev, :ino, :uid, :gid, :mode, :size) do
    def file? = true
  end

  def test_one_install_wide_call_attempts_every_discovered_user_and_isolates_failure
    with_tmp_dir do |root|
      profiles = %w[alice bob carol].map.with_index do |name, index|
        home = File.join(root, name)
        FileUtils.mkdir_p(home)
        profile(
          name, index + 1_001, home,
          environment:
            index == 2 ? { "HIVE_HOME" => File.join(home, "hive") } : {}
        )
      end
      executor = Executor.new do |candidate|
        raise Errno::EACCES, "unreadable registry" if candidate.username == "bob"

        installation_payload(
          candidate.username,
          retryable: candidate.username == "carol",
          profile: candidate
        )
      end
      migration = Migration.new(
        catalog: Catalog.new(snapshot(profiles, closed: true)),
        executor: executor,
        candidate: candidate_identity,
        effective_uid: -> { 0 }
      )

      payload = migration.call(now: Time.utc(2026, 7, 29, 20))

      assert_equal "failed", payload.fetch("status")
      assert payload.fetch("discovery_closed")
      assert_equal 3, payload.fetch("attempted_users")
      assert_equal 1, payload.fetch("failed_users")
      assert_equal 2, payload.fetch("retryable_users")
      assert_equal 3, payload.fetch("attempted_profiles")
      assert_equal 1, payload.fetch("failed_profiles")
      assert_equal 2, payload.fetch("retryable_profiles")
      assert_equal %w[alice bob carol],
                   executor.calls.map(&:username)
      assert_equal %w[completed failed completed],
                   payload.fetch("profiles").map { |row| row.fetch("status") }
      assert_equal(
        [ "job-alice", "job-carol" ],
        payload.fetch("profiles").flat_map do |row|
          row.fetch("projects").map { |project| project.fetch("project") }
        end
      )
      assert_empty schema_errors(
        "hive-installed-users-job-schema-migration.v1.json", payload
      )
      assert_equal File.stat(
        File.expand_path("../../../bin/hive", __dir__)
      ).uid, payload.dig("candidate", "uid")
    end
  end

  def test_successful_known_profiles_remain_partial_until_operator_closes_discovery
    with_tmp_dir do |root|
      candidate = profile("alice", 1_001, root)
      issue = Migration::DiscoveryIssue.new(
        kind: "unindexed_legacy_profiles_unverifiable",
        username: nil,
        uid: nil,
        detail: "arbitrary legacy HIVE_HOME roots cannot be inferred"
      )
      executor = Executor.new do |profile|
        installation_payload("alice", profile: profile)
      end
      migration = Migration.new(
        catalog: Catalog.new(
          Migration::Snapshot.new(
            profiles: [ candidate ],
            issues: [ issue ],
            closed: false,
            inventory_path: "/var/lib/hive/installed-users.v1.json",
            inventory_digest: nil
          )
        ),
        executor: executor,
        candidate: candidate_identity,
        effective_uid: -> { 0 }
      )

      payload = migration.call(now: Time.utc(2026, 7, 29, 20))

      assert_equal "partial", payload.fetch("status")
      refute payload.fetch("discovery_closed")
      assert_equal "unindexed_legacy_profiles_unverifiable",
                   payload.fetch("discovery_issues").first.fetch("kind")
    end
  end

  def test_install_wide_boundary_requires_root_even_with_no_profiles
    migration = Migration.new(
      catalog: Catalog.new(snapshot([], closed: true)),
      executor: Executor.new { flunk("no profile should execute") },
      candidate: candidate_identity,
      effective_uid: -> { 1_001 }
    )

    error = assert_raises(Hive::ConfigError) { migration.call }

    assert_match(/requires root authority/, error.message)
  end

  def test_default_process_identity_probes_are_live
    migration = Migration.new(
      catalog: Catalog.new(snapshot([], closed: true)),
      executor: Executor.new { flunk("no profile should execute") },
      candidate: candidate_identity
    )
    assert_equal Process.euid,
                 migration.instance_variable_get(:@effective_uid).call

    executor = Migration::Executor.new(
      binary: File.expand_path("../../../bin/hive", __dir__),
      runner: ->(*) { flunk("runner should not execute") }
    )
    assert_equal Process.euid,
                 executor.instance_variable_get(:@effective_uid).call

    drop = Migration::IdentityDrop.new
    assert_equal Process.euid,
                 drop.instance_variable_get(:@effective_uid).call
    assert_equal Process.egid,
                 drop.instance_variable_get(:@effective_gid).call
    assert_equal Process.groups,
                 drop.instance_variable_get(:@groups).call
  end

  def test_default_candidate_is_captured_and_unavailable_binary_is_rejected
    migration = Migration.new(
      catalog: Catalog.new(snapshot([], closed: true)),
      binary_path: -> { File.expand_path("../../../bin/hive", __dir__) },
      effective_uid: -> { 0 }
    )

    payload = migration.call

    assert_equal File.size(
      File.expand_path("../../../bin/hive", __dir__)
    ), payload.dig("candidate", "size")
    assert_operator payload.dig("candidate", "mode"), :>, 0
    assert payload.dig("candidate", "sha256").match?(/\A[0-9a-f]{64}\z/)

    unavailable = Migration.new(
      catalog: Catalog.new(snapshot([], closed: true)),
      binary_path: -> { nil },
      effective_uid: -> { 0 }
    )
    error = assert_raises(Hive::UnavailableError) { unavailable.call }
    assert_match(/candidate binary is unavailable/, error.message)
  end

  def test_install_wide_boundary_rejects_malformed_time
    migration = Migration.new(
      catalog: Catalog.new(snapshot([], closed: true)),
      executor: Executor.new { flunk("no profile should execute") },
      candidate: candidate_identity,
      effective_uid: -> { 0 }
    )

    error = assert_raises(Hive::ConfigError) do
      migration.call(now: "not-a-time")
    end

    assert_match(/time is malformed/, error.message)
  end

  def test_closed_discovery_with_retryable_project_is_not_complete
    with_tmp_dir do |home|
      candidate = profile("alice", 1_001, home)
      migration = Migration.new(
        catalog: Catalog.new(snapshot([ candidate ], closed: true)),
        executor: Executor.new do |profile|
          installation_payload("alice", retryable: true, profile: profile)
        end,
        candidate: candidate_identity,
        effective_uid: -> { 0 }
      )

      payload = migration.call(now: Time.utc(2026, 7, 29, 20))

      assert_equal "partial", payload.fetch("status")
      assert_equal 0, payload.fetch("failed_users")
      assert_equal 1, payload.fetch("retryable_users")
      assert_equal 0, payload.fetch("failed_profiles")
      assert_equal 1, payload.fetch("retryable_profiles")
    end
  end

  def test_profile_errors_remain_bounded_valid_utf8
    with_tmp_dir do |home|
      candidate = profile("alice", 1_001, home)
      migration = Migration.new(
        catalog: Catalog.new(snapshot([ candidate ], closed: true)),
        executor: Executor.new { raise Hive::Error, "é" * 2_000 },
        candidate: candidate_identity,
        effective_uid: -> { 0 }
      )

      payload = migration.call(now: Time.utc(2026, 7, 29, 20))
      error = payload.dig("profiles", 0, "error")

      assert error.valid_encoding?
      assert_operator error.bytesize, :<=, Migration::MAX_ERROR_BYTES
      JSON.generate(payload)
    end
  end

  def test_user_and_profile_counts_remain_distinct_for_multiple_hive_roots
    with_tmp_dir do |home|
      default = profile("alice", 1_001, home)
      custom = profile(
        "alice", 1_001, home,
        environment: { "HIVE_HOME" => File.join(home, "custom") }
      )
      FileUtils.mkdir_p(custom.environment.fetch("HIVE_HOME"))
      migration = Migration.new(
        catalog: Catalog.new(snapshot([ default, custom ], closed: true)),
        executor: Executor.new do |profile|
          installation_payload(profile.source, profile: profile)
        end,
        candidate: candidate_identity,
        effective_uid: -> { 0 }
      )

      payload = migration.call(now: Time.utc(2026, 7, 29, 20))

      assert_equal "complete", payload.fetch("status")
      assert_equal 1, payload.fetch("attempted_users")
      assert_equal 2, payload.fetch("attempted_profiles")
      assert_equal 2, payload.fetch("profiles").length
    end
  end

  def test_catalog_discovers_every_default_or_legacy_hive_home_and_exact_inventory_profile
    with_tmp_dir do |root|
      accounts = %w[alice bob carol unrelated].map.with_index do |name, index|
        home = File.join(root, name)
        FileUtils.mkdir_p(home)
        {
          name: name,
          uid: 1_001 + index,
          gid: 2_001 + index,
          dir: home
        }
      end
      FileUtils.mkdir_p(File.join(root, "alice", ".config", "hive"))
      File.write(
        File.join(root, "alice", ".config", "hive", "config.yml"),
        "registered_projects: []\n"
      )
      FileUtils.mkdir_p(File.join(root, "bob", ".hive-state"))
      File.write(
        File.join(root, "bob", ".hive-state", "registry.yml"),
        "registered_projects: []\n"
      )
      custom = File.join(root, "carol", "custom-hive")
      FileUtils.mkdir_p(custom)
      inventory = Object.new
      inventory.define_singleton_method(:read) do
        Migration::Inventory::Result.new(
          profiles: [ {
            username: "carol",
            uid: 1_003,
            home: File.join(root, "carol"),
            environment: { "HIVE_HOME" => custom }
          } ],
          issues: [],
          closed: true,
          path: "/var/lib/hive/installed-users.v1.json",
          digest: "a" * 64
        )
      end
      catalog = migration_catalog(
        accounts: -> { accounts },
        inventory: inventory
      )

      result = catalog.snapshot

      assert result.closed
      assert_empty result.issues
      assert_equal %w[alice bob carol],
                   result.profiles.map(&:username)
      assert_equal(
        [ "default-home", "default-home", "root-inventory" ],
        result.profiles.map(&:source)
      )
      assert_equal({ "HIVE_HOME" => custom },
                   result.profiles.last.environment)
    end
  end

  def test_catalog_default_nss_source_enumerates_passwd_records
    homes = []
    inventory = Object.new
    inventory.define_singleton_method(:read) do
      Migration::Inventory::Result.new(
        profiles: [],
        issues: [],
        closed: false,
        path: "/var/lib/hive/installed-users.v1.json",
        digest: nil
      )
    end
    catalog = migration_catalog(
      inventory: inventory,
      probe: Migration::Catalog::PathProbe.new(
        lstat: ->(path) {
          homes << path
          raise Errno::ENOENT, path
        }
      )
    )

    result = catalog.snapshot

    assert_empty result.profiles
    assert_includes homes, Etc.getpwuid(Process.uid).dir
  end

  def test_path_probe_distinguishes_missing_from_unsafe_or_unavailable
    with_tmp_dir do |root|
      directory = File.join(root, "directory")
      link = File.join(root, "link")
      fifo = File.join(root, "fifo")
      FileUtils.mkdir_p(directory)
      File.symlink(directory, link)
      File.mkfifo(fifo)
      probe = Migration::Catalog::PathProbe.new

      assert_equal :present, probe.directory(directory).state
      assert_equal :missing,
                   probe.directory(File.join(root, "missing")).state
      assert_equal :unavailable, probe.directory(link).state
      assert_match(/unsafe link/, probe.directory(link).detail)
      assert_equal :unavailable, probe.regular_file(fifo).state
      assert_match(/unsafe fifo/, probe.regular_file(fifo).detail)

      unavailable = Migration::Catalog::PathProbe.new(
        lstat: ->(_path) { raise Errno::EACCES, "offline home" }
      ).directory(directory)
      assert_equal :unavailable, unavailable.state
      assert_match(/EACCES/, unavailable.detail)
    end
  end

  def test_bounded_nss_query_times_out_and_catalog_stays_partial
    query = Migration::NssQuery.new(
      timeout_sec: 0.05,
      snapshot_script: "sleep 5"
    )
    error = assert_raises(Hive::ConfigError) { query.snapshot }
    assert_match(/exceeded/, error.message)

    inventory = Object.new
    inventory.define_singleton_method(:read) do
      Migration::Inventory::Result.new(
        profiles: [],
        issues: [],
        closed: true,
        path: "/var/lib/hive/installed-users.v1.json",
        digest: "a" * 64
      )
    end
    catalog = migration_catalog(
      accounts: -> { raise Hive::ConfigError, "NSS offline" },
      inventory: inventory
    )

    result = catalog.snapshot

    assert_empty result.profiles
    assert_equal "nss_catalog_unavailable", result.issues.first.kind
    assert result.closed,
           "inventory closure is retained but issues keep aggregate partial"
  end

  def test_inventory_accepts_only_stable_root_owned_exact_profiles
    bytes = JSON.generate(
      "schema" => "hive-installed-user-inventory",
      "schema_version" => 1,
      "discovery_closed" => true,
      "profiles" => [ {
        "username" => "alice",
        "uid" => 1_001,
        "home" => "/home/alice",
        "environment" => {
          "HIVE_HOME" => "/srv/hive/alice"
        }
      } ]
    )
    stat = FakeStat.new(
      dev: 1, ino: 2, uid: 0, gid: 0, mode: 0o100600,
      size: bytes.bytesize
    )
    inventory = Migration::Inventory.new(
      path: "/var/lib/hive/installed-users.v1.json",
      stat: ->(_path) { stat },
      reader: ->(_path) { bytes }
    )

    result = inventory.read

    assert result.closed
    assert_equal 1, result.profiles.length
    assert_equal "/srv/hive/alice",
                 result.profiles.first.dig(:environment, "HIVE_HOME")
    assert_empty schema_errors(
      "hive-installed-user-inventory.v1.json", JSON.parse(bytes)
    )
  end

  def test_inventory_rejects_writable_or_replaced_root_manifest
    bytes = JSON.generate(
      "schema" => "hive-installed-user-inventory",
      "schema_version" => 1,
      "discovery_closed" => false,
      "profiles" => []
    )
    writable = FakeStat.new(
      dev: 1, ino: 2, uid: 0, gid: 0, mode: 0o100622,
      size: bytes.bytesize
    )
    inventory = Migration::Inventory.new(
      stat: ->(_path) { writable },
      reader: ->(_path) { bytes }
    )
    assert_raises(Hive::ConfigError) { inventory.read }

    calls = 0
    replaced = Migration::Inventory.new(
      stat: lambda do |_path|
        calls += 1
        FakeStat.new(
          dev: 1, ino: calls, uid: 0, gid: 0, mode: 0o100600,
          size: bytes.bytesize
        )
      end,
      reader: ->(_path) { bytes }
    )
    error = assert_raises(Hive::ConfigError) { replaced.read }
    assert_match(/changed while it was read/, error.message)
  end

  def test_inventory_secure_reader_accepts_trusted_owner_and_missing_file
    with_tmp_dir do |root|
      path = File.join(root, "installed-users.v1.json")
      bytes = JSON.generate(
        "schema" => "hive-installed-user-inventory",
        "schema_version" => 1,
        "discovery_closed" => true,
        "profiles" => []
      )
      File.write(path, bytes)
      FileUtils.chmod(0o700, root)
      FileUtils.chmod(0o600, path)
      inventory = Migration::Inventory.new(
        path: path,
        trusted_uid: Process.uid
      )

      result = inventory.read

      assert result.closed
      assert_equal Digest::SHA256.hexdigest(bytes), result.digest

      missing = Migration::Inventory.new(
        path: File.join(root, "missing.json"),
        trusted_uid: Process.uid
      ).read
      refute missing.closed
      assert_nil missing.digest
      assert_empty missing.profiles
    end
  end

  def test_inventory_rejects_bad_constructor_and_document_inputs
    assert_raises(ArgumentError) do
      Migration::Inventory.new(path: "relative.json")
    end
    assert_raises(ArgumentError) do
      Migration::Inventory.new(stat: ->(*) { }, reader: nil)
    end
    assert_raises(ArgumentError) do
      Migration::Inventory.new(trusted_uid: -1)
    end

    malformed_json = Migration::Inventory.new(
      stat: ->(*) {
        FakeStat.new(
          dev: 1, ino: 2, uid: 0, gid: 0, mode: 0o100600, size: 1
        )
      },
      reader: ->(*) { "{" }
    )
    assert_raises(Hive::ConfigError) { malformed_json.read }

    malformed_document = inventory_for_document(
      "schema" => "wrong",
      "schema_version" => 1,
      "discovery_closed" => false,
      "profiles" => []
    )
    assert_raises(Hive::ConfigError) { malformed_document.read }

    duplicate = {
      "username" => "alice",
      "uid" => 1_001,
      "home" => "/home/alice",
      "environment" => {}
    }
    duplicate_inventory = inventory_for_document(
      "schema" => "hive-installed-user-inventory",
      "schema_version" => 1,
      "discovery_closed" => false,
      "profiles" => [ duplicate, duplicate ]
    )
    assert_raises(Hive::ConfigError) { duplicate_inventory.read }

    bad_environment = duplicate.merge(
      "environment" => { "HIVE_HOME" => "relative" }
    )
    bad_profile = inventory_for_document(
      "schema" => "hive-installed-user-inventory",
      "schema_version" => 1,
      "discovery_closed" => false,
      "profiles" => [ bad_environment ]
    )
    assert_raises(Hive::ConfigError) { bad_profile.read }

    malformed_profile = inventory_for_document(
      "schema" => "hive-installed-user-inventory",
      "schema_version" => 1,
      "discovery_closed" => false,
      "profiles" => [ duplicate.merge("username" => "") ]
    )
    assert_raises(Hive::ConfigError) { malformed_profile.read }
  end

  def test_inventory_secure_reader_rejects_untrusted_parent
    with_tmp_dir do |root|
      path = File.join(root, "installed-users.v1.json")
      File.write(path, JSON.generate(
        "schema" => "hive-installed-user-inventory",
        "schema_version" => 1,
        "discovery_closed" => false,
        "profiles" => []
      ))
      FileUtils.chmod(0o777, root)
      FileUtils.chmod(0o600, path)

      error = assert_raises(Hive::ConfigError) do
        Migration::Inventory.new(
          path: path,
          trusted_uid: Process.uid
        ).read
      end

      assert_match(/parent must be/, error.message)
    end
  end

  def test_inventory_and_candidate_require_no_follow_support
    with_tmp_dir do |root|
      inventory_path = File.join(root, "inventory.json")
      candidate_path = File.join(root, "hive")
      File.write(inventory_path, "{}")
      File.write(candidate_path, "#!/bin/sh\n")
      FileUtils.chmod(0o700, root)
      FileUtils.chmod(0o600, inventory_path)
      FileUtils.chmod(0o755, candidate_path)

      without_file_nofollow do
        error = assert_raises(Hive::ConfigError) do
          Migration::Inventory.new(
            path: inventory_path,
            trusted_uid: Process.uid
          ).read
        end
        assert_match(/requires no-follow/, error.message)

        error = assert_raises(Hive::ConfigError) do
          Migration::CandidateIdentity.capture(candidate_path)
        end
        assert_match(/requires no-follow/, error.message)
      end
    end
  end

  def test_inventory_secure_reader_rejects_descriptor_and_path_swaps
    with_tmp_dir do |root|
      path = File.join(root, "inventory.json")
      bytes = JSON.generate(
        "schema" => "hive-installed-user-inventory",
        "schema_version" => 1,
        "discovery_closed" => false,
        "profiles" => []
      )
      File.write(path, bytes)
      FileUtils.chmod(0o700, root)
      FileUtils.chmod(0o600, path)
      before = fake_inventory_stat(bytes, ino: 10)
      replaced = fake_inventory_stat(bytes, ino: 11)
      opened = fake_opened_file(bytes, [ replaced ])
      error = assert_raises(Hive::ConfigError) do
        Migration::Inventory.new(
          path: path,
          trusted_uid: Process.uid,
          lstat: ->(candidate) {
            candidate == path ? before : File.lstat(candidate)
          },
          open_file: ->(_candidate, _flags, &block) {
            block.call(opened)
          }
        ).read
      end
      assert_match(/before it was opened/, error.message)

      path_calls = 0
      opened = fake_opened_file(bytes, [ before, before ])
      error = assert_raises(Hive::ConfigError) do
        Migration::Inventory.new(
          path: path,
          trusted_uid: Process.uid,
          lstat: lambda do |candidate|
            next File.lstat(candidate) unless candidate == path

            path_calls += 1
            path_calls == 1 ? before : replaced
          end,
          open_file: ->(_candidate, _flags, &block) {
            block.call(opened)
          }
        ).read
      end
      assert_match(/changed while it was read/, error.message)
    end
  end

  def test_inventory_secure_reader_wraps_parent_stat_error
    with_tmp_dir do |root|
      path = File.join(root, "inventory.json")
      File.write(path, "{}")
      before = fake_inventory_stat("{}", ino: 10)

      error = assert_raises(Hive::ConfigError) do
        Migration::Inventory.new(
          path: path,
          trusted_uid: Process.uid,
          lstat: ->(candidate) {
            raise Errno::EIO, candidate unless candidate == path

            before
          }
        ).read
      end

      assert_match(/cannot validate.*parent/, error.message)
    end
  end

  def test_catalog_reports_uid_or_home_drift_in_root_inventory
    with_tmp_dir do |root|
      home = File.join(root, "alice")
      FileUtils.mkdir_p(home)
      inventory = Object.new
      inventory.define_singleton_method(:read) do
        Migration::Inventory::Result.new(
          profiles: [ {
            username: "former-alice",
            uid: 1_001,
            home: home,
            environment: {}
          } ],
          issues: [],
          closed: true,
          path: "/var/lib/hive/installed-users.v1.json",
          digest: "b" * 64
        )
      end
      catalog = migration_catalog(
        accounts: -> {
          [ { name: "alice", uid: 1_001, gid: 2_001, dir: home } ]
        },
        inventory: inventory
      )

      result = catalog.snapshot

      assert_empty result.profiles
      assert_equal "inventory_identity_drift",
                   result.issues.first.kind
    end
  end

  def test_catalog_rejects_ambiguous_nss_uid_reuse
    with_tmp_dir do |root|
      alice = File.join(root, "alice")
      replacement = File.join(root, "replacement")
      FileUtils.mkdir_p([ alice, replacement ])
      FileUtils.mkdir_p(File.join(alice, ".config", "hive"))
      File.write(
        File.join(alice, ".config", "hive", "config.yml"),
        "registered_projects: []\n"
      )
      inventory = Object.new
      inventory.define_singleton_method(:read) do
        Migration::Inventory::Result.new(
          profiles: [],
          issues: [],
          closed: true,
          path: "/var/lib/hive/installed-users.v1.json",
          digest: "c" * 64
        )
      end
      catalog = migration_catalog(
        accounts: -> {
          [
            { name: "alice", uid: 1_001, gid: 2_001, dir: alice },
            {
              name: "replacement", uid: 1_001, gid: 2_002,
              dir: replacement
            }
          ]
        },
        inventory: inventory
      )

      result = catalog.snapshot

      assert_empty result.profiles
      assert_equal "nss_uid_ambiguous", result.issues.first.kind
    end
  end

  def test_catalog_rejects_profile_roots_shared_by_different_os_users
    with_tmp_dir do |root|
      alice_home = File.join(root, "alice")
      bob_home = File.join(root, "bob")
      shared = File.join(root, "shared-hive")
      shared_alias = File.join(root, "shared-hive-alias")
      FileUtils.mkdir_p([ alice_home, bob_home, shared ])
      File.symlink(shared, shared_alias)
      inventory = Object.new
      inventory.define_singleton_method(:read) do
        Migration::Inventory::Result.new(
          profiles: [
            {
              username: "alice",
              uid: 1_001,
              home: alice_home,
              environment: { "HIVE_HOME" => shared }
            },
            {
              username: "bob",
              uid: 1_002,
              home: bob_home,
              environment: { "HIVE_HOME" => shared_alias }
            }
          ],
          issues: [],
          closed: true,
          path: "/var/lib/hive/installed-users.v1.json",
          digest: "e" * 64
        )
      end
      catalog = migration_catalog(
        accounts: -> {
          [
            {
              name: "alice", uid: 1_001, gid: 2_001,
              dir: alice_home
            },
            {
              name: "bob", uid: 1_002, gid: 2_002,
              dir: bob_home
            }
          ]
        },
        inventory: inventory
      )

      result = catalog.snapshot

      assert_empty result.profiles
      assert_equal [ "alice", "alice", "bob", "bob" ],
                   result.issues.map(&:username).sort
      assert(result.issues.all? do |issue|
        issue.kind == "shared_profile_root"
      end)
      assert(result.issues.all? do |issue|
        issue.detail.include?("assigned to multiple OS users")
      end)
    end
  end

  def test_catalog_rejects_cross_kind_root_convergence_between_users
    with_tmp_dir do |root|
      alice_home = File.join(root, "alice")
      bob_home = File.join(root, "bob")
      shared_parent = File.join(root, "shared")
      FileUtils.mkdir_p([
        alice_home,
        bob_home,
        File.join(shared_parent, "hive")
      ])
      inventory = Object.new
      inventory.define_singleton_method(:read) do
        Migration::Inventory::Result.new(
          profiles: [
            {
              username: "alice",
              uid: 1_001,
              home: alice_home,
              environment: {
                "XDG_CONFIG_HOME" => shared_parent,
                "XDG_STATE_HOME" => File.join(alice_home, "state")
              }
            },
            {
              username: "bob",
              uid: 1_002,
              home: bob_home,
              environment: {
                "XDG_CONFIG_HOME" => File.join(bob_home, "config"),
                "XDG_STATE_HOME" => shared_parent
              }
            }
          ],
          issues: [],
          closed: true,
          path: "/var/lib/hive/installed-users.v1.json",
          digest: "e" * 64
        )
      end
      catalog = migration_catalog(
        accounts: -> {
          [
            {
              name: "alice", uid: 1_001, gid: 2_001,
              dir: alice_home
            },
            {
              name: "bob", uid: 1_002, gid: 2_002,
              dir: bob_home
            }
          ]
        },
        inventory: inventory
      )

      result = catalog.snapshot

      assert_empty result.profiles
      assert_equal %w[alice bob],
                   result.issues.map(&:username).uniq.sort
      assert(result.issues.all? do |issue|
        issue.kind == "shared_profile_root"
      end)
    end
  end

  def test_root_binding_rejects_inode_retarget_and_missing_root_appearance
    with_tmp_dir do |root|
      home = File.join(root, "home")
      hive_home = File.join(home, "hive")
      FileUtils.mkdir_p(hive_home)
      binder = Migration::ProfileRootBindings.new
      bindings = binder.bind(
        home: home,
        environment: { "HIVE_HOME" => hive_home },
        uid: Process.uid
      )
      candidate = Migration::Profile.new(
        username: "current",
        uid: Process.uid,
        gid: Process.gid,
        home: home,
        real_home: File.realpath(home),
        environment: { "HIVE_HOME" => hive_home },
        source: "root-inventory",
        supplementary_gids: Process.groups.uniq.sort,
        root_bindings: bindings
      )
      File.rename(hive_home, "#{hive_home}.old")
      FileUtils.mkdir_p(hive_home)

      error = assert_raises(Hive::ConfigError) do
        binder.verify!(candidate)
      end
      assert_match(/identity changed/, error.message)

      missing = File.join(home, "missing-hive")
      bindings = binder.bind(
        home: home,
        environment: { "HIVE_HOME" => missing },
        uid: Process.uid
      )
      candidate = candidate.with(
        environment: { "HIVE_HOME" => missing },
        root_bindings: bindings
      )
      FileUtils.mkdir_p(missing)
      error = assert_raises(Hive::ConfigError) do
        binder.verify!(candidate)
      end
      assert_match(/appeared after discovery/, error.message)
    end
  end

  def test_catalog_isolates_unavailable_homes_and_malformed_nss_rows
    with_tmp_dir do |root|
      home = File.join(root, "alice")
      FileUtils.mkdir_p(File.join(home, ".config", "hive"))
      File.write(
        File.join(home, ".config", "hive", "config.yml"),
        "registered_projects: []\n"
      )
      inventory = Object.new
      inventory.define_singleton_method(:read) do
        Migration::Inventory::Result.new(
          profiles: [],
          issues: [],
          closed: true,
          path: "/var/lib/hive/installed-users.v1.json",
          digest: "f" * 64
        )
      end
      catalog = migration_catalog(
        accounts: -> {
          [
            { name: "broken", uid: "not-an-integer", gid: 2_000, dir: home },
            { name: "alice", uid: 1_001, gid: 2_001, dir: home }
          ]
        },
        inventory: inventory,
        probe: Migration::Catalog::PathProbe.new(
          lstat: ->(path) {
            raise Errno::EIO, path if path == home

            File.lstat(path)
          }
        )
      )

      result = catalog.snapshot

      assert_empty result.profiles
      assert_equal "default_home_unavailable", result.issues.first.kind
    end
  end

  def test_catalog_isolates_unavailable_inventoried_home
    with_tmp_dir do |root|
      home = File.join(root, "alice")
      FileUtils.mkdir_p(home)
      inventory = Object.new
      inventory.define_singleton_method(:read) do
        Migration::Inventory::Result.new(
          profiles: [ {
            username: "alice",
            uid: 1_001,
            home: home,
            environment: { "HIVE_HOME" => File.join(home, "custom") }
          } ],
          issues: [],
          closed: true,
          path: "/var/lib/hive/installed-users.v1.json",
          digest: "a" * 64
        )
      end
      calls = 0
      catalog = migration_catalog(
        accounts: -> {
          [ { name: "alice", uid: 1_001, gid: 2_001, dir: home } ]
        },
        inventory: inventory,
        probe: Migration::Catalog::PathProbe.new(
          lstat: lambda do |path|
            return File.lstat(path) unless path == home

            calls += 1
            return File.lstat(path) if calls == 1
            raise Errno::EACCES, path
          end
        )
      )

      result = catalog.snapshot

      assert_empty result.profiles
      assert_equal "inventory_home_unavailable", result.issues.first.kind
    end
  end

  def test_catalog_rejects_two_environments_for_one_profile_root
    with_tmp_dir do |root|
      home = File.join(root, "alice")
      FileUtils.mkdir_p(File.join(home, ".config", "hive"))
      File.write(
        File.join(home, ".config", "hive", "config.yml"),
        "registered_projects: []\n"
      )
      inventory = Object.new
      inventory.define_singleton_method(:read) do
        Migration::Inventory::Result.new(
          profiles: [ {
            username: "alice",
            uid: 1_001,
            home: home,
            environment: {
              "XDG_CACHE_HOME" => File.join(home, "custom-cache")
            }
          } ],
          issues: [],
          closed: true,
          path: "/var/lib/hive/installed-users.v1.json",
          digest: "b" * 64
        )
      end
      catalog = migration_catalog(
        accounts: -> {
          [ { name: "alice", uid: 1_001, gid: 2_001, dir: home } ]
        },
        inventory: inventory
      )

      result = catalog.snapshot

      assert_empty result.profiles
      assert_equal "profile_root_ambiguous", result.issues.first.kind
    end
  end

  def test_catalog_uses_lexical_missing_custom_roots
    with_tmp_dir do |root|
      home = File.join(root, "alice")
      custom = File.join(home, "missing-custom")
      FileUtils.mkdir_p(home)
      inventory = Object.new
      inventory.define_singleton_method(:read) do
        Migration::Inventory::Result.new(
          profiles: [ {
            username: "alice",
            uid: 1_001,
            home: home,
            environment: { "HIVE_HOME" => custom }
          } ],
          issues: [],
          closed: true,
          path: "/var/lib/hive/installed-users.v1.json",
          digest: "c" * 64
        )
      end
      catalog = migration_catalog(
        accounts: -> {
          [ { name: "alice", uid: 1_001, gid: 2_001, dir: home } ]
        },
        inventory: inventory
      )

      result = catalog.snapshot

      assert_equal [ "alice" ], result.profiles.map(&:username)
      assert_empty result.issues
    end
  end

  def test_nss_identity_requires_exact_uid_name_gid_and_home_binding
    with_tmp_dir do |home|
      candidate = profile(
        "alice", 1_001, home, gid: 2_001
      )
      entry = Struct.new(:name, :uid, :gid, :dir)
        .new("alice", 1_001, 2_001, home)
      validator = Migration::NssIdentity.new(
        by_uid: ->(_uid) { entry },
        by_name: ->(_name) { entry }
      )

      assert validator.call(candidate)

      drifted = entry.dup
      drifted.dir = File.join(home, "replacement")
      validator = Migration::NssIdentity.new(
        by_uid: ->(_uid) { entry },
        by_name: ->(_name) { drifted }
      )
      error = assert_raises(Hive::ConfigError) do
        validator.call(candidate)
      end
      assert_match(/identity changed/, error.message)

      missing = Migration::NssIdentity.new(
        by_uid: ->(_uid) { raise ArgumentError, "gone" },
        by_name: ->(_name) { flunk("name lookup should not run") }
      )
      error = assert_raises(Hive::ConfigError) do
        missing.call(candidate)
      end
      assert_match(/identity disappeared/, error.message)

      malformed = entry.dup
      malformed.uid = nil
      validator = Migration::NssIdentity.new(
        by_uid: ->(_uid) { malformed },
        by_name: ->(_name) { malformed }
      )
      error = assert_raises(Hive::ConfigError) do
        validator.call(candidate)
      end
      assert_match(/identity changed/, error.message)
    end
  end

  def test_executor_requires_root_before_real_child_execution
    with_tmp_dir do |home|
      executor = Migration::Executor.new(
        binary: File.expand_path("../../../bin/hive", __dir__),
        effective_uid: -> { 1_001 },
        identity_validator: IDENTITY_OK
      )

      error = assert_raises(Hive::ConfigError) do
        executor.call(profile("alice", 1_001, home))
      end

      assert_match(/requires root authority/, error.message)
    end
  end

  def test_executor_scrubs_parent_environment_and_passes_exact_profile_roots
    with_tmp_dir do |home|
      custom = File.join(home, "custom")
      FileUtils.mkdir_p(custom)
      observed = nil
      executor = Migration::Executor.new(
        binary: File.expand_path("../../../bin/hive", __dir__),
        identity_validator: IDENTITY_OK,
        force: false,
        runner: lambda do |candidate, environment, argv|
          observed = [ candidate, environment, argv ]
          installation_payload("alice", profile: candidate)
        end
      )

      with_env(
        "OPENAI_API_KEY" => "not-for-child",
        "HIVE_HOME" => "/wrong-parent-root"
      ) do
        executor.call(
          profile(
            "alice", Process.uid, home,
            gid: Process.gid,
            environment: { "HIVE_HOME" => custom }
          )
        )
      end

      candidate, environment, argv = observed
      assert_equal "alice", candidate.username
      assert_equal custom, environment.fetch("HIVE_HOME")
      assert_equal home, environment.fetch("HOME")
      assert_equal "alice", environment.fetch("USER")
      refute environment.key?("OPENAI_API_KEY")
      assert_equal "1",
                   environment.fetch("HIVE_JOB_SCHEMA_MIGRATION_INTERNAL")
      assert_equal [
        "refactor-patrol-migrate-installed", "--resume"
      ], argv.last(2)
      assert File.absolute_path(argv.first) == argv.first
    end
  end

  def test_executor_force_controls_child_resume_argument
    binary = File.expand_path("../../../bin/hive", __dir__)
    forced = Migration::Executor.new(
      binary: binary,
      candidate: candidate_identity,
      force: true
    )
    resumed = Migration::Executor.new(
      binary: binary,
      candidate: candidate_identity,
      force: false
    )

    assert_equal(
      [ binary, "refactor-patrol-migrate-installed" ],
      forced.send(:argv)
    )
    assert_equal(
      [ binary, "refactor-patrol-migrate-installed", "--resume" ],
      resumed.send(:argv)
    )
  end

  def test_executor_rejects_incomplete_user_profile_receipt
    with_tmp_dir do |home|
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )
      executor = Migration::Executor.new(
        binary: File.expand_path("../../../bin/hive", __dir__),
        identity_validator: IDENTITY_OK,
        runner: lambda do |profile, _environment, _argv|
          installation_payload("alice", profile: profile).tap do |payload|
            payload.fetch("projects").first.delete("real_path")
          end
        end
      )

      error = assert_raises(Hive::ConfigError) do
        executor.call(candidate)
      end

      assert_match(/invalid user-profile receipt/, error.message)
    end
  end

  def test_executor_revalidates_candidate_after_injected_attempt
    with_tmp_dir do |root|
      home = File.join(root, "home")
      binary = File.join(root, "hive")
      FileUtils.mkdir_p(home)
      File.write(binary, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, binary)
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )
      executor = Migration::Executor.new(
        binary: binary,
        identity_validator: IDENTITY_OK,
        runner: lambda do |profile, _environment, _argv|
          File.write(binary, "#!/bin/sh\nexit 1\n")
          installation_payload("alice", profile: profile)
        end
      )

      error = assert_raises(Hive::ConfigError) do
        executor.call(candidate)
      end

      assert_match(/changed after activation/, error.message)
    end
  end

  def test_identity_drop_replaces_groups_gid_and_uid_in_order
    with_tmp_dir do |home|
      calls = []
      current_uid = nil
      current_gid = nil
      drop = Migration::IdentityDrop.new(
        groups_setter: ->(groups) {
          calls << [ :groups, groups ]
        },
        gid_drop: ->(gid) {
          calls << [ :gid, gid ]
          current_gid = gid
        },
        uid_drop: ->(uid) {
          calls << [ :uid, uid ]
          current_uid = uid
        },
        effective_uid: -> { current_uid },
        effective_gid: -> { current_gid },
        groups: -> { [ 2_001, 2_100 ] }
      )
      candidate = profile(
        "alice", 1_001, home, gid: 2_001,
        supplementary_gids: [ 2_001, 2_100 ]
      )

      assert drop.call(candidate)
      assert_equal [
        [ :groups, [ 2_001, 2_100 ] ],
        [ :gid, 2_001 ],
        [ :uid, 1_001 ]
      ], calls
    end
  end

  def test_child_launcher_scrubs_process_and_execs_exact_argv
    with_tmp_dir do |home|
      calls = []
      process_environment = { "SECRET" => "parent" }
      readers = [ fake_closable(calls, :stdout_reader),
                  fake_closable(calls, :stderr_reader) ]
      stdout_writer = fake_closable(calls, :stdout_writer)
      stderr_writer = fake_closable(calls, :stderr_writer)
      launcher = Migration::ChildLauncher.new(
        identity_drop: ->(profile) {
          calls << [ :identity, profile.uid ]
        },
        session: -> { calls << :session },
        environment: process_environment,
        stdout_reopen: ->(io) { calls << [ :stdout, io ] },
        stderr_reopen: ->(io) { calls << [ :stderr, io ] },
        umask: ->(mode) { calls << [ :umask, mode ] },
        chdir: ->(path) { calls << [ :chdir, path ] },
        execer: ->(*argv, **options) {
          calls << [ :exec, argv, options ]
        },
        warning: ->(message) { flunk(message) },
        exit_process: ->(status) { flunk("unexpected exit #{status}") }
      )
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )
      environment = { "HOME" => home, "USER" => "alice" }
      argv = [ "/usr/bin/hive", "refactor-patrol-migrate-installed" ]

      launcher.call(
        candidate,
        environment,
        argv,
        readers: readers,
        writers: { stdout: stdout_writer, stderr: stderr_writer }
      )

      assert_equal environment, process_environment
      assert_includes calls, :session
      assert_includes calls, [ :identity, Process.uid ]
      assert_includes calls, [ :umask, 0o077 ]
      assert_includes calls, [ :chdir, home ]
      assert_includes calls,
                      [ :exec, argv, { close_others: true } ]
      assert_equal 4, calls.count { |call| Array(call).first == :close }
    end
  end

  def test_child_launcher_reports_setup_failure_and_exits_126
    with_tmp_dir do |home|
      warnings = []
      exits = []
      launcher = Migration::ChildLauncher.new(
        identity_drop: ->(_profile) { raise Hive::ConfigError, "drop failed" },
        session: -> { },
        environment: {},
        stdout_reopen: ->(_io) { },
        stderr_reopen: ->(_io) { },
        umask: ->(_mode) { },
        chdir: ->(_path) { },
        execer: ->(*) { flunk("exec should not run") },
        warning: ->(message) { warnings << message },
        exit_process: ->(status) { exits << status }
      )
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )

      launcher.call(
        candidate,
        {},
        [ "/usr/bin/hive" ],
        readers: [ fake_closable([], :reader) ],
        writers: {
          stdout: fake_closable([], :stdout),
          stderr: fake_closable([], :stderr)
        }
      )

      assert_equal [ 126 ], exits
      assert_match(/drop failed/, warnings.fetch(0))
      assert_match(/uid #{Process.uid}/, warnings.fetch(0))
    end
  end

  def test_identity_drop_rejects_retained_root_group_or_identity_mismatch
    with_tmp_dir do |home|
      drop = Migration::IdentityDrop.new(
        groups_setter: ->(*) { },
        gid_drop: ->(*) { },
        uid_drop: ->(*) { },
        effective_uid: -> { 1_001 },
        effective_gid: -> { 2_001 },
        groups: -> { [ 0, 2_001 ] }
      )

      error = assert_raises(Hive::ConfigError) do
        drop.call(profile("alice", 1_001, home, gid: 2_001))
      end

      assert_match(/complete identity/, error.message)
    end
  end

  def test_candidate_identity_rejects_entrypoint_replacement
    with_tmp_dir do |root|
      binary = File.join(root, "hive")
      File.write(binary, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, binary)
      candidate = Migration::CandidateIdentity.capture(binary)
      File.write(binary, "#!/bin/sh\nexit 1\n")

      error = assert_raises(Hive::ConfigError) do
        Migration::CandidateIdentity.verify!(candidate)
      end

      assert_match(/changed after activation/, error.message)
    end
  end

  def test_candidate_identity_rejects_missing_or_non_executable_entrypoint
    with_tmp_dir do |root|
      missing = File.join(root, "missing-hive")
      error = assert_raises(Hive::ConfigError) do
        Migration::CandidateIdentity.capture(missing)
      end
      assert_match(/cannot capture/, error.message)

      non_executable = File.join(root, "hive")
      File.write(non_executable, "not executable\n")
      error = assert_raises(Hive::ConfigError) do
        Migration::CandidateIdentity.capture(non_executable)
      end
      assert_match(/not a bounded executable/, error.message)

      File.write(non_executable, "")
      FileUtils.chmod(0o755, non_executable)
      error = assert_raises(Hive::ConfigError) do
        Migration::CandidateIdentity.capture(non_executable)
      end
      assert_match(/not a bounded executable/, error.message)
    end
  end

  def test_executor_runs_bounded_child_and_reports_child_failures
    with_tmp_dir do |root|
      home = File.join(root, "home")
      FileUtils.mkdir_p(home)
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )
      payload = installation_payload("alice", profile: candidate)
      binary = write_executable(
        root, "hive-success",
        "STDOUT.write(#{JSON.generate(payload).dump})"
      )
      executor = Migration::Executor.new(
        binary: binary,
        effective_uid: -> { 0 },
        identity_drop: IDENTITY_OK,
        identity_validator: IDENTITY_OK
      )

      assert_equal payload, executor.call(candidate)

      failed_binary = write_executable(
        root, "hive-failed",
        "warn \"sk-ant-abcdefghijklmnopqrst\"\nexit 7"
      )
      failed = Migration::Executor.new(
        binary: failed_binary,
        effective_uid: -> { 0 },
        identity_drop: IDENTITY_OK,
        identity_validator: IDENTITY_OK
      )
      error = assert_raises(Hive::Error) { failed.call(candidate) }
      assert_match(/exit 7/, error.message)
      refute_includes error.message, "sk-ant-abcdefghijklmnopqrst"

      malformed_binary = write_executable(
        root, "hive-malformed",
        "STDOUT.write(\"not-json\")"
      )
      malformed = Migration::Executor.new(
        binary: malformed_binary,
        effective_uid: -> { 0 },
        identity_drop: IDENTITY_OK,
        identity_validator: IDENTITY_OK
      )
      error = assert_raises(Hive::ConfigError) do
        malformed.call(candidate)
      end
      assert_match(/malformed JSON/, error.message)

      child_setup_failed = Migration::Executor.new(
        binary: binary,
        effective_uid: -> { 0 },
        identity_drop: ->(_profile) { raise Hive::ConfigError, "drop failed" },
        identity_validator: IDENTITY_OK
      )
      error = assert_raises(Hive::Error) do
        child_setup_failed.call(candidate)
      end
      assert_match(/exit 126/, error.message)
      assert_match(/drop failed/, error.message)
    end
  end

  def test_executor_capture_finishes_while_restarted_user_daemon_stays_live
    with_tmp_dir do |root|
      home = File.join(root, "home")
      FileUtils.mkdir_p(home)
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )
      payload = installation_payload("alice", profile: candidate)
      daemon_pid_path = File.join(root, "restarted-daemon.pid")
      library_path = File.expand_path("../../../lib", __dir__)
      daemon_program = <<~RUBY
        Process.daemon(true, true)
        File.write(ARGV.fetch(0), Process.pid)
        sleep 30
      RUBY
      body = <<~RUBY
        $LOAD_PATH.unshift(#{library_path.dump})
        require "hive"
        require "hive/refactor_patrol/installed_job_schema_migration"
        lifecycle =
          Hive::RefactorPatrol::InstalledJobSchemaMigration::DaemonLifecycle.new(
            status_report: Object.new
          )
        lifecycle.send(
          :run_command,
          [#{RbConfig.ruby.dump}, "-e", #{daemon_program.dump}, #{daemon_pid_path.dump}],
          {}
        )
        STDOUT.write(#{JSON.generate(payload).dump})
      RUBY
      binary = write_executable(root, "hive-restarts-daemon", body)
      executor = Migration::Executor.new(
        binary: binary,
        effective_uid: -> { 0 },
        identity_drop: IDENTITY_OK,
        identity_validator: IDENTITY_OK,
        timeout_sec: 3
      )

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal payload, executor.call(candidate)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 2
      wait_for_path(daemon_pid_path)
      daemon_pid = Integer(File.binread(daemon_pid_path))
      assert_equal 1, Process.kill(0, daemon_pid)
    ensure
      terminate_pid_from(daemon_pid_path)
    end
  end

  def test_executor_kills_timed_out_or_oversized_child
    with_tmp_dir do |root|
      home = File.join(root, "home")
      FileUtils.mkdir_p(home)
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )
      timeout_binary = write_executable(
        root, "hive-timeout", "sleep 5"
      )
      timeout = Migration::Executor.new(
        binary: timeout_binary,
        effective_uid: -> { 0 },
        identity_drop: IDENTITY_OK,
        identity_validator: IDENTITY_OK,
        timeout_sec: 0.05
      )
      error = assert_raises(Hive::ConfigError) do
        timeout.call(candidate)
      end
      assert_match(/exceeded 0.05 seconds/, error.message)

      oversized_binary = write_executable(
        root, "hive-oversized",
        "STDOUT.write(\"x\" * #{Migration::Executor::MAX_CAPTURE_BYTES + 1})"
      )
      oversized = Migration::Executor.new(
        binary: oversized_binary,
        effective_uid: -> { 0 },
        identity_drop: IDENTITY_OK,
        identity_validator: IDENTITY_OK
      )
      error = assert_raises(Hive::ConfigError) do
        oversized.call(candidate)
      end
      assert_match(/bounded capture/, error.message)
    end
  end

  def test_executor_deadline_covers_exit_after_capture_streams_close
    with_tmp_dir do |root|
      home = File.join(root, "home")
      FileUtils.mkdir_p(home)
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )
      binary = write_executable(
        root, "hive-closes-capture-then-hangs",
        "STDOUT.close\nSTDERR.close\nsleep 5"
      )
      executor = Migration::Executor.new(
        binary: binary,
        effective_uid: -> { 0 },
        identity_drop: IDENTITY_OK,
        identity_validator: IDENTITY_OK,
        timeout_sec: 0.05
      )

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(Hive::ConfigError) do
        executor.call(candidate)
      end

      assert_match(/exceeded 0.05 seconds/, error.message)
      assert_operator(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        :<,
        1
      )
    end
  end

  def test_executor_cleanup_tolerates_disappeared_processes_and_streams
    executor = Migration::Executor.new(
      binary: File.expand_path("../../../bin/hive", __dir__),
      candidate: candidate_identity,
      process_wait: ->(_pid) { raise Errno::ECHILD },
      runner: ->(*) { flunk("runner should not execute") }
    )
    executor.define_singleton_method(:kill_child) do |_pid|
      raise Errno::EPERM, "cannot signal"
    end

    assert_nil executor.send(:cleanup_child, 12_345)

    stream = Object.new
    stream.define_singleton_method(:closed?) { false }
    stream.define_singleton_method(:close) { raise IOError, "already closed" }

    assert_nil executor.send(:close_stream, stream)
  end

  def test_executor_kill_falls_back_from_process_group_to_child
    calls = []
    killer = lambda do |signal, pid|
      calls << [ signal, pid ]
      raise Errno::ESRCH, "gone"
    end
    executor = Migration::Executor.new(
      binary: File.expand_path("../../../bin/hive", __dir__),
      candidate: candidate_identity,
      process_kill: killer,
      runner: ->(*) { flunk("runner should not execute") }
    )

    assert_nil executor.send(:kill_child, 12_345)
    assert_equal [ [ "KILL", -12_345 ], [ "KILL", 12_345 ] ], calls
  end

  def test_candidate_identity_rejects_capture_time_path_swap
    with_tmp_dir do |root|
      binary = write_executable(root, "hive", "exit 0")
      current = File.stat(binary)
      fields = %i[dev ino size mode uid gid mtime ctime]
      drifted = Struct.new(*fields).new(
        current.dev,
        current.ino + 1,
        current.size,
        current.mode,
        current.uid,
        current.gid,
        current.mtime,
        current.ctime
      )

      error = assert_raises(Hive::ConfigError) do
        Migration::CandidateIdentity.capture(
          binary,
          lstat: ->(_path) { drifted }
        )
      end

      assert_match(/changed during capture/, error.message)
    end
  end

  def test_executor_rejects_home_drift_and_bad_timeout
    with_tmp_dir do |root|
      home = File.join(root, "home")
      replacement = File.join(root, "replacement")
      FileUtils.mkdir_p([ home, replacement ])
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )
      executor = Migration::Executor.new(
        binary: File.expand_path("../../../bin/hive", __dir__),
        identity_validator: IDENTITY_OK,
        runner: ->(*) { flunk("runner should not execute") }
      )
      FileUtils.rm_rf(home)
      File.symlink(replacement, home)

      error = assert_raises(Hive::ConfigError) do
        executor.call(candidate)
      end
      assert_match(/home changed/, error.message)

      FileUtils.rm_f(home)
      FileUtils.mkdir_p(home)
      candidate = profile(
        "alice", Process.uid, home, gid: Process.gid
      )
      inaccessible = Migration::Executor.new(
        binary: File.expand_path("../../../bin/hive", __dir__),
        identity_validator: IDENTITY_OK,
        realpath: ->(_path) { raise Errno::EIO, "unavailable" },
        runner: ->(*) { flunk("runner should not execute") }
      )
      error = assert_raises(Hive::ConfigError) do
        inaccessible.call(candidate)
      end
      assert_match(/cannot revalidate/, error.message)

      assert_raises(ArgumentError) do
        Migration::Executor.new(
          binary: File.expand_path("../../../bin/hive", __dir__),
          timeout_sec: 0
        )
      end
    end
  end

  private

  def migration_catalog(**options)
    Migration::Catalog.new(
      root_bindings: CurrentUserRootBindings.new,
      **options
    )
  end

  def snapshot(profiles, closed:)
    Migration::Snapshot.new(
      profiles: profiles,
      issues: [],
      closed: closed,
      inventory_path: "/var/lib/hive/installed-users.v1.json",
      inventory_digest: closed ? "d" * 64 : nil
    )
  end

  def profile(username, uid, home, gid: uid, environment: {},
              supplementary_gids: [ gid ])
    bindings = Migration::ProfileRootBindings.new.bind(
      home: home,
      environment: environment,
      uid: Process.uid
    )
    Migration::Profile.new(
      username: username,
      uid: uid,
      gid: gid,
      home: home,
      real_home: File.realpath(home),
      environment:
        Migration::ProfileRoots.canonical_environment(
          environment, bindings
        ),
      source: environment.empty? ? "default-home" : "root-inventory",
      supplementary_gids: supplementary_gids.sort.freeze,
      root_bindings: bindings
    )
  end

  def installation_payload(name, retryable: false, profile:)
    hive_home = profile.environment["HIVE_HOME"]
    status = retryable ? "failed" : "current"
    {
      "schema" => "hive-user-profile-job-schema-migration",
      "schema_version" => 1,
      "hive_version" => Hive::VERSION,
      "target_schema_version" => 3,
      "registry_digest" => Digest::SHA256.hexdigest(name),
      "updated_at" => "2026-07-29T20:00:00.000000Z",
      "daemon_restart_pending" => false,
      "user_profile" => {
        "username" => profile.username,
        "uid" => profile.uid,
        "home" => profile.home,
        "config_home" =>
          hive_home || File.join(profile.home, ".config", "hive"),
        "state_home" =>
          hive_home || File.join(profile.home, ".local", "state", "hive")
      },
      "projects" => [ {
        "project" => "job-#{name}",
        "project_id" => "project-#{name}",
        "path" => profile.home,
        "real_path" => profile.real_home,
        "hive_state_path" => File.join(profile.home, ".hive-state"),
        "status" => status,
        "current_schema_version" => 3,
        "target_schema_version" => 3,
        "snapshot_id" => nil,
        "retryable" => retryable,
        "next_retry_at" =>
          retryable ? "2026-07-29T21:00:00.000000Z" : nil,
        "remediation" => retryable ? "retry later" : nil,
        "error" => retryable ? "migration pending" : nil
      } ]
    }
  end

  def candidate_identity
    @candidate_identity ||=
      Migration::CandidateIdentity.capture(
        File.expand_path("../../../bin/hive", __dir__)
      )
  end

  def inventory_for_document(document)
    bytes = JSON.generate(document)
    stat = FakeStat.new(
      dev: 1, ino: 2, uid: 0, gid: 0, mode: 0o100600,
      size: bytes.bytesize
    )
    Migration::Inventory.new(
      stat: ->(*) { stat },
      reader: ->(*) { bytes }
    )
  end

  def write_executable(root, name, body)
    path = File.join(root, name)
    File.write(path, "#!#{RbConfig.ruby}\n#{body}\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def fake_inventory_stat(bytes, ino:)
    FakeStat.new(
      dev: 1,
      ino: ino,
      uid: Process.uid,
      gid: Process.gid,
      mode: 0o100600,
      size: bytes.bytesize
    )
  end

  def fake_opened_file(bytes, stats)
    file = Object.new
    remaining = stats.dup
    file.define_singleton_method(:stat) do
      remaining.length > 1 ? remaining.shift : remaining.first
    end
    file.define_singleton_method(:read) { |_limit| bytes }
    file
  end

  def fake_closable(calls, name)
    io = Object.new
    io.define_singleton_method(:close) { calls << [ :close, name ] }
    io
  end

  def wait_for_path(path, timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until File.file?(path)
      raise "timed out waiting for #{path}" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def terminate_pid_from(path)
    wait_for_path(path, timeout: 0.5)
    Process.kill("KILL", Integer(File.binread(path)))
  rescue Errno::ENOENT, Errno::ESRCH, ArgumentError, RuntimeError
    nil
  end

  def without_file_nofollow
    original = File::NOFOLLOW
    File::Constants.send(:remove_const, :NOFOLLOW)
    yield
  ensure
    File::Constants.const_set(:NOFOLLOW, original) if original
  end

  def schema_errors(name, payload)
    schema = JSONSchemer.schema(
      JSON.parse(
        File.binread(File.expand_path("../../../schemas/#{name}", __dir__))
      )
    )
    schema.validate(payload).to_a
  end
end
