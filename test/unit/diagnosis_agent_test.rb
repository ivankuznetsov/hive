require "test_helper"
require "digest"
require "fileutils"
require "rbconfig"
require "tmpdir"
require "timeout"
require "yaml"
require "hive/agent_profile"
require "hive/diagnosis_agent"
require "hive/markers"
require "hive/task_action"

# Pins the load-bearing invariants for Hive::DiagnosisAgent:
#   * no marker writes (no :agent_working pre-spawn, no terminal marker)
#   * no task-lock claim (compatible with a concurrent `hive run`)
#   * ADR-019 per-spawn <user_supplied_<nonce>> wrap around every
#     disk-derived value interpolated into the prompt
#   * SecretPatterns redaction over prompt interpolations AND over the
#     written artifact body, but NOT over the YAML frontmatter
#   * write-time freshness gate: marker rotation mid-spawn aborts the
#     artifact write instead of describing the stale state
#   * marker_signature wire-compatible with TaskAction (canonical impl)
class DiagnosisAgentTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(
    :slug, :stage_name, :stage_index, :folder, :state_file,
    :project_root, :worktree_path,
    keyword_init: true
  )

  def setup
    @tmp = Dir.mktmpdir("hive-diagnosis-agent")
    @project_root = File.join(@tmp, "project")
    @slug = "red-task-260516-aaaa"
    @folder = File.join(@project_root, ".hive-state", "stages", "6-review", @slug)
    FileUtils.mkdir_p(@folder)
    @state_file = File.join(@folder, "task.md")
    File.write(@state_file, "<!-- REVIEW_ERROR phase=fix pass=1 -->\n")
    @task = FakeTask.new(
      slug: @slug, stage_name: "review", stage_index: 6,
      folder: @folder, state_file: @state_file,
      project_root: @project_root,
      worktree_path: nil
    )
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # `spawn:` injection captures the prompt the agent would have received
  # so the assertions can inspect the wrap shape + redaction without
  # actually exec-ing claude/codex.
  def spy_spawn(return_value: "agent body", capture_to: [])
    lambda do |profile:, prompt:, cwd:, add_dirs:, timeout_sec:, max_budget_usd:|
      capture_to << {
        profile: profile, prompt: prompt, cwd: cwd, add_dirs: add_dirs,
        timeout_sec: timeout_sec, max_budget_usd: max_budget_usd
      }
      return_value
    end
  end

  def test_does_not_write_markers_or_claim_task_lock
    capture = []
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: capture)).run!

    refute File.exist?(File.join(@folder, ".lock")),
           "DiagnosisAgent must not write a .lock file (no task-lock claim)"
    state_body = File.read(@state_file)
    refute_includes state_body, "<!-- AGENT_WORKING",
                    "DiagnosisAgent must not write :agent_working marker"
    refute_includes state_body, "<!-- COMPLETE",
                    "DiagnosisAgent must not write terminal markers"
  end

  def test_writes_artifact_at_fixed_path
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!

    path = File.join(@folder, "diagnostics", "red-status.md")
    assert File.exist?(path), "expected artifact at #{path}"
    body = File.read(path)
    assert_match(/\A---\n/, body, "artifact must begin with YAML frontmatter")
    assert_match(/^# Red Status Diagnosis$/, body)
  end

  def test_prompt_wraps_user_supplied_content_in_per_spawn_nonce
    capture = []
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: capture)).run!

    prompt = capture.first[:prompt]
    assert_match(/<user_supplied_[0-9a-f]{16}>/, prompt,
                 "ADR-019 nonce wrap must surround interpolated content")
    nonce = prompt.match(/<(user_supplied_[0-9a-f]{16})>/)[1]
    assert_includes prompt, "<#{nonce}>"
    assert_includes prompt, "</#{nonce}>"
    # Slug, marker name, and marker attrs all wrapped in the same nonce.
    assert_match(/<#{Regexp.escape(nonce)}>#{Regexp.escape(@slug)}<\/#{Regexp.escape(nonce)}>/, prompt)
    assert_match(/<#{Regexp.escape(nonce)}>review_error<\/#{Regexp.escape(nonce)}>/, prompt)
  end

  def test_each_spawn_uses_a_fresh_nonce
    first = []
    second = []
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: first)).run!
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: second)).run!

    first_nonce = first.first[:prompt].match(/<(user_supplied_[0-9a-f]+)>/)[1]
    second_nonce = second.first[:prompt].match(/<(user_supplied_[0-9a-f]+)>/)[1]
    refute_equal first_nonce, second_nonce,
                 "consecutive DiagnosisAgent runs must mint distinct ADR-019 nonces"
  end

  def test_marker_attrs_with_secret_values_are_redacted_in_prompt
    token = "ghp_#{'a' * 40}"
    File.write(@state_file, "<!-- REVIEW_ERROR reason=\"creds leaked #{token}\" -->\n")
    capture = []
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: capture)).run!

    prompt = capture.first[:prompt]
    refute_includes prompt, token,
                    "SecretPatterns must scrub credentials before they leave the host"
    assert_includes prompt, "[REDACTED:github_token]"
  end

  def test_artifact_body_is_redacted_but_frontmatter_is_not
    token = "ghp_#{'a' * 40}"
    body = "Agent reports: #{token} leaked in logs"
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(return_value: body)).run!

    artifact = File.read(File.join(@folder, "diagnostics", "red-status.md"))
    frontmatter = artifact.split("---", 3)[1]
    body_part = artifact.split("---", 3)[2]

    refute_includes frontmatter, "[REDACTED",
                    "frontmatter must not be processed by SecretPatterns (would corrupt YAML)"
    assert_match(/marker_signature: [0-9a-f]{64}/, frontmatter)
    assert_includes body_part, "[REDACTED:github_token]"
    refute_includes body_part, token
  end

  def test_artifact_frontmatter_carries_canonical_marker_signature
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!

    frontmatter = YAML.safe_load(
      File.read(File.join(@folder, "diagnostics", "red-status.md")).split("---")[1],
      permitted_classes: [ Time ]
    )
    # Reproduce TaskAction#marker_signature for the same (marker, attrs)
    # pair. Producer + consumer must agree byte-for-byte.
    expected = Digest::SHA256.hexdigest("review_error\npass=1\nphase=fix")
    assert_equal expected, frontmatter["marker_signature"]
  end

  def test_marker_rotation_during_spawn_aborts_write_with_stale_marker
    rotating_spawn = lambda do |**_args|
      # Simulate a concurrent `hive run` writing a new marker between
      # DiagnosisAgent#run!'s pre-spawn read and post-spawn freshness
      # check. The freshness gate must refuse the write so we never
      # produce an artifact that describes a state the task is no
      # longer in.
      File.write(@state_file, "<!-- REVIEW_ERROR phase=fix pass=2 -->\n")
      "agent body"
    end

    assert_raises(Hive::DiagnosisAgent::StaleMarker) do
      Hive::DiagnosisAgent.new(task: @task, spawn: rotating_spawn).run!
    end

    refute File.exist?(File.join(@folder, "diagnostics", "red-status.md")),
           "stale-marker abort must NOT leave an artifact behind"
  end

  def test_write_artifact_is_world_readable_for_other_uids
    # Daemon and bot workers can run under different uids than the CLI
    # operator that triggered the diagnose. The artifact IS the
    # freshness gate for every subsequent poll across all consumers;
    # if Tempfile's default 0600 mode leaks into the rename target,
    # those consumers silently fail to read it and the operator-visible
    # symptom is "no diagnostic available" while the file exists. See
    # PR #84 review C6.
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!

    path = File.join(@folder, "diagnostics", "red-status.md")
    mode_bits = File.stat(path).mode & 0o777
    assert_equal 0o644, mode_bits,
                 "artifact must be world-readable so daemon / bot under other uids can consume it"
  end

  def test_write_artifact_eaccess_maps_to_actionable_hive_error
    # Pre-fix, an Errno::EACCES from File.rename propagated raw —
    # operators on a TTY saw a backtrace instead of a "could not write
    # red-status.md" message. Drive the rename-fails path by making
    # the diagnostics dir read-only before run!; Tempfile create or
    # rename then fails with EACCES which the wrapped rescue maps to
    # Hive::Error. See PR #84 review C6.
    FileUtils.mkdir_p(File.join(@folder, "diagnostics"))
    File.chmod(0o500, File.join(@folder, "diagnostics"))
    begin
      error = assert_raises(Hive::Error) do
        Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!
      end
      assert_match(/could not (write|acquire diagnose lock)/, error.message,
                   "EACCES on rename or lock acquisition must surface as actionable Hive::Error, not raw Errno")
      refute_match(/Errno::EACCES/, error.class.to_s,
                   "the raised class must be Hive::Error, not a raw Errno class")
    ensure
      File.chmod(0o755, File.join(@folder, "diagnostics"))
    end
  end

  def test_concurrent_diagnose_on_same_task_raises_diagnosis_in_flight
    # Two concurrent `--diagnose --write` invocations on the same task
    # must not both spawn the configured agent and burn budget in
    # parallel. The first acquires the per-task flock; the second fails
    # fast with DiagnosisInFlight rather than blocking or duplicating
    # work. See PR #84 review findings #2 + #11.
    started = Queue.new
    release = Queue.new
    slow_spawn = lambda do |**_kwargs|
      started << :go
      release.pop          # block until the test signals completion
      "agent body"
    end

    holder = Thread.new do
      Hive::DiagnosisAgent.new(task: @task, spawn: slow_spawn).run!
    rescue StandardError
      # Tolerate Config-load failures from the simplified FakeTask; the
      # lock has already been acquired before that path is reached.
      nil
    end

    started.pop          # ensure the holder has the lock

    assert_raises(Hive::DiagnosisAgent::DiagnosisInFlight) do
      Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!
    end

    release << :done
    holder.join
  end

  def test_diagnose_lock_released_on_exception_so_retry_can_acquire
    # An agent spawn that raises must release the flock in ensure so
    # the operator's retry isn't permanently blocked.
    fail_spawn = lambda { |**_kwargs| raise Hive::Error, "boom" }
    assert_raises(Hive::Error) do
      Hive::DiagnosisAgent.new(task: @task, spawn: fail_spawn).run!
    end

    # A subsequent run on the same task must NOT see DiagnosisInFlight.
    refute_raises_diagnosis_in_flight do
      Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!
    end
  end

  def refute_raises_diagnosis_in_flight
    yield
  rescue Hive::DiagnosisAgent::DiagnosisInFlight
    flunk "diagnose flock was not released — retry would be permanently blocked"
  rescue StandardError
    # Other errors are fine for this test's purpose (lock was released).
    nil
  end

  def test_missing_execute_agent_config_surfaces_actionable_error
    # An unknown agent profile is rejected by AgentProfiles.lookup with
    # Hive::ConfigError → exit 78. DiagnosisAgent must propagate that
    # without writing a partial artifact.
    FileUtils.mkdir_p(File.dirname(@state_file).then { |d| File.join(@project_root, ".hive-state") })
    File.write(
      File.join(@project_root, ".hive-state", "config.yml"),
      YAML.dump("execute" => { "agent" => "no-such-agent" })
    )

    assert_raises(Hive::ConfigError) do
      Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!
    end
  end

  def test_stale_marker_exit_code_is_tempfail
    # Agent wrappers branch on exit code to decide retry-vs-escalate.
    # StaleMarker is retryable (marker rotated during the spawn; the
    # operator just needs to re-issue) and MUST map to TEMPFAIL (75),
    # matching Hive::ConcurrentRunError's semantics. Generic exit 1 (the
    # Hive::Error default) would tell wrappers to escalate.
    assert_equal Hive::ExitCodes::TEMPFAIL,
                 Hive::DiagnosisAgent::StaleMarker.new("stale").exit_code
  end

  def test_diagnosis_in_flight_exit_code_is_tempfail
    # Lock contention is retryable; same TEMPFAIL semantics as
    # Hive::ConcurrentRunError so wrappers can branch uniformly.
    assert_equal Hive::ExitCodes::TEMPFAIL,
                 Hive::DiagnosisAgent::DiagnosisInFlight.new("inflight").exit_code
  end

  def test_run_with_timeout_installs_and_restores_sigint_handler
    # Ctrl-C during the popen3 block unwinds the body and Ruby's popen3
    # ensure calls wait_thr.join with no timeout — the child agent is
    # never signalled and the CLI hangs forever. Verify the SIGINT (and
    # SIGTERM) trap is installed during run_with_timeout and restored
    # afterward so the operator's Ctrl-C terminates the child pgroup.
    agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
    pre_int = Signal.trap("INT") { nil }
    pre_term = Signal.trap("TERM") { nil }
    Signal.trap("INT", pre_int)
    Signal.trap("TERM", pre_term)

    seen_handlers = []
    fake_spawn = lambda do |**_kwargs|
      # Snapshot the active handlers from inside the popen3 block-equivalent.
      seen_handlers << [ Signal.trap("INT") { nil }, Signal.trap("TERM") { nil } ]
      # Restore so the agent's body assertion sees the same state as a
      # real spawn would.
      Signal.trap("INT", seen_handlers.first[0])
      Signal.trap("TERM", seen_handlers.first[1])
      "agent body"
    end
    # Wire the injected spawn through DiagnosisAgent#run! so the trap
    # would be installed; the injected callable bypasses popen3 (and
    # therefore the trap installation), so this test alone can't prove
    # the trap is set DURING popen3. The companion `run_with_timeout`
    # tightening is covered by the spawn_profile path manually.
    Hive::DiagnosisAgent.new(task: @task, spawn: fake_spawn).run!
    post_int = Signal.trap("INT") { nil }
    post_term = Signal.trap("TERM") { nil }
    Signal.trap("INT", post_int)
    Signal.trap("TERM", post_term)

    # Caller's INT/TERM handlers must be restored to their pre-call values.
    assert_equal pre_int, post_int,
                 "INT handler must be restored to caller's handler after run!"
    assert_equal pre_term, post_term,
                 "TERM handler must be restored to caller's handler after run!"
    agent
  end

  def test_run_with_timeout_traps_int_and_kills_pgroup_on_ctrl_c
    # Spawn a short-lived shell child via the real run_with_timeout
    # path, send SIGINT to ourselves while the child is alive, and
    # verify the child is signalled (no orphan, no hang). The popen3
    # block must trap INT so Ruby's auto-unwind doesn't bypass child
    # cleanup. Skip on platforms where Process.kill is not supported.
    skip "Process.kill not supported on this platform" if RUBY_PLATFORM =~ /mswin|mingw/

    agent = Hive::DiagnosisAgent.new(task: @task)
    raised = nil
    thr = Thread.new do
      begin
        agent.send(:run_with_timeout, [ "sleep", "30" ], Dir.pwd, nil, 60)
      rescue Interrupt => e
        raised = e
      rescue Hive::Error => e
        raised = e
      end
    end
    # Wait a moment for popen3 to install the trap and start the child.
    sleep 0.3
    Process.kill("INT", Process.pid)
    thr.join(10)
    refute thr.alive?, "run_with_timeout must not hang past SIGINT"
    assert raised, "SIGINT must surface as Interrupt or Hive::Error from run_with_timeout"
  end

  def test_marker_rotation_to_agent_working_mid_spawn_aborts_with_stale_marker
    # A concurrent `hive run` flipping the marker to :agent_working
    # mid-spawn means the agent's verdict would describe an in-flight
    # run, not a red recovery state. The write-time freshness gate must
    # raise StaleMarker — see PR #84 review row 12.
    rotating_spawn = lambda do |**_args|
      File.write(@state_file, "<!-- AGENT_WORKING pid=999 -->\n")
      "agent body"
    end

    error = assert_raises(Hive::DiagnosisAgent::StaleMarker) do
      Hive::DiagnosisAgent.new(task: @task, spawn: rotating_spawn).run!
    end
    assert_match(/transitioned to/i, error.message,
                 "stale-marker error must mention the new marker state for operator")
    refute File.exist?(File.join(@folder, "diagnostics", "red-status.md")),
           "transition to non-red state must NOT leave an artifact behind"
  end

  def test_dispatch_time_freshness_gate_rejects_non_red_marker
    # If the marker is already in a non-red state when DiagnosisAgent
    # acquires the lock (e.g., a concurrent `hive run` raced ahead),
    # the agent must not spawn at all — its verdict has no audience.
    File.write(@state_file, "<!-- AGENT_WORKING pid=999 -->\n")
    spawned = false
    no_spawn = lambda { |**_kwargs| spawned = true; "should not spawn" }

    assert_raises(Hive::DiagnosisAgent::StaleMarker) do
      Hive::DiagnosisAgent.new(task: @task, spawn: no_spawn).run!
    end
    refute spawned, "DiagnosisAgent must not spawn when marker is not red at dispatch"
  end

  def test_run_with_timeout_succeeds_when_descendant_drains_within_grace
    # Pre-fix this test pinned the false-timeout bug: a fast shell parent plus descendant
    # holding stdio open past the runtime deadline would trip a timeout even though the
    # parent had exited successfully and only the pipe drain was
    # outstanding. The drain phase now uses its own TERMINATE_GRACE
    # budget rather than the runtime timeout, so a successful parent
    # whose descendants drain within ~5s returns cleanly. See PR #84
    # review C3.
    agent = Hive::DiagnosisAgent.new(task: @task)
    out = nil
    Timeout.timeout(8) do
      out = agent.send(
        :run_with_timeout,
        [ "sh", "-c", "sleep 2 & echo done" ],
        Dir.pwd,
        nil,
        1.0
      )
    end

    assert_includes out.to_s, "done",
                    "parent exited successfully — drain must complete and the agent output must surface"
  end

  def test_run_with_timeout_redacts_failed_agent_stderr
    token = "ghp_#{'a' * 40}"
    agent = Hive::DiagnosisAgent.new(task: @task)

    error = assert_raises(Hive::Error) do
      agent.send(
        :run_with_timeout,
        [ "sh", "-c", "printf '%s\\n' \"$1\" >&2; exit 2", "diagnosis-agent-test", token ],
        Dir.pwd,
        nil,
        2
      )
    end

    refute_includes error.message, token
    assert_includes error.message, "[REDACTED:github_token]"
  end

  def test_run_rejects_worktree_pointer_outside_configured_root
    worktree_root = File.join(@tmp, "worktrees")
    FileUtils.mkdir_p(worktree_root)
    File.write(
      File.join(@project_root, ".hive-state", "config.yml"),
      YAML.dump("worktree_root" => worktree_root)
    )
    @task.worktree_path = File.join(@tmp, "outside-worktree")
    spawned = false

    assert_raises(Hive::WorktreeError) do
      Hive::DiagnosisAgent.new(task: @task, spawn: lambda { |**_kwargs| spawned = true; "agent body" }).run!
    end
    refute spawned, "DiagnosisAgent must validate worktree.yml before spawning"
  end

  def test_run_rejects_custom_generated_by_not_in_published_schema_enum
    originals = Hive::AgentProfiles.registered_names.to_h do |name|
      [ name, Hive::AgentProfiles.lookup(name) ]
    end
    Hive::AgentProfiles.register(
      :custom,
      Hive::AgentProfile.new(
        name: :custom,
        bin_default: "custom-agent",
        headless_flag: "--headless",
        version_flag: "--version",
        skill_syntax_format: "/%{skill}"
      )
    )
    File.write(
      File.join(@project_root, ".hive-state", "config.yml"),
      YAML.dump("execute" => { "agent" => "custom" })
    )
    spawned = false

    error = assert_raises(Hive::ConfigError) do
      Hive::DiagnosisAgent.new(task: @task, spawn: lambda { |**_kwargs| spawned = true; "agent body" }).run!
    end

    assert_match(/generated_by/, error.message)
    refute spawned, "unsupported diagnostic generator must fail before spawning"
  ensure
    Hive::AgentProfiles.reset_for_tests!
    originals&.each { |name, profile| Hive::AgentProfiles.register(name, profile) }
  end
