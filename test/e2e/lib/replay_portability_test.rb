require_relative "../../test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require_relative "paths"
require_relative "repro_script_writer"
require_relative "replay_safety"
unless Hive::E2E.const_defined?(:ReplayLauncher, false)
  load File.join(Hive::E2E::Paths.repo_root, "bin", "hive-e2e")
end

class E2EReplayPortabilityTest < Minitest::Test
  AliasStat = Data.define(:dev, :ino, :mode)

  class AliasMismatchFilesystem
    def lstat(path)
      File.lstat(path)
    end

    def realpath(path)
      File.realpath(path)
    end

    def stat(path)
      stat = File.stat(path)
      return stat unless path.match?(%r{\A/(?:proc/self|dev)/fd/\d+\z})

      AliasStat.new(dev: stat.dev, ino: stat.ino + 1, mode: stat.mode)
    end

    def open(path, flags, &block)
      File.open(path, flags, &block)
    end
  end

  def test_generated_shebang_script_launches_from_its_inherited_descriptor
    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      sandbox = File.join(tmp, "sandbox")
      run_home = File.join(tmp, "run-home")
      FileUtils.mkdir_p([ sandbox, run_home ])
      script = Hive::E2E::ReproScriptWriter.new(
        scenario_dir: scenario_dir,
        sandbox_dir: sandbox,
        run_home: run_home,
        steps: [],
        failed_index: 0,
        scenario_name: "scenario-1"
      ).write
      File.open(script, "a") do |file|
        file.puts <<~'BASH'
          ruby -rjson -e '
            path = ARGV.fetch(0)
            stat = File.stat(path)
            puts JSON.generate(alias_path: path, fd: File.basename(path), dev: stat.dev, ino: stat.ino)
          ' "$0"
        BASH
      end
      expected = File.stat(script)

      out, err, status = Open3.capture3(
        replay_env(runs_dir, state_home),
        hive_e2e, "replay", "run-1", "scenario-1"
      )

      assert status.success?, err
      payload = JSON.parse(out.lines.last)
      assert_match(%r{\A/(?:proc/self|dev)/fd/\d+\z}, payload.fetch("alias_path"))
      assert_equal File.basename(payload.fetch("alias_path")), payload.fetch("fd")
      assert_equal expected.dev, payload.fetch("dev")
      assert_equal expected.ino, payload.fetch("ino")
    end
  end

  def test_native_binary_keeps_repro_sh_as_argv_zero_through_descriptor_alias
    skip "/bin/bash is required to verify native argv[0]" unless File.executable?("/bin/bash")

    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      script = File.join(scenario_dir, "repro.sh")
      FileUtils.cp("/bin/bash", script)
      File.chmod(0o755, script)
      hook = File.join(tmp, "argv0-hook")
      File.write(hook, "printf 'argv0=%s\\n' \"$0\"\nexit 23\n")

      out, err, status = Open3.capture3(
        replay_env(runs_dir, state_home).merge("BASH_ENV" => hook),
        hive_e2e, "replay", "run-1", "scenario-1"
      )

      assert_equal 23, status.exitstatus, err
      assert_empty err
      assert_equal "argv0=repro.sh\n", out
    end
  end

  def test_post_fence_public_script_swap_executes_only_the_pinned_original
    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      original_marker = File.join(tmp, "original-marker")
      replacement_marker = File.join(tmp, "replacement-marker")
      script = File.join(scenario_dir, "repro.sh")
      write_marker_script(script, original_marker)

      ready_r, ready_w = IO.pipe
      continue_r, continue_w = IO.pipe
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      driver = replay_driver(
        runs_dir: runs_dir,
        state_home: state_home,
        ready: ready_w,
        continue: continue_r,
        out: out_w,
        err: err_w
      )
      ready_w.close
      continue_r.close
      out_w.close
      err_w.close

      Timeout.timeout(10) { assert_equal "fenced\n", ready_r.gets }
      parked = "#{script}.pinned"
      File.rename(script, parked)
      write_marker_script(script, replacement_marker)
      continue_w.puts("launch")
      continue_w.close

      _pid, status = Timeout.timeout(10) { Process.wait2(driver) }
      assert status.success?, err_r.read
      assert_equal "", out_r.read
      assert_path_exists original_marker
      refute_path_exists replacement_marker
    ensure
      close_ios(ready_r, ready_w, continue_r, continue_w, out_r, out_w, err_r, err_w)
      terminate_driver(driver)
    end
  end

  def test_artifact_inherits_only_its_script_from_replay_custody
    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      script = File.join(scenario_dir, "repro.sh")
      File.write(script, <<~'BASH')
        #!/usr/bin/env bash
        ruby -rjson -e '
          alias_path = ARGV.fetch(0)
          fds = (3..255).filter_map do |fd|
            path = "/dev/fd/#{fd}"
            begin
              stat = File.stat(path)
              { fd: fd, dev: stat.dev, ino: stat.ino }
            rescue SystemCallError
              nil
            end
          end
          puts JSON.generate(alias_path: alias_path, fds: fds)
        ' "$0"
      BASH
      File.chmod(0o755, script)

      out, err, status = Open3.capture3(
        replay_env(runs_dir, state_home),
        hive_e2e, "replay", "run-1", "scenario-1"
      )

      assert status.success?, err
      payload = JSON.parse(out)
      open_identities = payload.fetch("fds").map { |row| [ row.fetch("dev"), row.fetch("ino") ] }
      script_identity = [ File.stat(script).dev, File.stat(script).ino ]
      assert_equal 1, open_identities.count(script_identity)
      assert_equal File.basename(payload.fetch("alias_path")).to_i,
                   payload.fetch("fds").find { |row| [ row.fetch("dev"), row.fetch("ino") ] == script_identity }
                          .fetch("fd")

      custody_paths = [
        runs_dir,
        File.join(runs_dir, "run-1"),
        File.join(runs_dir, "run-1", "scenarios"),
        scenario_dir,
        Hive::E2E::Paths.replay_control_dir(env: replay_env(runs_dir, state_home))
      ]
      control_root = custody_paths.last
      custody_paths.concat(Dir[File.join(control_root, "*.lock")])
      forbidden = custody_paths.filter_map do |path|
        next unless File.exist?(path)

        stat = File.stat(path)
        [ stat.dev, stat.ino ]
      end
      assert_empty open_identities & forbidden
    end
  end

  def test_missing_descriptor_alias_fails_closed_without_public_path_fallback
    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      write_marker_script(File.join(scenario_dir, "repro.sh"), File.join(tmp, "marker"))
      error = assert_raises(Hive::E2E::ReplaySafety::Error) do
        Hive::E2E::ReplaySafety.new(
          runs_root: runs_dir,
          control_root: Hive::E2E::Paths.replay_control_dir(
            env: replay_env(runs_dir, state_home)
          ),
          descriptor_alias_roots: []
        ).select(run_id: "run-1", scenario: "scenario-1")
      end

      assert_equal "preflight", error.error_kind
      assert_equal "descriptor_exec_unavailable", error.reason
    end
  end

  def test_darwin_descriptor_alias_is_verified_through_its_opened_duplicate
    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      script = File.join(scenario_dir, "repro.sh")
      write_marker_script(script, File.join(tmp, "marker"))
      custody = Hive::E2E::ReplaySafety.new(
        runs_root: runs_dir,
        control_root: Hive::E2E::Paths.replay_control_dir(
          env: replay_env(runs_dir, state_home)
        ),
        filesystem: AliasMismatchFilesystem.new,
        platform: "arm64-darwin"
      ).select(run_id: "run-1", scenario: "scenario-1")

      expected = File.stat(script)
      actual = File.open(custody.descriptor_alias, File::RDONLY, &:stat)
      assert_equal [ expected.dev, expected.ino, expected.mode & 0o170000 ],
                   [ actual.dev, actual.ino, actual.mode & 0o170000 ]
    ensure
      custody&.close
    end
  end

  def test_identity_mismatched_descriptor_alias_fails_closed
    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      write_marker_script(File.join(scenario_dir, "repro.sh"), File.join(tmp, "marker"))

      error = assert_raises(Hive::E2E::ReplaySafety::Error) do
        Hive::E2E::ReplaySafety.new(
          runs_root: runs_dir,
          control_root: Hive::E2E::Paths.replay_control_dir(
            env: replay_env(runs_dir, state_home)
          ),
          filesystem: AliasMismatchFilesystem.new,
          platform: "x86_64-linux"
        ).select(run_id: "run-1", scenario: "scenario-1")
      end

      assert_equal "preflight", error.error_kind
      assert_equal "descriptor_exec_unavailable", error.reason
    end
  end

  def test_execute_bit_loss_after_fence_is_a_descriptor_launch_failure_and_retry_is_clean
    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      marker = File.join(tmp, "marker")
      script = File.join(scenario_dir, "repro.sh")
      write_marker_script(script, marker)
      safety = Hive::E2E::ReplaySafety.new(
        runs_root: runs_dir,
        control_root: Hive::E2E::Paths.replay_control_dir(
          env: replay_env(runs_dir, state_home)
        ),
        on_event: lambda do |event|
          File.chmod(0o644, script) if event == :final_fence_passed
        end
      )
      custody = safety.select(run_id: "run-1", scenario: "scenario-1")
      launcher = Hive::E2E.const_get(:ReplayLauncher).new

      assert_raises(Hive::E2E.const_get(:ReplayLauncher).const_get(:LaunchError)) do
        launcher.run(custody)
      end
      refute_path_exists marker
      custody.close

      File.chmod(0o755, script)
      out, err, status = Open3.capture3(
        replay_env(runs_dir, state_home),
        hive_e2e, "replay", "run-1", "scenario-1"
      )
      assert status.success?, [ out, err ].join("\n")
      assert_equal "original\n", File.read(marker)
    ensure
      custody&.close
    end
  end

  def test_same_inode_content_rewrite_remains_outside_descriptor_custody
    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      original_marker = File.join(tmp, "original-marker")
      rewritten_marker = File.join(tmp, "rewritten-marker")
      script = File.join(scenario_dir, "repro.sh")
      write_marker_script(script, original_marker)
      original = File.stat(script)
      safety = Hive::E2E::ReplaySafety.new(
        runs_root: runs_dir,
        control_root: Hive::E2E::Paths.replay_control_dir(
          env: replay_env(runs_dir, state_home)
        ),
        on_event: lambda do |event|
          write_marker_script(script, rewritten_marker) if event == :final_fence_passed
        end
      )
      custody = safety.select(run_id: "run-1", scenario: "scenario-1")
      assert_equal 0, IO.for_fd(custody.script_fd, autoclose: false).pos

      status = Hive::E2E.const_get(:ReplayLauncher).new.run(custody)

      assert status.success?
      assert_equal original.ino, File.stat(script).ino
      refute_path_exists original_marker
      assert_path_exists rewritten_marker
    ensure
      custody&.close
    end
  end

  def test_ruby_enoexec_fallback_uses_only_the_descriptor_alias
    Dir.mktmpdir("replay-portability") do |tmp|
      runs_dir, state_home, scenario_dir = replay_layout(tmp)
      script = File.join(scenario_dir, "repro.sh")
      File.write(script, "printf 'fallback=%s\\n' \"$0\"\n")
      File.chmod(0o755, script)

      out, err, status = Open3.capture3(
        replay_env(runs_dir, state_home),
        hive_e2e, "replay", "run-1", "scenario-1"
      )

      assert status.success?, err
      assert_match(%r{\Afallback=/(?:proc/self|dev)/fd/\d+\n\z}, out)
      refute_includes out, script
    end
  end

  private

  def hive_e2e
    File.join(Hive::E2E::Paths.repo_root, "bin", "hive-e2e")
  end

  def replay_layout(tmp)
    runs_dir = File.join(tmp, "runs")
    state_home = File.join(tmp, "state")
    scenario_dir = File.join(runs_dir, "run-1", "scenarios", "scenario-1")
    FileUtils.mkdir_p(scenario_dir)
    [ runs_dir, state_home, scenario_dir ]
  end

  def replay_env(runs_dir, state_home)
    {
      "HIVE_E2E_RUNS_DIR" => runs_dir,
      "XDG_STATE_HOME" => state_home
    }
  end

  def replay_driver(runs_dir:, state_home:, ready:, continue:, out:, err:)
    code = <<~RUBY
      load #{hive_e2e.inspect}
      ready = IO.for_fd(Integer(ENV.fetch("REPLAY_READY_FD")))
      continue = IO.for_fd(Integer(ENV.fetch("REPLAY_CONTINUE_FD")))
      binary = Hive::E2E::Binary.new([], {}, {})
      binary.define_singleton_method(:build_replay_safety) do |runs_root:|
        Hive::E2E::ReplaySafety.new(
          runs_root: runs_root,
          on_event: lambda do |event|
            next unless event == :final_fence_passed

            ready.puts("fenced")
            ready.flush
            raise "launch barrier closed" unless continue.gets
          end
        )
      end
      binary.replay("run-1", "scenario-1")
    RUBY
    env = replay_env(runs_dir, state_home).merge(
      "REPLAY_READY_FD" => ready.fileno.to_s,
      "REPLAY_CONTINUE_FD" => continue.fileno.to_s
    )
    Process.spawn(
      env,
      RbConfig.ruby,
      "-Itest",
      "-Ilib",
      "-e",
      code,
      ready.fileno => ready.fileno,
      continue.fileno => continue.fileno,
      out: out,
      err: err,
      close_others: true,
      chdir: Hive::E2E::Paths.repo_root
    )
  end

  def write_marker_script(path, marker)
    File.write(path, <<~BASH)
      #!/usr/bin/env bash
      printf 'original\\n' > #{marker.inspect}
    BASH
    File.chmod(0o755, path)
  end

  def close_ios(*ios)
    ios.compact.each do |io|
      io.close unless io.closed?
    rescue IOError
      nil
    end
  end

  def terminate_driver(pid)
    return unless pid

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
