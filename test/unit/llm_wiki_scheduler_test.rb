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
      encoded_main = historical_word(main)
      encoded_linked = historical_word(linked)
      assert_includes service, "WorkingDirectory=#{main}"
      assert_includes service, "MemoryMax=4G"
      assert_includes service, "MemorySwapMax=0"
      assert_includes service, "X-HiveManaged=yes"
      assert_includes service, "Environment=LLM_WIKI_GLOBAL_LOCK_HELD=1"
      shared_runner = File.join(main, ".git", "llm-wiki", "post-commit-refresh.sh")
      assert_includes service, "ConditionFileIsExecutable=#{shared_runner}"
      assert_includes service, "#{historical_word(shared_runner)} --project #{encoded_main} --drain"
      assert File.executable?(shared_runner)
      assert_equal File.basename(services.first),
                   File.read(File.join(main, ".git", "llm-wiki", "scheduler-service")).strip
      refute_includes service, encoded_linked
    end
  end

  def test_service_preserves_literal_directives_and_encodes_each_command_word
    [
      [ "wiki test", "wiki test", 'wiki\x20test' ],
      [ '\x20\x22\x41', '\x20\x22\x41', '\x5cx20\x5cx22\x5cx41' ],
      [ "a\\\\b'\"", "a\\\\b'\"", 'a\x5c\x5cb\x27\x22' ],
      [ "%t%%$$${NAME}é", "%%t%%%%$$${NAME}é", "%%t%%%%$$${NAME}é" ],
      [ "a\tb", "a\tb", 'a\x09b' ]
    ].each do |name, directive, word|
      unit = Hive::LlmWikiBootstrap::Scheduler.systemd_service(
        "/tmp/#{name}", "probe.service", flock_path: "/bin/fl%ock"
      ).lines(chomp: true)
      assert_includes unit, "X-HivePathEncoding=literal-v1"
      assert_includes unit, "WorkingDirectory=/tmp/#{directive}"
      assert_includes unit, "ConditionFileIsExecutable=/tmp/#{directive}/.llm-wiki/refresh-wiki.sh"
      assert_includes unit, "ExecStart=:/bin/fl%%ock --nonblock --conflict-exit-code 0 " \
                            "%t/llm-wiki-refresh.lock /tmp/#{word}/.llm-wiki/refresh-wiki.sh --project /tmp/#{word} --drain"
    end
  end

  def test_unrepresentable_roots_fail_before_installation
    with_tmp_dir do |root|
      home = File.join(root, "home")
      [ "nul\0", "line\nbreak", "cr\r", "bad\xff", "end\\", "end ", "end\t" ].each do |name|
        project = "#{root}/#{name}"
        assert_raises(ArgumentError) do
          Hive::LlmWikiBootstrap::Scheduler.systemd_service(project, "probe.service")
        end
        next if name.include?("\0")

        run_git("init", "-q", project)
        FileUtils.mkdir_p(File.join(project, ".llm-wiki"))
        File.write(File.join(project, ".llm-wiki/config.json"), '{"created_by":"hive"}')
        with_env("HOME" => home, "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil) do
          capture_io { Hive::LlmWikiBootstrap::Scheduler.install(project) }
        end
        refute_path_exists File.join(project, ".git/llm-wiki")
        refute_path_exists home
      end
    end
  end

  def test_both_shared_runtime_writers_preserve_git_common_directory_trailing_space
    with_tmp_dir do |root|
      common = File.join(root, "metadata ")
      sibling = common.rstrip
      project = File.join(root, "wiki test")
      run_git("init", "-q", "--separate-git-dir", common, project)
      FileUtils.mkdir_p(sibling)
      assert_equal common, Hive::LlmWikiBootstrap.git_common_dir(project)
      Hive::LlmWikiBootstrap.install!(project, scheduler: false)
      assert File.executable?(File.join(common, "llm-wiki/post-commit-refresh.sh"))
      assert_empty Dir.children(sibling)
      with_env("HOME" => root, "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil, "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1") do
        Hive::LlmWikiBootstrap::Scheduler.install(project)
      end
      service = File.read(Dir[File.join(root, ".config/systemd/user/*.service")].fetch(0))
      assert_includes service, "WorkingDirectory=#{project}\n"
      assert_includes service, "ConditionFileIsExecutable=#{common}/llm-wiki/post-commit-refresh.sh\n"
      assert_includes service, "#{sibling}\\x20/llm-wiki/post-commit-refresh.sh --project "
      assert_empty Dir.children(sibling)
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
      write_legacy_timer(user_dir, legacy_service)
      File.symlink(File.join("..", legacy_timer), File.join(wants_dir, legacy_timer))

      stale_service = service_for("/tmp/hive-test-deleted-project")
      write_legacy_unit(user_dir, stale_service, "/tmp/hive-test-deleted-project")
      write_legacy_timer(user_dir, stale_service)

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
      original_read = File.method(:binread)
      raced_read = lambda do |path, *args, **kwargs|
        raise Errno::EACCES, path if path == service

        original_read.call(path, *args, **kwargs)
      end

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) do
        with_replaced_singleton_method(File, :binread, raced_read) do
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
      original_read = File.method(:binread)
      raced_read = lambda do |path, *args, **kwargs|
        raise Errno::EACCES, path if path == timer

        original_read.call(path, *args, **kwargs)
      end

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) do
        with_replaced_singleton_method(File, :binread, raced_read) do
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
      service = service_for(project)
      timer = service.sub(/\.service\z/, ".timer")
      write_legacy_unit(user_dir, service, project)
      write_legacy_timer(user_dir, service)

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
      service = service_for(main)
      timer = service.sub(/\.service\z/, ".timer")
      write_legacy_unit(user_dir, service, main)
      write_legacy_timer(user_dir, service)

      with_env(
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil,
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1"
      ) { Hive::LlmWikiBootstrap::Scheduler.reconcile_existing! }

      canonical = "llm-wiki-#{Hive::LlmWikiBootstrap::Scheduler.raw_project_slug(main)}.timer"
      canonical_service = canonical.sub(/\.timer\z/, ".service")
      assert_path_exists File.join(user_dir, canonical)
      assert_path_exists File.join(user_dir, canonical_service)
      assert_includes File.read(File.join(user_dir, service)), "X-HivePathEncoding=literal-v1"
      refute File.symlink?(File.join(user_dir, "timers.target.wants", canonical))
    end
  end

  def test_reconcile_removes_confirmed_legacy_test_unit_without_flock
    with_tmp_dir do |root|
      home = File.join(root, "home")
      user_dir = File.join(home, ".config", "systemd", "user")
      FileUtils.mkdir_p(user_dir)
      service = service_for("/tmp/hive-web-test-deleted/repo")
      timer = service.sub(/\.service\z/, ".timer")
      write_legacy_unit(user_dir, service, "/tmp/hive-web-test-deleted/repo")
      write_legacy_timer(user_dir, service)

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
      File.write(File.join(user_dir, marked), "[Unit]\nX-HiveManaged=yes\n[Timer]\nUnit=llm-wiki-marked.service\n")
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
      service = service_for("/tmp/e2e-runs20260721-1589510-iozxyy/repos/architecture")
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

  def test_foreign_runner_and_mismatched_service_name_are_preserved
    with_scheduler_fixture do |home, main, linked|
      with_env("HOME" => home, "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil, "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1") do
        user_dir = File.join(home, ".config/systemd/user")
        FileUtils.mkdir_p(user_dir)
        service = service_for(main)
        path = File.join(user_dir, service)
        write_legacy_unit(user_dir, service, main)
        bytes = File.read(path).sub("ExecStart=#{historical_word(main)}", "ExecStart=#{historical_word(linked)}")
        File.write(path, bytes)
        foreign = "llm-wiki-foreign.service"
        write_legacy_unit(user_dir, foreign, linked)
        Hive::LlmWikiBootstrap::Scheduler.reconcile_existing!
        assert_equal bytes, File.read(path)
        assert_path_exists File.join(user_dir, foreign)
        refute_path_exists File.join(main, ".git/llm-wiki")
      end
    end
  end

  def test_current_and_both_unmarked_grammars_prove_exact_root_and_converge_after_an_older_writer
    with_scheduler_sandbox do |root, units, calls|
      names = [ 'project\x20literal', "project literal", 'a"b', "a\\\\b", 'x\x41', "raw %t café", "plain" ]
      names.each_with_index do |basename, index|
        project = File.join(root, basename)
        seed_project(project)
        name = service_for(project)
        path, _, link = Scheduler.unit_paths(units, name)
        historical = historical_service(project, raw: [ 0, 4, 5 ].include?(index))
        File.write(path, historical)
        expected = [ 1, 2, 3 ].include?(index) ? :proven_legacy : :proven_unversioned_literal
        proof = Scheduler.classify_service(path, Scheduler.executable_path("flock"))
        assert_equal [ expected, project ], [ proof.disposition, proof.root ]
        write_legacy_timer(units, name)
        File.symlink("../#{File.basename(link)}", link) if index.even?
      end

      names.each do |basename|
        project = File.join(root, basename)
        File.write(File.join(project, "sentinel"), basename)
      end
      Scheduler.reconcile_existing!
      migrated = snapshot_scheduler(root)
      names.each_with_index do |basename, index|
        project = File.join(root, basename)
        path, _, link = Scheduler.unit_paths(units, service_for(project))
        assert_equal project, Scheduler.classify_service(path, Scheduler.executable_path("flock")).root
        assert_includes File.read(path), "WorkingDirectory=#{project.gsub('%', '%%')}\n"
        assert_equal index.even?, File.symlink?(link)
        assert_equal basename, File.read(File.join(project, "sentinel"))
      end
      Scheduler.reconcile_existing!
      assert_equal migrated, snapshot_scheduler(root)
      project = File.join(root, names.first)
      path = File.join(units, service_for(project))
      expected = File.binread(path)
      File.write(path, historical_service(project, raw: true))
      prior = calls.size
      Scheduler.install(project)
      assert_equal expected, File.binread(path)
      assert_operator calls.size, :>, prior
      after_restore = snapshot_scheduler(root)
      Scheduler.install(project)
      assert_equal after_restore, snapshot_scheduler(root)
    end
  end

  def test_unresolved_service_evidence_preserves_every_artifact_including_pending_intent
    with_scheduler_sandbox do |root, units, calls|
      project = File.join(root, "mismatch root")
      seed_project(project)
      service = service_for(project)
      path, _, link = Scheduler.unit_paths(units, service)
      write_legacy_timer(units, service)
      File.symlink("../#{File.basename(link)}", link)
      File.write(File.join(units, Scheduler::PENDING), "earlier intent\n")
      original = historical_service(project)
      [
        original.sub(/^WorkingDirectory=.*\n/, ""),
        original.sub(/^WorkingDirectory=.*$/, "\\0\n\\0"),
        original.sub("ConditionFileIsExecutable=/", "ConditionFileIsExecutable=/wrong"),
        original.sub(" --project /", " --project /wrong"),
        original.sub("lock /", "lock /wrong"),
        original.sub("X-HiveManaged=yes", "X-HiveManaged=yes\nX-HivePathEncoding=unknown"),
        original.sub("Description=", "Description=wrong"),
        original.b + "\xff".b
      ].each do |bytes|
        File.binwrite(path, bytes)
        before = snapshot_scheduler(root)
        Scheduler.reconcile_existing!
        Scheduler.install(project)
        assert_equal before, snapshot_scheduler(root)
        assert_empty calls
      end
      File.write(path, original)
      config = File.join(project, ".llm-wiki/config.json")
      [ '{"created_by":"other"}', %({"created_by":"hive","extra":"\xff"}).b ].each do |bytes|
        File.binwrite(config, bytes)
        before = snapshot_scheduler(root)
        Scheduler.reconcile_existing!
        assert_equal before, snapshot_scheduler(root)
        assert_empty calls
      end
    end
  end

  def test_direct_install_and_linked_migration_preserve_occupied_destinations
    with_scheduler_sandbox do |root, units, calls|
      project = File.join(root, "primary")
      linked = File.join(root, "linked")
      seed_project(project)
      run_git("-C", project, "add", ".")
      run_git("-C", project, "-c", "user.email=test@example.org", "-c", "user.name=Test", "commit", "-qm", "seed")
      run_git("-C", project, "worktree", "add", "-qb", "linked", linked)
      source = service_for(linked)
      write_legacy_unit(units, source, linked)
      name = service_for(project)
      service, timer, link = Scheduler.unit_paths(units, name)
      shared = File.join(project, ".git/llm-wiki")
      FileUtils.mkdir_p(shared)
      record = File.join(shared, "scheduler-service")
      File.write(record, "#{name}\n")
      [
        [ service, "foreign contents\n" ],
        [ service, historical_service(project).sub(" --project /", " --project /wrong") ],
        [ timer, "[Unit]\nX-HiveManaged=yes\n[Timer]\nUnit=foreign.service\n" ],
        [ timer, "\xff".b ],
        [ link, "regular file" ],
        [ link, :foreign_link ],
        [ link, :dangling ],
        [ record, "unrelated.service\n" ]
      ].each do |path, contents|
        case contents
        when :foreign_link then File.symlink(record, path)
        when :dangling then File.symlink("../#{File.basename(timer)}", path)
        else File.binwrite(path, contents)
        end
        before = snapshot_scheduler(root)
        Scheduler.reconcile_existing!
        Scheduler.install(linked)
        assert_equal before, snapshot_scheduler(root), path
        assert_empty calls
        File.unlink(path)
      end
      File.write(record, "#{name}\n")
      Scheduler.reconcile_existing!
      assert_path_exists service
      refute_path_exists File.join(units, source)
      refute File.symlink?(link)
      before = snapshot_scheduler(root)
      Scheduler.install(linked)
      assert_equal before, snapshot_scheduler(root)
      # Reappearing enabled linked units respect the disabled primary.
      write_legacy_unit(units, source, linked)
      write_legacy_timer(units, source)
      source_link = Scheduler.unit_paths(units, source).last
      File.symlink("../#{File.basename(source_link)}", source_link)
      Scheduler.reconcile_existing!
      refute File.symlink?(link)
      refute File.symlink?(source_link)
      File.symlink("../#{File.basename(timer)}", link)
      write_legacy_unit(units, source, linked)
      Scheduler.reconcile_existing!
      assert File.symlink?(link)
      before = snapshot_scheduler(root)
      Scheduler.install(project)
      assert_equal before, snapshot_scheduler(root)
    end
  end

  def test_disputed_linked_source_protects_a_marked_primary_timer_from_orphan_cleanup
    with_scheduler_fixture do |home, main, linked|
      with_env("HOME" => home, "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil, "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1") do
        units = Scheduler.systemd_user_dir
        FileUtils.mkdir_p(File.join(units, "timers.target.wants"))
        name = service_for(linked)
        write_legacy_unit(units, name, linked)
        source = File.join(units, name)
        File.write(source, File.read(source).sub("ExecStart=/", "ExecStart=/wrong/"))
        _, timer, link = Scheduler.unit_paths(units, service_for(main))
        File.write(timer, Scheduler.systemd_timer(service_for(main)))
        File.symlink("../#{File.basename(timer)}", link)
        before = snapshot_scheduler(home)
        Scheduler.reconcile_existing!
        Scheduler.install(linked)
        Scheduler.install(main)
        assert_equal before, snapshot_scheduler(home)
        refute_path_exists File.join(main, ".git/llm-wiki")
      end
    end
  end

  def test_malformed_stored_bytes_and_unrepresentable_legacy_root_do_not_block_independent_migration
    with_scheduler_sandbox do |root, units, calls|
      bad_root = File.join(root, "a-invalid")
      space_root = File.join(root, "b-trailing ")
      good_root = File.join(root, "z-good")
      [ bad_root, space_root, good_root ].each do |project|
        seed_project(project)
        name = service_for(project)
        write_legacy_unit(units, name, project)
        write_legacy_timer(units, name)
        _, _, link = Scheduler.unit_paths(units, name)
        File.symlink("../#{File.basename(link)}", link)
      end
      bad_path = File.join(units, service_for(bad_root))
      File.binwrite(bad_path, File.binread(bad_path) + "\xff".b)
      before = snapshot_scheduler(root)
      Scheduler.reconcile_existing!
      after = snapshot_scheduler(root)
      [ bad_root, space_root ].each do |project|
        name = service_for(project)
        assert_equal before.select { |p, _| p.include?(name.delete_suffix(".service")) },
                     after.select { |p, _| p.include?(name.delete_suffix(".service")) }
        refute_path_exists File.join(project, ".git/llm-wiki")
        refute calls.flatten.any? { |call| call.include?(name.delete_suffix(".service")) }
      end
      assert_includes File.read(File.join(units, service_for(good_root))), "X-HivePathEncoding=literal-v1"
    end
  end

  def test_retry_after_service_replacement_and_after_removal
    with_scheduler_sandbox do |root, units, calls|
      project = File.join(root, "project")
      seed_project(project)
      Scheduler.install(project)
      name = service_for(project)
      path, timer, = Scheduler.unit_paths(units, name)
      marker = File.join(units, Scheduler::PENDING)
      File.write(path, historical_service(project))
      rename = File.method(:rename)
      interrupted = lambda do |from, to|
        rename.call(from, to)
        raise IOError, "interrupted after service replacement" if to == path
      end
      calls.clear
      with_replaced_singleton_method(File, :rename, interrupted) do
        assert_raises(IOError) { Scheduler.reconcile_existing! }
      end
      assert_path_exists marker
      assert_empty calls
      assert_includes File.read(path), "X-HivePathEncoding=literal-v1"
      Scheduler.reconcile_existing!
      expected = [ [ "stop", name ], [ "daemon-reload" ], [ "start", File.basename(timer) ] ]
      assert_equal expected, calls
      refute_path_exists marker
      Scheduler.reconcile_existing!
      assert_equal expected, calls

      FileUtils.remove_entry(File.join(project, ".git"))
      fail_reload = lambda { |*args| raise "interrupted" if args == [ "daemon-reload" ] }
      with_replaced_singleton_method(Scheduler, :run_systemctl!, fail_reload) do
        assert_raises(RuntimeError) { Scheduler.reconcile_existing! }
      end
      refute_path_exists path
      assert_path_exists marker
      calls.clear
      Scheduler.reconcile_existing!
      assert_equal [ [ "daemon-reload" ] ], calls
      refute_path_exists marker
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

  def test_missing_systemctl_is_safe
    scheduler = Hive::LlmWikiBootstrap::Scheduler
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

  Scheduler = Hive::LlmWikiBootstrap::Scheduler

  def seed_project(root)
    run_git("init", "-q", root)
    FileUtils.mkdir_p(File.join(root, ".llm-wiki"))
    File.write(File.join(root, ".llm-wiki/config.json"), '{"created_by":"hive"}')
  end

  def with_scheduler_sandbox
    with_tmp_dir do |root|
      units = File.join(root, ".config/systemd/user")
      FileUtils.mkdir_p(File.join(units, "timers.target.wants"))
      calls = []
      with_env("HOME" => root, "HIVE_SKIP_LLM_WIKI_SCHEDULER" => nil) do
        with_replaced_singleton_method(Scheduler, :run_systemctl, ->(*args) { calls << args }) do
          yield root, units, calls
        end
      end
    end
  end

  def snapshot_scheduler(root)
    paths = Dir.glob(File.join(root, "{.config/systemd/user,*/.git/llm-wiki}/**/*"), File::FNM_DOTMATCH)
    paths.reject { |path| File.directory?(path) && !File.symlink?(path) }.to_h do |path|
      stat = File.lstat(path)
      [ path, [ stat.mode, stat.mtime, stat.symlink? ? File.readlink(path) : Digest::SHA256.file(path).hexdigest ] ]
    end
  end

  def historical_service(project, raw: false)
    name = service_for(project)
    runner = File.join(project, ".git/llm-wiki/post-commit-refresh.sh")
    <<~UNIT
      [Unit]
      Description=Refresh LLM wiki for #{name.delete_suffix(".service")}
      X-HiveManaged=yes
      ConditionFileIsExecutable=#{raw ? runner : historical_word(runner)}

      [Service]
      Type=oneshot
      Environment=LLM_WIKI_GLOBAL_LOCK_HELD=1
      WorkingDirectory=#{raw ? project : historical_word(project)}
      ExecStart=#{historical_word(Scheduler.executable_path("flock"))} --nonblock --conflict-exit-code 0 %t/llm-wiki-refresh.lock #{historical_word(runner)} --project #{historical_word(project)} --drain
      TimeoutStartSec=4h
      MemoryMax=4G
      MemorySwapMax=0
    UNIT
  end

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
    encoded_root = historical_word(project_root)
    File.write(File.join(user_dir, service_name), <<~UNIT)
      [Unit]
      Description=Refresh LLM wiki for #{service_name.sub(/\.service\z/, "")}
      [Service]
      WorkingDirectory=#{encoded_root}
      ExecStart=#{encoded_root}/.llm-wiki/refresh-wiki.sh
    UNIT
  end

  def run_git(*argv)
    system("git", *argv, out: File::NULL, err: File::NULL, exception: true)
  end


  def historical_word(path)
    path.gsub(/[ "\\]/) { |char| format("\\x%02x", char.ord) }
  end

  def service_for(root)
    basename = File.basename(root).gsub(/[^A-Za-z0-9_.-]/, "-")
    "llm-wiki-#{basename}-#{Digest::SHA256.hexdigest(root)[0, 8]}.service"
  end

  def write_legacy_timer(user_dir, service)
    File.write(File.join(user_dir, service.sub(/\.service\z/, ".timer")), <<~UNIT)
      [Unit]
      Description=Run #{service} daily
      [Timer]
      OnActiveSec=10min
      OnUnitActiveSec=1d
      Unit=#{service}
      [Install]
      WantedBy=timers.target
    UNIT
  end
end
