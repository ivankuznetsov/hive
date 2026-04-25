require "test_helper"
require "hive/commands/init"
require "hive/commands/run"

class RunExecuteTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)
  CLAUDE_DRIVER = File.expand_path("fixtures/execute_claude_driver.rb", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    @driver_path = Dir.mktmpdir("execute-driver")
    @driver_log = File.join(@driver_path, "log")
    @driver_script = File.join(@driver_path, "driver.rb")
    File.write(@driver_script, driver_script_body)
    @driver_bin = File.join(@driver_path, "claude")
    File.write(@driver_bin, <<~SH)
      #!/usr/bin/env bash
      if [[ "${1:-}" == "--version" ]]; then
        echo "2.1.118 (Claude Code)"
        exit 0
      fi
      exec ruby "#{@driver_script}" "$@"
    SH
    File.chmod(0o755, @driver_bin)
    ENV["HIVE_CLAUDE_BIN"] = @driver_bin
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    FileUtils.rm_rf(@driver_path)
    FileUtils.rm_rf(@local_worktree_root) if @local_worktree_root
    %w[HIVE_EXEC_DRIVER_TASK_DIR HIVE_EXEC_DRIVER_PASS HIVE_EXEC_DRIVER_FINDINGS
       HIVE_EXEC_DRIVER_PHASE HIVE_EXEC_DRIVER_LOG HIVE_EXEC_DRIVER_TAMPER].each do |k|
      ENV.delete(k)
    end
  end

  # Driver script: depending on prompt content, writes review file or task.md.
  def driver_script_body
    <<~RUBY
      #!/usr/bin/env ruby
      require "fileutils"
      args = ARGV
      log_path = ENV["HIVE_EXEC_DRIVER_LOG"] || "/tmp/exec-driver.log"
      File.open(log_path, "a") { |f| f.puts args.inspect }

      task_dir = ENV.fetch("HIVE_EXEC_DRIVER_TASK_DIR")
      pass = ENV.fetch("HIVE_EXEC_DRIVER_PASS").to_i
      findings_count = ENV.fetch("HIVE_EXEC_DRIVER_FINDINGS").to_i

      prompt = args.last.to_s

      if prompt.include?("ce-review")
        # Reviewer.
        review_dir = File.join(task_dir, "reviews")
        FileUtils.mkdir_p(review_dir)
        review_file = File.join(review_dir, "ce-review-%02d.md" % pass)
        body = +"## High\\n"
        findings_count.times do |i|
          body << "- [ ] finding-\#{i+1}: stub\\n"
        end
        File.write(review_file, body)
        if ENV["HIVE_EXEC_DRIVER_TAMPER"]
          File.write(File.join(task_dir, "plan.md"), "TAMPERED CONTENT")
        end
        exit 0
      end

      # Implementer: append marker to task.md so AGENT_WORKING gets replaced post-run.
      task_md = File.join(task_dir, "task.md")
      content = File.read(task_md)
      content = content.sub(/<!-- AGENT_WORKING.*-->/, "## Implementation\\nstub work pass \#{pass}")
      File.write(task_md, content)
      exit 0
    RUBY
  end

  def setup_execute_task(dir)
    capture_io { Hive::Commands::Init.new(dir).call }
    # Override worktree_root so tests don't pollute ~/Dev.
    cfg_path = File.join(dir, ".hive-state", "config.yml")
    cfg = YAML.safe_load(File.read(cfg_path))
    @local_worktree_root = Dir.mktmpdir("worktree-root-")
    cfg["worktree_root"] = @local_worktree_root
    File.write(cfg_path, cfg.to_yaml)

    slug = "feat-x-260424-aaaa"
    folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "plan.md"), <<~PLAN)
      # plan
      ## Overview
      stub
      <!-- COMPLETE -->
    PLAN
    [ folder, slug ]
  end

  def test_init_pass_creates_worktree_and_review
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_PASS"] = "1"
        ENV["HIVE_EXEC_DRIVER_FINDINGS"] = "2"

        capture_io { Hive::Commands::Run.new(folder).call }

        wt_yml = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
        assert File.directory?(wt_yml["path"]), "worktree directory must exist"
        review_file = File.join(folder, "reviews", "ce-review-01.md")
        assert File.exist?(review_file), "review file must be written"
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_waiting, marker.name
        assert_equal "2", marker.attrs["findings_count"]
        assert_equal "1", marker.attrs["pass"]
      ensure
        FileUtils.rm_rf(wt_yml["path"]) if defined?(wt_yml) && wt_yml
      end
    end
  end

  def test_iteration_pass_with_accepted_findings_increments_pass
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_PASS"] = "1"
        ENV["HIVE_EXEC_DRIVER_FINDINGS"] = "2"
        capture_io { Hive::Commands::Run.new(folder).call }

        # Tick one [x] in the review file.
        review_file = File.join(folder, "reviews", "ce-review-01.md")
        body = File.read(review_file).sub("- [ ] finding-1", "- [x] finding-1")
        File.write(review_file, body)

        ENV["HIVE_EXEC_DRIVER_PASS"] = "2"
        ENV["HIVE_EXEC_DRIVER_FINDINGS"] = "0"
        capture_io { Hive::Commands::Run.new(folder).call }

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_complete, marker.name
        assert File.exist?(File.join(folder, "reviews", "ce-review-02.md"))
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_no_accepted_findings_short_circuits_to_complete
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_PASS"] = "1"
        ENV["HIVE_EXEC_DRIVER_FINDINGS"] = "1"
        capture_io { Hive::Commands::Run.new(folder).call }

        # Don't tick any finding; second run sees nothing accepted.
        ENV["HIVE_EXEC_DRIVER_PASS"] = "2"
        ENV["HIVE_EXEC_DRIVER_FINDINGS"] = "0"
        capture_io { Hive::Commands::Run.new(folder).call }

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_complete, marker.name
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_max_passes_yields_stale_marker
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        # Force max_review_passes=1 in config.
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        cfg = YAML.safe_load(File.read(cfg_path))
        cfg["max_review_passes"] = 1
        File.write(cfg_path, cfg.to_yaml)

        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_PASS"] = "1"
        ENV["HIVE_EXEC_DRIVER_FINDINGS"] = "1"
        capture_io { Hive::Commands::Run.new(folder).call }
        # Tick the finding, attempt pass 2 (which exceeds max=1).
        review_file = File.join(folder, "reviews", "ce-review-01.md")
        body = File.read(review_file).sub("- [ ] finding-1", "- [x] finding-1")
        File.write(review_file, body)

        ENV["HIVE_EXEC_DRIVER_PASS"] = "2"
        capture_io { Hive::Commands::Run.new(folder).call }
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_stale, marker.name
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_reviewer_tampering_protected_files_yields_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_PASS"] = "1"
        ENV["HIVE_EXEC_DRIVER_FINDINGS"] = "1"
        ENV["HIVE_EXEC_DRIVER_TAMPER"] = "1"
        _, _, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal 1, status

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :error, marker.name
        assert_equal "reviewer_tampered", marker.attrs["reason"]
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_implementation_failure_stops_before_review
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_PASS"] = "1"
        ENV["HIVE_EXEC_DRIVER_FINDINGS"] = "0"
        # Implementation prompt → exit 1; reviewer prompt → exit 0. The
        # reviewer branch must NEVER fire; if it does, the test fails because
        # ce-review-01.md will appear.
        File.write(@driver_bin, <<~SH)
          #!/usr/bin/env bash
          if [[ "${1:-}" == "--version" ]]; then echo "2.1.118 (Claude Code)"; exit 0; fi
          if printf '%s' "$*" | grep -q 'ce-review'; then
            exit 0
          else
            exit 1
          fi
        SH
        File.chmod(0o755, @driver_bin)

        _, _, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal 1, status, "Run.report must exit 1 when execute records :error"

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :error, marker.name,
                     "implementation failure must surface as :error, not be overwritten by reviewer pass"
        refute File.exist?(File.join(folder, "reviews", "ce-review-01.md")),
               "reviewer must NOT run after implementation failure"
      ensure
        wt_path = begin
          YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        rescue StandardError
          nil
        end
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_reviewer_failure_does_not_overwrite_with_complete
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_PASS"] = "1"
        ENV["HIVE_EXEC_DRIVER_FINDINGS"] = "0"
        # Implementation succeeds via the driver script; reviewer exits 1.
        File.write(@driver_bin, <<~SH)
          #!/usr/bin/env bash
          if [[ "${1:-}" == "--version" ]]; then echo "2.1.118 (Claude Code)"; exit 0; fi
          if printf '%s' "$*" | grep -q 'ce-review'; then
            exit 1
          else
            exec ruby "#{@driver_script}" "$@"
          fi
        SH
        File.chmod(0o755, @driver_bin)

        _, _, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal 1, status, "Run.report must exit 1 when execute records :error"

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :error, marker.name,
                     "reviewer failure must surface as :error, not be overwritten by finalize_review_state"
      ensure
        wt_path = begin
          YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        rescue StandardError
          nil
        end
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_missing_plan_aborts
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "no-plan-260424-aaaa"
        folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(folder)
        _, err, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal 1, status
        assert_includes err, "plan.md missing"
      end
    end
  end

  def with_captured_exit
    out_pipe = StringIO.new
    err_pipe = StringIO.new
    real_out = $stdout
    real_err = $stderr
    $stdout = out_pipe
    $stderr = err_pipe
    status = 0
    begin
      yield
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = real_out
      $stderr = real_err
    end
    [ out_pipe.string, err_pipe.string, status ]
  end
end