def test_class_run_delegates_to_instance_run
  constructed = nil
  fake = Object.new
  fake.define_singleton_method(:run!) { :ran }

  result = with_replaced_singleton_method(Hive::DiagnosisAgent, :new, lambda { |**kwargs|
    constructed = kwargs
    fake
  }) do
    Hive::DiagnosisAgent.run!(task: @task, local_diagnostic: "local")
  end

  assert_equal :ran, result
  assert_equal @task, constructed[:task]
  assert_equal "local", constructed[:local_diagnostic]
end

def test_production_spawn_path_checks_profile_version_and_preflight
  profile = FakeProfile.new(name: :codex)
  agent = Hive::DiagnosisAgent.new(task: @task)
  agent.instance_variable_set(:@spawn, ->(**_kwargs) { "agent body" })

  with_replaced_singleton_method(Hive::Stages::Base, :stage_profile, ->(_cfg, _stage) { profile }) do
    agent.run!
  end

  assert_equal %i[check_version preflight], profile.calls
end

def test_diagnose_lock_warns_when_unlock_fails_but_closes_file
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
  lock_path = File.join(@folder, "diagnostics", Hive::DiagnosisAgent::LOCK_FILENAME)
  fake_lock = FakeLockFile.new(unlock_error: Errno::EIO.new("unlock failed"))
  original_file_open = File.method(:open)

  _out, err = capture_io do
    with_replaced_singleton_method(File, :open, lambda { |path, *args, &block|
      if path == lock_path && args.first == (File::RDWR | File::CREAT)
        fake_lock
      else
        original_file_open.call(path, *args, &block)
      end
    }) do
      agent.send(:with_diagnose_lock) { :ok }
    end
  end

  assert_includes err, "flock unlock"
  assert_equal true, fake_lock.closed
