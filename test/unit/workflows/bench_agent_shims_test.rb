require "test_helper"
require "json"
require "open3"
require "hive/workflows/bench"

class WorkflowsBenchAgentShimsTest < Minitest::Test
  RUNTIME = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness", "lib")
  MANAGED_NAMES = %w[codex pi grok].freeze
  FIXED_ROOTS = %w[/work /opt/hb /home/asterio /opt/compound-engineering /hive_resume_execute.sh].freeze

  # Only filesystem roots are adapted. The caller's branches, PATH handling,
  # cleanup and exit propagation all execute unchanged.
  def with_caller
    Dir.mktmpdir("hive-bench-agent-shims", "/tmp") do |root|
      paths = FIXED_ROOTS.zip(%w[target runtime user ce execute-resume.sh].map { |name| File.join(root, name) }).to_h
      fixture = { root: root, work: paths.fetch("/work"), bin: File.join(paths.fetch("/work"), ".hb/bin") }
      fixture[:script] = File.join(root, "stages.sh")
      fixture[:resume] = paths.fetch("/hive_resume_execute.sh")
      fixture[:launcher] = File.join(root, "pi-launcher.sh")
      { "hive_stages.sh" => fixture[:script], "hive_resume_execute.sh" => fixture[:resume],
        "pi_bench_launcher.sh" => fixture[:launcher] }.each do |source, destination|
        File.write(destination, File.read(File.join(RUNTIME, source)).gsub(Regexp.union(FIXED_ROOTS), paths))
      end
      assert_rebased(fixture)
      File.chmod(0o755, fixture[:launcher])

      FileUtils.mkdir_p([ fixture[:bin], paths.fetch("/home/asterio"), File.join(root, "real-bin") ])
      fixture[:env] = {
        "PATH" => "#{fixture[:bin]}:#{root}/real-bin:/usr/bin:/bin",
        "SHIM_FIXTURE" => root, "SHIM_AGENT" => "codex",
        "HB_HIVE_VERSION" => "fixture-hive", "HB_REVIEW" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1",
        "HB_PI_REAL_BIN" => File.join(root, "real-bin/pi"),
        "HB_PI_TOOL_STREAM" => File.join(root, "extension.ts")
      }
      fixture[:env]["HIVE_PI_BIN"] = fixture[:launcher]
      write_executable(File.join(paths.fetch("/opt/hb"), "hive-current/bin/hive"), HIVE_STUB)
      MANAGED_NAMES.each { |name| write_executable(File.join(root, "real-bin", name), AGENT_STUB) }
      File.write(File.join(root, "extension.ts"), "// fixture\n")
      File.write(File.join(fixture[:work], "tracked.txt"), "base\n")
      git(fixture[:work], "init", "-q", "-b", "main")
      git(fixture[:work], "add", "tracked.txt")
      git(fixture[:work], "-c", "user.name=fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "base")
      fixture[:base] = git(fixture[:work], "rev-parse", "HEAD").strip
      git(root, "clone", "-q", "--local", fixture[:work], File.join(root, "candidate"))
      fixture[:task] = File.join(fixture[:work], ".hive-state/stages/3-plan/demo")
      FileUtils.mkdir_p(fixture[:task])
      File.write(File.join(fixture[:task], "task.md"), "task sentinel\n")
      File.write(File.join(fixture[:task], "worktree.yml"), {
        "path" => File.join(root, "candidate"), "execute_base_head" => fixture[:base]
      }.to_yaml)
      fixture[:preserved] = %w[.hb/keep .hb/saved.patch .worktrees/keep task-notes.md].to_h do |relative|
        path = File.join(fixture[:work], relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "sentinel #{relative}\n")
        [ path, File.binread(path) ]
      end
      fixture[:preserved][File.join(fixture[:task], "task.md")] = "task sentinel\n"
      %w[unrelated claude opencode].each do |name|
        path = File.join(fixture[:bin], name)
        write_executable(path, "#!/bin/sh\nexit 98\n")
        fixture[:preserved][path] = File.binread(path)
      end
      File.write(File.join(fixture[:bin], "gh"), "gh sentinel\n")
      yield fixture
    ensure
      FileUtils.chmod(0o755, fixture[:bin]) if fixture && File.directory?(fixture[:bin]) && !File.symlink?(fixture[:bin])
    end
  end

  def assert_rebased(fixture)
    [ fixture[:script], fixture[:resume], fixture[:launcher] ].each do |path|
      FIXED_ROOTS.each { |root| refute_includes File.read(path), root, "unrebased root in #{path}" }
    end
  end

  def write_executable(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.chmod(0o755, path)
  end

  def git(directory, *args)
    out, err, status = Open3.capture3({ "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1" },
                                    "/usr/bin/git", "-C", directory, *args)
    assert status.success?, out + err
    out
  end

  def run_caller(fixture, **env)
    assert_rebased(fixture)
    gh = File.join(fixture[:bin], "gh")
    gh_expected = File.file?(gh) ? File.read(gh) : nil
    out, err, status = Open3.capture3(
      fixture[:env].merge("SHIM_GH_EXPECTED" => gh_expected).merge(env.transform_keys(&:to_s)),
      "/usr/bin/timeout", "--kill-after=2", "20", *Array(fixture[:privilege_drop]),
      "/bin/bash", fixture[:script], "demo", fixture[:base], unsetenv_others: true
    )
    stage_err = File.join(fixture[:work], ".hb/stage.err")
    err += File.read(stage_err) if File.file?(stage_err)
    [ out, err, status ]
  end

  def calls(fixture)
    path = File.join(fixture[:root], "agents.jsonl")
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def assert_removed(fixture)
    MANAGED_NAMES.each { |name| assert_raises(Errno::ENOENT) { File.lstat(File.join(fixture[:bin], name)) } }
  end

  def assert_success(fixture, out, err, status, stages:, agents:)
    assert status.success?, out + err
    assert_includes out, "HB_DONE"
    assert_removed(fixture)
    assert_equal stages, calls(fixture).map { |call| call.fetch("argv").last(3).first }
    assert_equal agents, calls(fixture).map { |call| call.fetch("agent") }
    calls(fixture).each do |call|
      assert_equal [ "--label", "two words" ], call.fetch("argv").last(2)
      if call.fetch("agent") == "pi"
        assert_equal [ "--extension", File.join(fixture[:root], "extension.ts") ], call.fetch("argv").first(2)
      end
    end
    assert_preserved(fixture)
  end

  def assert_preflight_failure(fixture, out, err, status, diagnostic)
    assert_equal 4, status.exitstatus, out + err
    assert_includes err, "HB_ERROR #{diagnostic}"
    refute_includes out, "HB_DONE"
    assert_empty calls(fixture)
    refute_path_exists File.join(fixture[:root], "hive.jsonl")
    assert_preserved(fixture)
  end

  def assert_preserved(fixture)
    fixture[:preserved].each { |path, bytes| assert_equal bytes, File.binread(path), path }
    refute_path_exists File.join(fixture[:root], "stale-called")
  end

  def plant(fixture, name, kind)
    path = File.join(fixture[:bin], name)
    case kind
    when :regular
      write_executable(path, "#!/bin/sh\ntouch \"$SHIM_FIXTURE/stale-called\"\nexit 97\n")
    when :dangling
      File.symlink(File.join(fixture[:root], "missing-#{name}"), path)
    end
  end

  def test_wrappers_and_dangling_symlinks_are_removed_for_each_agent_and_reused_work_directory
    MANAGED_NAMES.product([ :regular, :dangling ]).each do |agent, kind|
      with_caller do |fixture|
        2.times do |iteration|
          MANAGED_NAMES.each { |name| plant(fixture, name, kind) }
          out, err, status = run_caller(fixture, SHIM_AGENT: agent)
          expected_stages = %w[plan develop review] * (iteration + 1)
          assert_success(fixture, out, err, status, stages: expected_stages, agents: [ agent ] * expected_stages.size)
          # --version observes gh after cleanup, before review is allowed to replace it.
          observations = File.readlines(File.join(fixture[:root], "gh-at-start.jsonl"))
          assert_equal iteration + 1, observations.size
          assert_equal "gh sentinel\n", JSON.parse(observations.first)
        end
      end
    end
  end

  def test_fresh_startup_without_managed_entries
    with_caller do |fixture|
      out, err, status = run_caller(fixture)
      assert_success(fixture, out, err, status, stages: %w[plan develop review], agents: %w[codex codex codex])
    end
  end

  def test_cleanup_preserves_targets_of_executable_symlinks
    with_caller do |fixture|
      MANAGED_NAMES.each do |name|
        target = File.join(fixture[:root], "external-#{name}")
        write_executable(target, "#!/bin/sh\nexit 97\n")
        fixture[:preserved][target] = File.binread(target)
        File.symlink(target, File.join(fixture[:bin], name))
      end
      out, err, status = run_caller(fixture)
      assert_success(fixture, out, err, status, stages: %w[plan develop review], agents: %w[codex codex codex])
      MANAGED_NAMES.each { |name| assert File.executable?(File.join(fixture[:root], "external-#{name}")) }
    end
  end

  def test_managed_directory_fails_without_recursive_deletion
    with_caller do |fixture|
      path = File.join(fixture[:bin], "pi")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "keep"), "directory sentinel\n")
      out, err, status = run_caller(fixture)
      assert_preflight_failure(fixture, out, err, status, "legacy_agent_shim_cleanup_failed")
      assert_includes err, "path=#{path}"
      assert_equal "directory sentinel\n", File.read(File.join(path, "keep"))
    end
  end

  def test_failed_mkdir_has_distinct_setup_diagnostic
    with_caller do |fixture|
      FileUtils.rm_r(fixture[:bin])
      File.write(fixture[:bin], "bin is a file\n")
      fixture[:preserved].reject! { |path, _| path.start_with?("#{fixture[:bin]}/") }
      out, err, status = run_caller(fixture)
      assert_preflight_failure(fixture, out, err, status, "controller_bin_setup_failed")
      refute_includes err, "legacy_agent_shim_cleanup_failed"
      assert_equal "bin is a file\n", File.read(fixture[:bin])
    end
  end

  def symlink_bin(fixture)
    external = File.join(fixture[:root], "external-bin")
    FileUtils.mv(fixture[:bin], external)
    fixture[:preserved] = fixture[:preserved].transform_keys { |path| path.sub("#{fixture[:bin]}/", "#{external}/") }
    File.symlink(external, fixture[:bin])
    external
  end

  def test_symlinked_bin_is_rejected_without_touching_external_directory
    with_caller do |fixture|
      MANAGED_NAMES.each { |name| plant(fixture, name, :regular) }
      external = symlink_bin(fixture)
      before = Dir.children(external).sort.to_h { |name| [ name, File.binread(File.join(external, name)) ] }
      out, err, status = run_caller(fixture)
      assert_preflight_failure(fixture, out, err, status, "controller_bin_setup_failed")
      assert File.symlink?(fixture[:bin])
      assert_equal before, Dir.children(external).sort.to_h { |name| [ name, File.binread(File.join(external, name)) ] }
    end
  end

  def test_replanted_wrapper_is_removed_before_execute
    %w[0 1].each do |review|
      with_caller do |fixture|
        out, err, status = run_caller(fixture, SHIM_AGENT: "codex", SHIM_REPLANT: "wrapper", HB_REVIEW: review)
        stages = review == "1" ? %w[plan develop review] : %w[plan develop]
        assert_success(fixture, out, err, status, stages: stages, agents: [ "codex" ] * stages.size)
        assert_path_exists File.join(fixture[:root], "replanted")
      end
    end
  end

  def test_replanted_wrapper_is_removed_before_review
    with_caller do |fixture|
      out, err, status = run_caller(fixture, SHIM_AGENT: "pi", SHIM_REVIEW_AGENT: "codex",
                                           SHIM_REPLANT: "wrapper", SHIM_REPLANT_STAGE: "develop")
      assert_success(fixture, out, err, status, stages: %w[plan develop review], agents: %w[pi pi codex])
      assert_path_exists File.join(fixture[:root], "replanted")
    end
  end

  def test_execute_and_review_revalidate_bin_and_removal_failures
    %w[plan develop].product(%w[symlink directory]).each do |replant_stage, kind|
      with_caller do |fixture|
        out, err, status = run_caller(fixture, SHIM_AGENT: "pi", SHIM_REPLANT: kind, SHIM_REPLANT_STAGE: replant_stage)
        assert_equal 4, status.exitstatus, out + err
        diagnostic = kind == "symlink" ? "controller_bin_setup_failed" : "legacy_agent_shim_cleanup_failed"
        assert_includes err, "HB_ERROR #{diagnostic}"
        stages = replant_stage == "plan" ? %w[plan] : %w[plan develop]
        assert_equal stages, calls(fixture).map { |call| call.fetch("argv").last(3).first }
        assert_preserved(fixture)
        assert_path_exists File.join(fixture[:bin], "codex")
        refute_includes out, "HB_STAGE develop" if replant_stage == "plan"
        refute_includes out, "HB_STAGE review"
      end
    end
  end

  def prepare_resume(fixture, stage)
    destination = File.join(fixture[:work], ".hive-state/stages/#{stage}/demo")
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.mv(fixture[:task], destination)
    bytes = fixture[:preserved].delete(File.join(fixture[:task], "task.md"))
    fixture[:task] = destination
    fixture[:preserved][File.join(destination, "task.md")] = bytes
  end

  def test_execute_resume_reaches_real_agent_after_cleanup
    with_caller do |fixture|
      prepare_resume(fixture, "4-execute")
      File.open(File.join(fixture[:task], "task.md"), "a") do |file|
        file.puts "<!-- ERROR reason=implementer_failed marker_id=fixture-marker -->"
      end
      MANAGED_NAMES.each { |name| plant(fixture, name, :regular) }
      out, err, status = run_caller(fixture, HB_RESUME_EXECUTE: "1", HB_RESUME_MARKER_ID: "fixture-marker")
      assert_success(fixture, out, err, status, stages: %w[develop review], agents: %w[codex codex])
      assert_includes out, "HB_NOTE execute_resumed"
      hive_calls = File.readlines(File.join(fixture[:root], "hive.jsonl")).map { |line| JSON.parse(line) }
      assert_includes hive_calls, [ "markers", "clear", fixture[:task], "--name", "ERROR", "--match-attr",
                                  "marker_id=fixture-marker,reason=implementer_failed", "--json" ]
    end
  end

  def test_review_resume_reaches_real_agent_after_cleanup
    with_caller do |fixture|
      prepare_resume(fixture, "6-review")
      File.write(File.join(fixture[:root], "candidate/tracked.txt"), "execute change\n")
      patch = git(File.join(fixture[:root], "candidate"), "diff", fixture[:base])
      File.write(File.join(fixture[:work], "candidate-execute.patch"), patch)
      fixture[:preserved][File.join(fixture[:work], "candidate-execute.patch")] = patch
      MANAGED_NAMES.each { |name| plant(fixture, name, :dangling) }
      out, err, status = run_caller(fixture, HB_RESUME_REVIEW: "1", SHIM_AGENT: "grok")
      assert_success(fixture, out, err, status, stages: %w[review], agents: %w[grok])
      assert_includes out, "HB_NOTE review_resumed"
    end
  end

  def test_cleanup_runs_when_review_is_disabled
    with_caller do |fixture|
      MANAGED_NAMES.each { |name| plant(fixture, name, :regular) }
      out, err, status = run_caller(fixture, HB_REVIEW: "0")
      assert_success(fixture, out, err, status, stages: %w[plan develop], agents: %w[codex codex])
    end
  end

  def test_cleanup_precedes_opencode_agent_preflight
    with_caller do |fixture|
      MANAGED_NAMES.each { |name| plant(fixture, name, :regular) }
      %w[ce-plan ce-work ce-code-review].each do |name|
        path = File.join(fixture[:root], "ce/skills", name, "SKILL.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "fixture skill\n")
      end
      preflight = File.join(fixture[:root], "opencode-preflight")
      write_executable(preflight, <<~'RUBY')
        #!/usr/bin/ruby
        require "json"
        root = ENV.fetch("SHIM_FIXTURE")
        %w[codex pi grok].each do |name|
          begin
            File.lstat(File.join(root, "target/.hb/bin", name))
            abort "stale shim before agent preflight"
          rescue Errno::ENOENT
          end
        end
        File.open(File.join(root, "preflight-calls"), "a") { |file| file.puts ARGV.join(" ") }
        names = %w[ce-plan ce-work ce-code-review] + 30.times.map { |n| "ce-fixture-#{n}" }
        payload = if ARGV == %w[debug config]
          { "skills" => { "paths" => [File.join(root, "ce/skills")] }, "command" => names.to_h { |name| [name, {}] } }
        elsif ARGV == %w[debug skill]
          names.map { |name| { "name" => name } }
        else
          abort "unexpected preflight argv"
        end
        puts JSON.generate(payload)
      RUBY
      out, err, status = run_caller(fixture, HB_OPENCODE_CE_PREFLIGHT: "1", HIVE_OPENCODE_BIN: preflight)
      assert_success(fixture, out, err, status, stages: %w[plan develop review], agents: %w[codex codex codex])
      assert_includes out, "HB_NOTE opencode_ce_skills enabled count=33"
      assert_equal [ "debug config", "debug skill" ], File.readlines(File.join(fixture[:root], "preflight-calls"), chomp: true)
    end
  end

  def test_real_unlink_denial_for_regular_and_dangling_entries_then_repair_and_retry
    [ :regular, :dangling ].each do |kind|
      with_caller do |fixture|
        plant(fixture, "codex", kind)
        # This guard must run before even the privilege fixture's chown/chmod.
        assert_rebased(fixture)
        if Process.euid.zero?
          assert File.executable?("/usr/bin/setpriv"), "root permission rows require Linux setpriv"
          fixture[:privilege_drop] = %w[/usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups]
          FileUtils.chown_R(65534, 65534, fixture[:root])
        end
        File.chmod(0o555, fixture[:bin])
        path = File.join(fixture[:bin], "codex")
        _, denial, denied = Open3.capture3(
          { "LC_ALL" => "C" },
          "/usr/bin/timeout", "5", *Array(fixture[:privilege_drop]), "/usr/bin/rm", "-f", "--", path
        )
        assert_equal 1, denied.exitstatus, "fixture must truly deny unlink: #{denial}"
        assert_includes denial, "Permission denied"
        assert_equal(kind == :dangling ? "link" : "file", File.lstat(path).ftype)
        out, err, status = run_caller(fixture)
        assert_preflight_failure(fixture, out, err, status, "legacy_agent_shim_cleanup_failed")
        assert_includes err, "path=#{path}"
        assert_equal(kind == :dangling ? "link" : "file", File.lstat(path).ftype)
        File.chmod(0o755, fixture[:bin])
        out, err, status = run_caller(fixture)
        assert_success(fixture, out, err, status, stages: %w[plan develop review], agents: %w[codex codex codex])
      end
    end
  end

  def test_removal_status_is_checked_directly_without_an_absence_reprobe
    script = File.read(File.join(RUNTIME, "hive_stages.sh"))
    cleanup = script[/^cleanup_legacy_agent_shims\(\) \{.*?^\}/m]
    refute_nil cleanup
    assert_match(/if ! \/usr\/bin\/rm -f -- "\$CONTROLLER_BIN\/\$name"; then/, cleanup)
    refute_match(/(?:\[|test\b).*\$CONTROLLER_BIN\/\$name/, cleanup)
  end

  AGENT_STUB = <<~'RUBY'
    #!/usr/bin/ruby
    require "json"
    File.open(File.join(ENV.fetch("SHIM_FIXTURE"), "agents.jsonl"), "a") do |file|
      file.puts JSON.generate("agent" => File.basename($0), "argv" => ARGV)
    end
  RUBY

  HIVE_STUB = <<~'RUBY'
    #!/usr/bin/ruby
    require "fileutils"
    require "json"
    if ARGV == ["--version"]
      root = ENV.fetch("SHIM_FIXTURE")
      gh = File.read(File.join(root, "target/.hb/bin/gh"))
      abort "cleanup changed gh" unless gh == ENV.fetch("SHIM_GH_EXPECTED")
      File.open(File.join(root, "gh-at-start.jsonl"), "a") { |file| file.puts JSON.generate(gh) }
      puts "fixture-hive"
      exit
    end
    root = ENV.fetch("SHIM_FIXTURE")
    work = File.join(root, "target")
    action = ARGV.fetch(0)
    File.open(File.join(root, "hive.jsonl"), "a") { |file| file.puts JSON.generate(ARGV) }
    if %w[plan develop review].include?(action)
      agent = action == "review" ? ENV.fetch("SHIM_REVIEW_AGENT", ENV.fetch("SHIM_AGENT")) : ENV.fetch("SHIM_AGENT")
      executable = agent == "pi" ? ENV.fetch("HIVE_PI_BIN") : agent
      abort "agent failed" unless system(executable, action, "--label", "two words")
    end
    case action
    when "plan"
      path = File.join(work, ".hive-state/stages/3-plan/demo")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "plan.md"), "fixture plan\n<!-- COMPLETE -->\n")
    when "develop", "review"
      File.write(File.join(root, "candidate/tracked.txt"), "#{action} change\n")
    when "open-pr"
      # Offline publication requires no agent.
    when "markers"
      abort "unexpected marker operation" unless ARGV[1] == "clear"
      path = File.join(ARGV.fetch(2), "task.md")
      File.write(path, File.read(path).lines.reject { |line| line.include?("<!-- ERROR ") }.join)
    else
      abort "unexpected hive invocation: #{ARGV.inspect}"
    end
    if ENV["SHIM_REPLANT"] && action == ENV.fetch("SHIM_REPLANT_STAGE", "plan")
      bin = File.join(work, ".hb/bin")
      case ENV.fetch("SHIM_REPLANT")
      when "wrapper"
        File.write(File.join(bin, "codex"), "#!/bin/sh\ntouch \"$SHIM_FIXTURE/stale-called\"\nexit 97\n")
        File.chmod(0o755, File.join(bin, "codex"))
      when "directory"
        FileUtils.mkdir_p(File.join(bin, "codex"))
      when "symlink"
        external = File.join(root, "review-external-bin")
        FileUtils.mv(bin, external)
        File.write(File.join(external, "codex"), "external sentinel\n")
        File.symlink(external, bin)
      end
      File.write(File.join(root, "replanted"), "#{ENV.fetch("SHIM_REPLANT")}\n")
    end
    puts "{}"
  RUBY
end
