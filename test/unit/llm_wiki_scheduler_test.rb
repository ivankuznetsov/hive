require "test_helper"
require "hive/llm_wiki_bootstrap"
require "socket"

class LlmWikiSchedulerTest < Minitest::Test
  include HiveTestHelper

  def setup
    skip "systemd user timers are Linux-only" unless RbConfig::CONFIG["host_os"].include?("linux")
  end

  def test_linked_worktrees_share_the_primary_checkout_timer
    with_scheduler_fixture do |home, main, linked|
      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) do
        Hive::LlmWikiBootstrap::Scheduler.install(main)
        Hive::LlmWikiBootstrap::Scheduler.install(linked)
      end

      user_dir = File.join(home, ".config", "systemd", "user")
      services = Dir[File.join(user_dir, "llm-wiki-*.service")]
      timers = Dir[File.join(user_dir, "llm-wiki-*.timer")]
      assert_equal 1, services.length
      assert_equal 1, timers.length
      assert_equal Hive::LlmWikiBootstrap::Scheduler.project_slug(main),
                   Hive::LlmWikiBootstrap::Scheduler.project_slug(linked)
      service = File.read(services.first)
      encoded_main = Hive::LlmWikiBootstrap::Scheduler.systemd_path(main)
      encoded_linked = Hive::LlmWikiBootstrap::Scheduler.systemd_path(linked)
      assert_includes service, "WorkingDirectory=#{encoded_main}"
      assert_includes service, "MemoryMax=4G"
      assert_includes service, "MemorySwapMax=0"
      assert_includes service, "X-HiveManaged=yes"
      assert_includes service, "Environment=LLM_WIKI_GLOBAL_LOCK_HELD=1"
      shared_runner = File.join(main, ".git", "llm-wiki", "post-commit-refresh.sh")
      assert_includes service, "ConditionFileIsExecutable=#{scheduler_path(shared_runner)}"
      assert_includes service, "#{scheduler_path(shared_runner)} --project #{encoded_main} --drain"
      assert File.executable?(shared_runner)
      assert_equal File.basename(services.first),
                   File.read(File.join(main, ".git", "llm-wiki", "scheduler-service")).strip
      refute_includes service, encoded_linked
    end
  end

  def test_reconcile_migrates_linked_unit_and_removes_stale_test_unit
    with_scheduler_fixture do |home, main, linked|
      user_dir = File.join(home, ".config", "systemd", "user")
      wants_dir = File.join(user_dir, "timers.target.wants")
      FileUtils.mkdir_p(wants_dir)
      legacy_slug = Hive::LlmWikiBootstrap::Scheduler.raw_project_slug(linked)
      legacy_service = "llm-wiki-#{legacy_slug}.service"
      legacy_timer = legacy_service.sub(/\.service\z/, ".timer")
      write_legacy_unit(user_dir, legacy_service, linked)
      File.write(File.join(user_dir, legacy_timer), "[Timer]\nPersistent=true\n")
      File.symlink(File.join("..", legacy_timer), File.join(wants_dir, legacy_timer))

      stale_service = "llm-wiki-hive-test-stale.service"
      write_legacy_unit(user_dir, stale_service, "/tmp/hive-test-deleted-project")
      File.write(File.join(user_dir, stale_service.sub(/\.service\z/, ".timer")), "[Timer]\n")

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }

      canonical_slug = Hive::LlmWikiBootstrap::Scheduler.raw_project_slug(main)
      canonical_service = File.join(user_dir, "llm-wiki-#{canonical_slug}.service")
      canonical_timer = File.join(user_dir, "llm-wiki-#{canonical_slug}.timer")
      assert_path_exists canonical_service
      assert_path_exists canonical_timer
      assert File.symlink?(File.join(wants_dir, File.basename(canonical_timer)))
      refute_path_exists File.join(user_dir, legacy_service)
      refute_path_exists File.join(user_dir, legacy_timer)
      refute_path_exists File.join(user_dir, stale_service)
      refute_path_exists File.join(user_dir, stale_service.sub(/\.service\z/, ".timer"))
    end
  end

  def test_reconcile_preserves_non_hive_and_unreadable_managed_projects
    with_tmp_dir do |root|
      home = File.join(root, "home")
      project = File.join(root, "project")
      user_dir = File.join(home, ".config", "systemd", "user")
      FileUtils.mkdir_p(File.join(project, ".llm-wiki"))
      FileUtils.mkdir_p(user_dir)
      File.write(File.join(project, ".llm-wiki", "config.json"), "not-json\n")
      service = "llm-wiki-external.service"
      write_legacy_unit(user_dir, service, project)

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }

      assert_path_exists File.join(user_dir, service)
      refute Hive::LlmWikiBootstrap::Scheduler.hive_managed_root?(project)
      File.write(File.join(project, ".llm-wiki", "config.json"), "[]\n")
      refute Hive::LlmWikiBootstrap::Scheduler.hive_managed_root?(project)
      refute Hive::LlmWikiBootstrap::Scheduler.hive_managed_root?(File.join(root, "missing"))

      missing_service = "llm-wiki-missing-external.service"
      write_legacy_unit(user_dir, missing_service, "/opt/missing-llm-wiki-project")
      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }
      assert_path_exists File.join(user_dir, missing_service)
    end
  end

  def test_reconcile_skips_a_unit_that_becomes_unreadable_during_scan
    with_tmp_dir do |root|
      home = File.join(root, "home")
      user_dir = File.join(home, ".config", "systemd", "user")
      service = File.join(user_dir, "llm-wiki-raced.service")
      FileUtils.mkdir_p(user_dir)
      File.write(service, "placeholder\n")
      original_read = File.method(:read)
      raced_read = lambda do |path, *args, **kwargs|
        raise Errno::EACCES, path if path == service

        original_read.call(path, *args, **kwargs)
      end

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) do
        with_replaced_singleton_method(File, :read, raced_read) do
          Hive::LlmWikiBootstrap::Scheduler.reconcile_existing!
        end
      end

      assert_path_exists service
    end
  end

  def test_reconcile_skips_an_orphan_timer_that_becomes_unreadable_during_scan
    with_tmp_dir do |root|
      home = File.join(root, "home")
      user_dir = File.join(home, ".config", "systemd", "user")
      timer = File.join(user_dir, "llm-wiki-raced.timer")
      FileUtils.mkdir_p(user_dir)
      File.write(timer, "[Unit]\nX-HiveManaged=yes\n")
      original_read = File.method(:read)
      raced_read = lambda do |path, *args, **kwargs|
        raise Errno::EACCES, path if path == timer

        original_read.call(path, *args, **kwargs)
      end

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) do
        with_replaced_singleton_method(File, :read, raced_read) do
          Hive::LlmWikiBootstrap::Scheduler.reconcile_existing!
        end
      end

      assert_path_exists timer
    end
  end

  def test_write_if_changed_repairs_only_the_mode_when_contents_match
    with_tmp_dir do |root|
      path = File.join(root, "runner")
      File.write(path, "same\n")
      File.chmod(0o644, path)

      assert Hive::LlmWikiBootstrap::Scheduler.write_if_changed(
        path, "same\n", mode: 0o755
      )
      assert_equal 0o755, File.stat(path).mode & 0o777
      assert_equal "same\n", File.binread(path)
    end
  end

  def test_confirmed_hive_unit_with_broken_git_metadata_is_removed_fail_closed
    with_tmp_dir do |root|
      home = File.join(root, "home")
      project = File.join(root, "broken-project")
      user_dir = File.join(home, ".config", "systemd", "user")
      FileUtils.mkdir_p(File.join(project, ".llm-wiki"))
      FileUtils.mkdir_p(user_dir)
      File.write(File.join(project, ".llm-wiki", "config.json"), "{\"created_by\":\"hive\"}\n")
      service = "llm-wiki-broken-project.service"
      timer = service.sub(/\.service\z/, ".timer")
      write_legacy_unit(user_dir, service, project)
      File.write(File.join(user_dir, timer), "[Timer]\nPersistent=true\n")

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }

      refute_path_exists File.join(user_dir, service)
      refute_path_exists File.join(user_dir, timer)
    end
  end

  def test_reconcile_calls_systemctl_only_when_units_change
    with_scheduler_fixture do |home, main, _linked|
      fake_bin = File.join(home, "bin")
      calls = File.join(home, "systemctl-calls")
      FileUtils.mkdir_p(fake_bin)
      File.write(File.join(fake_bin, "systemctl"), <<~SH)
        #!/usr/bin/env bash
        printf '%s\n' "$*" >>#{calls}
      SH
      FileUtils.chmod("+x", File.join(fake_bin, "systemctl"))
      path = [ fake_bin, "/usr/bin", "/bin" ].join(File::PATH_SEPARATOR)
      env = {
        "HOME" => home,
        "PATH" => path,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => nil
      }

      with_env(env) { Hive::LlmWikiBootstrap::Scheduler.install(main) }
      first_calls = File.readlines(calls, chomp: true)
      assert_includes first_calls, "--user daemon-reload"
      assert first_calls.any? { |line| line.start_with?("--user stop llm-wiki-") }
      assert first_calls.any? { |line| line.start_with?("--user start llm-wiki-") }

      with_env(env) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }
      assert_equal first_calls, File.readlines(calls, chomp: true)
    end
  end

  def test_reconcile_preserves_an_intentionally_disabled_timer
    with_scheduler_fixture do |home, main, _linked|
      user_dir = File.join(home, ".config", "systemd", "user")
      FileUtils.mkdir_p(user_dir)
      service = "llm-wiki-disabled.service"
      timer = service.sub(/\.service\z/, ".timer")
      write_legacy_unit(user_dir, service, main)
      File.write(File.join(user_dir, timer), "[Timer]\nPersistent=true\n")

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }

      canonical = "llm-wiki-#{Hive::LlmWikiBootstrap::Scheduler.raw_project_slug(main)}.timer"
      canonical_service = canonical.sub(/\.timer\z/, ".service")
      assert_path_exists File.join(user_dir, canonical)
      assert_path_exists File.join(user_dir, canonical_service)
      refute_path_exists File.join(user_dir, service)
      refute_path_exists File.join(user_dir, timer)
      refute File.symlink?(File.join(user_dir, "timers.target.wants", canonical))
    end
  end

  def test_reconcile_removes_confirmed_legacy_test_unit_without_flock
    with_tmp_dir do |root|
      home = File.join(root, "home")
      user_dir = File.join(home, ".config", "systemd", "user")
      FileUtils.mkdir_p(user_dir)
      service = "llm-wiki-stale-test.service"
      timer = service.sub(/\.service\z/, ".timer")
      write_legacy_unit(user_dir, service, "/tmp/hive-web-test-deleted/repo")
      File.write(File.join(user_dir, timer), "[Timer]\nPersistent=true\n")

      with_env(
        "HOME" => home,
        "PATH" => "",
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }

      refute_path_exists File.join(user_dir, service)
      refute_path_exists File.join(user_dir, timer)
    end
  end

  def test_reconcile_removes_only_marked_orphan_timer
    with_tmp_dir do |root|
      home = File.join(root, "home")
      user_dir = File.join(home, ".config", "systemd", "user")
      FileUtils.mkdir_p(user_dir)
      marked = "llm-wiki-marked.timer"
      ambiguous = "llm-wiki-ambiguous.timer"
      File.write(File.join(user_dir, marked), "[Unit]\nX-HiveManaged=yes\n")
      File.write(File.join(user_dir, ambiguous), "[Timer]\nPersistent=true\n")

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }

      refute_path_exists File.join(user_dir, marked)
      assert_path_exists File.join(user_dir, ambiguous)
    end
  end

  def test_reconcile_removes_e2e_service_even_when_its_timer_is_already_missing
    with_tmp_dir do |root|
      home = File.join(root, "home")
      user_dir = File.join(home, ".config", "systemd", "user")
      fake_bin = File.join(home, "bin")
      calls = File.join(home, "systemctl-calls")
      FileUtils.mkdir_p(user_dir)
      FileUtils.mkdir_p(fake_bin)
      service = "llm-wiki-architecture-94f974d5.service"
      write_legacy_unit(user_dir, service, "/tmp/e2e-runs20260721-1589510-iozxyy/repos/architecture")
      File.write(File.join(fake_bin, "systemctl"), <<~SH)
        #!/bin/sh
        printf '%s\n' "$*" >>#{calls}
        case "$*" in *disable*) exit 1;; esac
      SH
      FileUtils.chmod("+x", File.join(fake_bin, "systemctl"))

      with_env(
        "HOME" => home,
        "PATH" => fake_bin,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => nil
      ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }

      refute_path_exists File.join(user_dir, service)
      calls_made = File.readlines(calls, chomp: true)
      refute calls_made.any? { |line| line.include?("disable") }
      assert_includes calls_made, "--user stop #{service}"
      assert_includes calls_made, "--user daemon-reload"
      refute Hive::LlmWikiBootstrap::Scheduler.known_hive_test_root?("/tmp/e2e-runtime-production")
    end
  end

  def test_systemctl_failure_leaves_durable_retry_marker
    with_scheduler_fixture do |home, main, _linked|
      fake_bin = File.join(home, "bin")
      FileUtils.mkdir_p(fake_bin)
      File.write(File.join(fake_bin, "systemctl"), "#!/usr/bin/env bash\nexit 1\n")
      FileUtils.chmod("+x", File.join(fake_bin, "systemctl"))

      _out, err = capture_io do
        with_env(
          "HOME" => home,
          "PATH" => [ fake_bin, "/usr/bin", "/bin" ].join(File::PATH_SEPARATOR),
          "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
          "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => nil
        ) { Hive::LlmWikiBootstrap::Scheduler.install(main) }
      end
      assert_match(/could not activate LLM-wiki scheduler/, err)
      assert_path_exists File.join(home, ".config", "systemd", "user", ".hive-llm-wiki-reconcile-pending")

      error = assert_raises(RuntimeError) do
        with_env(
          "HOME" => home,
          "PATH" => [ fake_bin, "/usr/bin", "/bin" ].join(File::PATH_SEPARATOR),
          "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
          "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => nil
        ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }
      end
      assert_match(/systemctl --user stop/, error.message)
    end
  end

  def test_resolution_failures_are_fail_closed
    scheduler = Hive::LlmWikiBootstrap::Scheduler
    failed = Struct.new(:success?).new(false)
    with_replaced_singleton_method(Open3, :capture3, ->(*) { [ "", "failed", failed ] }) do
      assert_nil scheduler.scheduled_project_root("/tmp/project")
    end
    with_replaced_singleton_method(Open3, :capture3, ->(*) { raise Errno::ENOENT }) do
      assert_nil scheduler.scheduled_project_root("/tmp/project")
    end
    assert_match(/project-/, scheduler.project_slug("/tmp/project"))
  end

  def test_missing_flock_and_non_linux_do_not_install_units
    with_scheduler_fixture do |home, project, _linked|
      fake_bin = File.join(home, "git-only-bin")
      FileUtils.mkdir_p(fake_bin)
      git_path = Hive::LlmWikiBootstrap::Scheduler.executable_path("git")
      File.symlink(git_path, File.join(fake_bin, "git"))
      original_os = RbConfig::CONFIG["host_os"]
      with_env(
        "HOME" => home,
        "PATH" => fake_bin,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) do
        assert_raises(ArgumentError) do
          Hive::LlmWikiBootstrap::Scheduler.systemd_service(project, "llm-wiki-test.service")
        end
        Hive::LlmWikiBootstrap::Scheduler.install(project)
        refute Dir.exist?(File.join(home, ".config", "systemd")),
               "Linux installation without flock must fail closed"
        RbConfig::CONFIG["host_os"] = "darwin"
        Hive::LlmWikiBootstrap::Scheduler.install(project)
      ensure
        RbConfig::CONFIG["host_os"] = original_os
      end
      refute Dir.exist?(File.join(home, ".config", "systemd"))
    end
  end

  def test_systemd_path_round_trip_and_missing_systemctl_are_safe
    scheduler = Hive::LlmWikiBootstrap::Scheduler
    path = '/tmp/a path/with"quote\\slash'
    assert_equal path, scheduler.decode_systemd_path(scheduler.systemd_path(path))
    with_env("PATH" => "", "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => nil) do
      refute scheduler.run_systemctl("daemon-reload")
    end
  end

  def test_systemctl_recovers_a_missing_headless_bus_address
    with_tmp_dir do |root|
      fake_bin = File.join(root, "bin")
      runtime_dir = File.join(root, "runtime")
      calls = File.join(root, "systemctl-calls")
      FileUtils.mkdir_p(fake_bin)
      FileUtils.mkdir_p(runtime_dir)
      bus_path = File.join(runtime_dir, "bus")
      bus = UNIXServer.new(bus_path)
      File.write(File.join(fake_bin, "systemctl"), <<~SH)
        #!/bin/sh
        printf '%s|%s|%s\n' "$XDG_RUNTIME_DIR" "$DBUS_SESSION_BUS_ADDRESS" "$*" >>#{calls}
      SH
      FileUtils.chmod("+x", File.join(fake_bin, "systemctl"))

      with_env(
        "PATH" => fake_bin,
        "XDG_RUNTIME_DIR" => runtime_dir,
        "DBUS_SESSION_BUS_ADDRESS" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => nil
      ) do
        assert Hive::LlmWikiBootstrap::Scheduler.run_systemctl("daemon-reload")
      end

      assert_equal "#{runtime_dir}|unix:path=#{bus_path}|--user daemon-reload\n", File.read(calls)
    ensure
      bus&.close
    end
  end

  private

  def with_scheduler_fixture
    with_tmp_dir do |root|
      home = File.join(root, "home")
      main = File.join(root, "main repo")
      linked = File.join(root, "linked repo")
      FileUtils.mkdir_p(home)
      run_git("init", "-q", "-b", "main", main)
      run_git("-C", main, "config", "user.email", "test@example.com")
      run_git("-C", main, "config", "user.name", "Hive Test")
      FileUtils.mkdir_p(File.join(main, ".llm-wiki"))
      File.write(File.join(main, ".llm-wiki", "config.json"), "{\"created_by\":\"hive\"}\n")
      File.write(File.join(main, ".llm-wiki", "refresh-wiki.sh"), "#!/bin/sh\n")
      File.write(File.join(main, "README.md"), "# fixture\n")
      run_git("-C", main, "add", ".")
      run_git("-C", main, "commit", "-qm", "init")
      run_git("-C", main, "worktree", "add", "-q", "-b", "feature", linked)
      yield home, main, linked
    ensure
      run_git("-C", main, "worktree", "remove", "--force", linked) \
        if main && linked && Dir.exist?(linked)
    end
  end

  def write_legacy_unit(user_dir, service_name, project_root)
    encoded_root = Hive::LlmWikiBootstrap::Scheduler.systemd_path(project_root)
    File.write(File.join(user_dir, service_name), <<~UNIT)
      [Unit]
      Description=Refresh LLM wiki for #{service_name.sub(/\.service\z/, "")}
      [Service]
      WorkingDirectory=#{encoded_root}
      ExecStart=/usr/bin/flock --nonblock #{encoded_root}/.llm-wiki/refresh-wiki.sh
    UNIT
  end

  def run_git(*argv)
    system("git", *argv, out: File::NULL, err: File::NULL, exception: true)
  end


  def scheduler_path(path)
    Hive::LlmWikiBootstrap::Scheduler.systemd_path(path)
  end
end