end

def test_local_diagnostic_text_formats_strings_and_hashes
  plain = Hive::DiagnosisAgent.new(task: @task, local_diagnostic: "plain text", spawn: spy_spawn)
  assert_equal "plain text", plain.send(:local_diagnostic_text)

  structured = Hive::DiagnosisAgent.new(
    task: @task,
    local_diagnostic: {
      "summary" => "failed",
      "detail" => nil,
      "source" => "local",
      "updated_at" => "2026-05-22T12:00:00Z"
    },
    spawn: spy_spawn
  )
  assert_equal "summary: failed\nsource: local\nupdated_at: 2026-05-22T12:00:00Z",
               structured.send(:local_diagnostic_text)
end

def test_write_artifact_errors_are_wrapped_as_hive_error
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)

  error = with_replaced_singleton_method(Tempfile, :create, ->(*_args) { raise Errno::ENOSPC, "full" }) do
    assert_raises(Hive::Error) { agent.send(:write_artifact, "body") }
  end

  assert_match(/could not write .*red-status\.md/, error.message)
  assert_includes error.message, "ENOSPC"
end

def test_fsync_dir_ignores_unsupported_directory_fsync
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)

  result = with_replaced_singleton_method(File, :open, ->(_path, *_args) { raise Errno::EINVAL, "unsupported" }) do
    agent.send(:fsync_dir, @folder)
  end

  assert_nil result
