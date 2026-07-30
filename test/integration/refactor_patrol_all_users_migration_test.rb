require "test_helper"
require "digest"
require "etc"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "yaml"
require "hive/refactor_patrol/installed_users_job_schema_migration"

class RefactorPatrolAllUsersMigrationTest < Minitest::Test
  include HiveTestHelper

  Migration = Hive::RefactorPatrol::InstalledUsersJobSchemaMigration
  NAMESPACE_ENV = "HIVE_ALL_USERS_NAMESPACE_CHILD".freeze
  HOME_ROOT_ENV = "HIVE_ALL_USERS_HOME_ROOT".freeze
  REQUIRED_ENV = "HIVE_REQUIRE_TEST_RUNS".freeze

  def test_one_candidate_migrates_three_inactive_uid_profiles
    return run_in_user_namespace unless ENV[NAMESPACE_ENV] == "1" ||
                                        Process.euid.zero?

    profiles = []
    accounts = eligible_accounts
    assert_operator accounts.length, :>=, 3
    accounts = accounts.first(3)

    with_tmp_dir do |root|
      FileUtils.chmod(0o755, root)
      candidate = write_candidate(root)
      profiles = accounts.map.with_index do |account, index|
        prepare_profile(root, account, index)
      end
      inventory_path = write_inventory(root, profiles.drop(1))
      catalog = Migration::Catalog.new(
        accounts: -> {
          profiles.map do |profile|
            {
              name: profile.fetch(:account).name,
              uid: profile.fetch(:account).uid,
              gid: profile.fetch(:account).gid,
              dir: profile.fetch(:home)
            }
          end
        },
        inventory: Migration::Inventory.new(path: inventory_path)
      )
      migration = Migration.new(
        catalog: catalog,
        binary_path: -> { candidate },
        effective_uid: -> { Process.euid }
      )

      payload = migration.call(now: Time.utc(2026, 7, 29, 23, 45))

      assert_equal "complete", payload.fetch("status"),
                   JSON.pretty_generate(payload)
      assert payload.fetch("discovery_closed")
      assert_equal 3, payload.fetch("attempted_users")
      assert_equal 3, payload.fetch("attempted_profiles")
      assert_equal 0, payload.fetch("failed_users")
      assert_equal 0, payload.fetch("retryable_users")
      assert_equal accounts.map(&:uid).sort,
                   payload.fetch("profiles").map { |row| row.fetch("uid") }.sort
      assert(payload.fetch("profiles").all? do |row|
        row.fetch("status") == "completed" &&
          row.fetch("projects").one? &&
          row.dig("projects", 0, "status") == "migrated"
      end)

      profiles.each do |profile|
        assert_profile_migrated(profile)
      end
    end
  ensure
    if Process.euid.zero?
      profiles.each do |profile|
        FileUtils.rm_rf(profile[:home]) if profile[:home]
      end
    end
  end

  private

  def run_in_user_namespace
    reason = namespace_unavailable_reason
    if reason
      flunk(reason) if ENV[REQUIRED_ENV] == "1"
      skip(reason)
    end

    uid = Process.uid
    gid = Process.gid
    subuid = subordinate_range("/etc/subuid", Etc.getpwuid(uid).name)
    subgid = subordinate_range("/etc/subgid", Etc.getpwuid(uid).name)
    count = [ subuid.fetch(:count), subgid.fetch(:count), 65_535 ].min
    repo_source = File.expand_path("../..", __dir__)
    gem_source = Gem::Specification.find_by_name("thor").base_dir
    Dir.mktmpdir("hive-all-users-mount") do |mount_root|
      repo_target = File.join(mount_root, "repo")
      gem_target = File.join(mount_root, "gems")
      home_root = File.join(mount_root, "homes")
      passwd_path = File.join(mount_root, "passwd")
      group_path = File.join(mount_root, "group")
      FileUtils.mkdir_p([ repo_target, gem_target, home_root ])
      FileUtils.chmod(
        0o755, [ mount_root, repo_target, gem_target, home_root ]
      )
      write_namespace_accounts(passwd_path, group_path, home_root)
      nested_test = File.join(
        repo_target, "test", "integration",
        File.basename(__FILE__)
      )
      gem_paths = Gem.path.map do |path|
        path == gem_source ? gem_target : path
      end.join(File::PATH_SEPARATOR)
      shell = <<~'SH'
        set -eu
        mount --bind "$1" "$2"
        mount --bind "$3" "$4"
        export GEM_HOME="$4"
        export GEM_PATH="$5"
        mount --bind "$6" /etc/passwd
        mount --bind "$7" /etc/group
        shift 7
        exec "$@"
      SH
      command = [
        "unshare",
        "--mount",
        "--propagation", "unchanged",
        "--map-users", "0:#{uid}:1",
        "--map-users", "1:#{subuid.fetch(:start)}:#{count}",
        "--map-groups", "0:#{gid}:1",
        "--map-groups", "1:#{subgid.fetch(:start)}:#{count}",
        "sh", "-c", shell, "hive-all-users",
        repo_source, repo_target, gem_source, gem_target, gem_paths,
        passwd_path, group_path,
        RbConfig.ruby,
        "-I#{File.join(repo_target, 'test')}",
        "-I#{File.join(repo_target, 'lib')}",
        nested_test,
        "--name", name
      ]
      environment = {
        NAMESPACE_ENV => "1",
        HOME_ROOT_ENV => home_root,
        REQUIRED_ENV => ENV.fetch(REQUIRED_ENV, "0"),
        "RUBYOPT" => nil,
        "BUNDLE_GEMFILE" => nil
      }
      output, error, status = Open3.capture3(environment, *command)

      assert status.success?,
             "multi-UID namespace proof failed\nstdout:\n#{output}\nstderr:\n#{error}"
      evidence = output.match(/1 runs, (?<assertions>\d+) assertions/)
      refute_nil evidence, output
      assert_operator Integer(evidence[:assertions]), :>=, 28
    end
  end

  def write_namespace_accounts(passwd_path, group_path, home_root)
    accounts = [
      [ "hive-alice", 1_001, 2_001 ],
      [ "hive-bob", 1_002, 2_002 ],
      [ "hive-carol", 1_003, 2_003 ]
    ]
    passwd = [
      "root:x:0:0:root:/root:/bin/sh",
      *accounts.map do |name, uid, gid|
        "#{name}:x:#{uid}:#{gid}:Hive proof:" \
          "#{File.join(home_root, name)}:/bin/sh"
      end
    ].join("\n")
    groups = [
      "root:x:0:",
      *accounts.map { |name, _uid, gid| "#{name}:x:#{gid}:#{name}" }
    ].join("\n")
    File.write(passwd_path, "#{passwd}\n")
    File.write(group_path, "#{groups}\n")
    FileUtils.chmod(0o644, [ passwd_path, group_path ])
  end

  def namespace_unavailable_reason
    return "multi-UID migration proof requires Linux" unless
      RbConfig::CONFIG["host_os"].include?("linux")
    %w[unshare mount].each do |name|
      available = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, name))
      end
      return "multi-UID migration proof requires #{name}" unless available
    end

    username = Etc.getpwuid(Process.uid).name
    return "multi-UID migration proof requires /etc/subuid allocation" unless
      subordinate_range("/etc/subuid", username, missing: true)
    return "multi-UID migration proof requires /etc/subgid allocation" unless
      subordinate_range("/etc/subgid", username, missing: true)

    nil
  end

  def subordinate_range(path, username, missing: false)
    line = File.foreach(path).find do |entry|
      entry.split(":", 2).first == username
    end
    return nil if line.nil? && missing
    raise "no subordinate id range for #{username}" unless line

    _name, start, count = line.strip.split(":", 3)
    { start: Integer(start), count: Integer(count) }
  rescue Errno::ENOENT
    return nil if missing

    raise
  end

  def eligible_accounts
    root_members = Etc.getgrgid(0).mem
    entries = []
    Etc.passwd { |entry| entries << entry }
    entries.select do |entry|
      entry.uid.positive? &&
        entry.uid <= 65_535 &&
        entry.gid.positive? &&
        entry.gid <= 65_535 &&
        !root_members.include?(entry.name)
    end.sort_by(&:uid)
  end

  def write_candidate(root)
    path = File.join(root, "candidate", "hive")
    FileUtils.mkdir_p(File.dirname(path))
    ruby = RbConfig.ruby
    lib = File.expand_path("../../lib", __dir__)
    bin = File.expand_path("../../bin/hive", __dir__)
    File.write(path, <<~SH)
      #!/bin/sh
      export GEM_HOME=#{Shellwords.escape(Gem.dir)}
      export GEM_PATH=#{Shellwords.escape(Gem.path.join(File::PATH_SEPARATOR))}
      exec #{Shellwords.escape(ruby)} -I#{Shellwords.escape(lib)} #{Shellwords.escape(bin)} "$@"
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def prepare_profile(root, account, index)
    home = account.dir
    assert_equal ENV.fetch(HOME_ROOT_ENV), File.dirname(home)
    project = File.join(home, "project")
    FileUtils.mkdir_p(project)
    environment =
      case index
      when 0
        {}
      when 1
        { "HIVE_HOME" => File.join(home, "custom-hive") }
      else
        {
          "XDG_CONFIG_HOME" => File.join(home, "xdg-config"),
          "XDG_STATE_HOME" => File.join(home, "xdg-state")
        }
      end
    roots = profile_roots(home, environment)
    FileUtils.mkdir_p([ roots.fetch(:config), roots.fetch(:state) ])
    state = File.join(project, ".architecture-state")
    write_released_v2_job(state, "job-#{account.name}")
    registry = {
      "registered_projects" => [ {
        "name" => "project-#{account.name}",
        "path" => project,
        "real_path" => File.realpath(project),
        "hive_state_path" => state
      } ]
    }
    File.write(File.join(roots.fetch(:config), "config.yml"), registry.to_yaml)
    FileUtils.chown_R(account.uid, account.gid, home)
    FileUtils.chmod(0o700, home)

    {
      account: account,
      home: home,
      project: project,
      state: state,
      roots: roots,
      environment: environment
    }
  end

  def profile_roots(home, environment)
    hive_home = environment["HIVE_HOME"]
    {
      config:
        hive_home ||
        File.join(
          environment.fetch(
            "XDG_CONFIG_HOME", File.join(home, ".config")
          ),
          "hive"
        ),
      state:
        hive_home ||
        File.join(
          environment.fetch(
            "XDG_STATE_HOME", File.join(home, ".local", "state")
          ),
          "hive"
        )
    }
  end

  def write_inventory(root, custom_profiles)
    parent = File.join(root, "machine")
    path = File.join(parent, "installed-users.v1.json")
    FileUtils.mkdir_p(parent)
    payload = {
      "schema" => "hive-installed-user-inventory",
      "schema_version" => 1,
      "discovery_closed" => true,
      "profiles" => custom_profiles.map do |profile|
        {
          "username" => profile.dig(:account).name,
          "uid" => profile.dig(:account).uid,
          "home" => profile.fetch(:home),
          "environment" => profile.fetch(:environment)
        }
      end
    }
    File.write(path, JSON.generate(payload))
    FileUtils.chmod(0o700, parent)
    FileUtils.chmod(0o600, path)
    path
  end

  def assert_profile_migrated(profile)
    uid = profile.dig(:account).uid
    job_path = File.join(
      profile.fetch(:state),
      "refactor_patrol", "v3", "jobs",
      "job-#{profile.dig(:account).name}.json"
    )
    status_path = File.join(
      profile.dig(:roots, :state),
      "schema-migrations", "refactor-patrol-job-v3.json"
    )
    job = JSON.parse(File.binread(job_path))
    status = JSON.parse(File.binread(status_path))

    assert_equal 3, job.fetch("schema_version")
    assert_equal uid, status.dig("user_profile", "uid")
    assert_equal profile.fetch(:home),
                 status.dig("user_profile", "home")
    assert_equal uid, File.stat(job_path).uid
    assert_equal uid, File.stat(status_path).uid
    root_owned = Dir.glob(
      File.join(profile.fetch(:home), "**", "*"),
      File::FNM_DOTMATCH
    ).any? do |path|
      next false if %w[. ..].include?(File.basename(path))

      File.lstat(path).uid.zero?
    end
    refute root_owned,
           "privileged coordinator left root-owned state in #{profile.fetch(:home)}"
  end

  def write_released_v2_job(state_root, job_id)
    job = {
      "schema" => "hive-refactor-patrol-job",
      "schema_version" => 2,
      "job_id" => job_id,
      "source" => {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40,
        "merged_at" => "2026-07-10T12:00:00Z",
        "changed_paths" => [ "lib/checkout.rb" ],
        "manifest_checksum" => "c" * 64
      },
      "analysis_sha" => nil,
      "policy" => {
        "discovery" => true,
        "auto_fix" => false,
        "issue_filing" => false
      },
      "state" => "complete",
      "complete" => true,
      "dispositions" => {
        "accepted" => [], "flagged" => [], "suppressed" => []
      },
      "feature_results" => [],
      "review_errors" => [],
      "zero_reason" => "no_mapped_slice",
      "attempts" => [],
      "actions" => [],
      "created_at" => "2026-07-10T10:00:00Z",
      "updated_at" => "2026-07-10T10:01:00Z"
    }
    path = File.join(
      state_root, "refactor_patrol", "v2", "jobs", "#{job_id}.json"
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "#{JSON.pretty_generate(job)}\n")
  end
end