end

def test_spawn_profile_builds_codex_command_and_pipes_prompt_to_stdin
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
  profile = CommandProfile.new(
    name: :codex,
    bin: "codex",
    headless_flag: "exec",
    permission_skip_flag: "--dangerously-bypass-approvals-and-sandbox",
    add_dir_flag: "--add-dir",
    budget_flag: "--budget"
  )
  captured = nil
  agent.define_singleton_method(:run_with_timeout) do |cmd, cwd, stdin_data, timeout_sec|
    captured = { cmd: cmd, cwd: cwd, stdin_data: stdin_data, timeout_sec: timeout_sec }
    "ok"
  end

  result = agent.send(
    :spawn_profile,
    profile: profile, prompt: "diagnose", cwd: @project_root,
    add_dirs: [ @folder ], timeout_sec: 12, max_budget_usd: 3
  )

  assert_equal "ok", result
  assert_equal [ "codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "--add-dir", @folder, "--budget", "3", "-" ],
               captured[:cmd]
  assert_equal "diagnose", captured[:stdin_data]
  assert_equal 12, captured[:timeout_sec]
end

def test_build_cmd_omits_optional_flags_for_plain_prompt_profiles
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
  profile = CommandProfile.new(name: :claude, bin: "claude")

  cmd = agent.send(:build_cmd, profile, "diagnose", [ @folder ], nil)

  assert_equal [ "claude", "diagnose" ], cmd
end

def test_run_with_timeout_traps_term_and_kills_pgroup_on_sigterm
  skip "Process.kill not supported on this platform" if RUBY_PLATFORM =~ /mswin|mingw/

  agent = Hive::DiagnosisAgent.new(task: @task)
  raised = nil
  thr = Thread.new do
    begin
      agent.send(:run_with_timeout, [ "sleep", "30" ], Dir.pwd, nil, 60)
    rescue Interrupt, Hive::Error => e
      raised = e
    end
  end

  sleep 0.3
  Process.kill("TERM", Process.pid)
  thr.join(10)

  refute thr.alive?, "run_with_timeout must not hang past SIGTERM"
  assert raised, "SIGTERM must surface as Interrupt or Hive::Error from run_with_timeout"
end

def test_run_with_timeout_times_out_and_terminates_pgroup
  agent = Hive::DiagnosisAgent.new(task: @task)

  error = assert_raises(Hive::Error) do
    agent.send(:run_with_timeout, [ "sleep", "30" ], Dir.pwd, nil, 0.1)
  end

  assert_match(/timed out after 0.1s/, error.message)
end

def test_drain_reader_threads_timeout_terminates_child_and_kills_readers
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
  alive_reader = FakeReaderThread.new(alive: true)
  killed = []
  terminated = []
  agent.define_singleton_method(:terminate_process_group) { |pid| terminated << pid }
  agent.define_singleton_method(:kill_reader_threads) { |*threads| killed.concat(threads) }

  error = assert_raises(Hive::Error) do
    agent.send(
      :drain_reader_threads_or_timeout,
      1234, alive_reader, alive_reader,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1,
      9
    )
  end

  assert_equal [ 1234 ], terminated
  assert_equal [ alive_reader, alive_reader ], killed
  assert_match(/timed out after 9s/, error.message)
end

def test_feed_stdin_ignores_epipe_and_close_errors
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
  stdin = FakeStdin.new(write_error: Errno::EPIPE.new, close_error: IOError.new("already closed"))

  assert_nil agent.send(:feed_stdin, stdin, "prompt")
  assert_equal true, stdin.closed
end

def test_read_stream_returns_empty_string_for_io_error
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
  stream = Object.new
  stream.define_singleton_method(:read) { raise IOError, "closed" }

  assert_equal "", agent.send(:read_stream, stream)
end

def test_terminate_process_group_returns_when_process_is_already_gone
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
  agent.instance_variable_set(:@kill_threads_queue, Queue.new)

  with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
    assert_nil agent.send(:terminate_process_group, 1234)
  end

  assert_raises(ThreadError) { agent.instance_variable_get(:@kill_threads_queue).pop(true) }
end

def test_terminate_process_group_waits_then_escalates_to_kill
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
  agent.instance_variable_set(:@kill_threads_queue, Queue.new)
  signals = []
  wait_results = [ nil, [ 1234, Object.new ] ]

  with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
    with_replaced_singleton_method(Process, :waitpid2, ->(_pid, _flags) { wait_results.shift }) do
      agent.send(:terminate_process_group, 1234)
      agent.send(:join_kill_threads)
    end
  end

  assert_equal [ [ "TERM", -1234 ], [ "KILL", -1234 ] ], signals
end

def test_kill_reader_threads_only_kills_live_threads
  agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
  live = FakeReaderThread.new(alive: true)
  dead = FakeReaderThread.new(alive: false)

  agent.send(:kill_reader_threads, live, dead)

  assert_equal true, live.killed
  assert_equal false, dead.killed
end

private

FakeProfile = Struct.new(:name, keyword_init: true) do
  attr_reader :calls

  def initialize(**kwargs)
    super
    @calls = []
  end

  def check_version!
    calls << :check_version
  end

  def preflight!
    calls << :preflight
  end
end

CommandProfile = Struct.new(
  :name, :bin, :headless_flag, :permission_skip_flag, :add_dir_flag, :budget_flag,
  keyword_init: true
)

class FakeLockFile
  attr_reader :closed

  def initialize(unlock_error: nil)
    @unlock_error = unlock_error
    @closed = false
  end

  def flock(mode)
    raise @unlock_error if mode == File::LOCK_UN && @unlock_error

    true
  end

  def close
    @closed = true
  end
end

class FakeReaderThread
  attr_reader :killed

  def initialize(alive:)
    @alive = alive
    @killed = false
  end

  def alive?
    @alive
  end

  def kill
    @killed = true
  end
end

class FakeStdin
  attr_reader :closed

  def initialize(write_error: nil, close_error: nil)
    @write_error = write_error
    @close_error = close_error
    @closed = false
  end

  def write(_data)
    raise @write_error if @write_error
  end

  def close
    @closed = true
    raise @close_error if @close_error
  end
end
end
