require "application_system_test_case"
require "open3"

# The hivebox golden path, end to end, in a real browser — deliberately NOT
# named *_test.rb so the default suites skip it; run it explicitly:
#
#   cd web && bin/rails test test/e2e/golden_path_e2e.rb
#
# What is real: the browser (capybara-playwright), the Rails app, the claim
# flow's GithubAuth logic, a REAL `hive daemon` subprocess advancing stages,
# real git repos/worktrees/commits, the brainstorm answer round trip.
# What is stubbed: GitHub's HTTP endpoints (the `http:` DI seam — device
# flow runs unmodified against canned responses) and the agent binary (a
# stage-aware fake claude; AI output is not under test here).
class GoldenPathE2E < ApplicationSystemTestCase
  REPO_ROOT = File.expand_path("../../..", __dir__)
  SUPPORT = File.expand_path("support", __dir__)

  class FakeGithubHttp
    def initialize(device:, token:, user:)
      @device = device
      @token = token
      @user = user
    end

    def start(host, _port, **_opts)
      @host = host
      yield self
    end

    def request(req)
      return @user if @host == "api.github.com"

      req.path.include?("/login/device/code") ? @device : @token
    end
  end

  setup do
    configure_owner!(owner: "") # claimable box
    speed_up_daemon!
    @project = create_hive_project!("golden-app")
    force_headless_claude!(@project)
    StatusBroadcaster.start!
    install_github_stub(login: "goldenpath")
    spawn_daemon!
  end

  teardown do
    if @daemon_pid
      Process.kill("TERM", @daemon_pid)
      Process.wait(@daemon_pid)
    end
    StatusBroadcaster.stop!
    SessionsController.http_client = Net::HTTP
    # The sandbox vanishes with the process — on failure, keep the daemon's
    # own event log and the task tree where a human can read them.
    unless passed?
      # CI has no /tmp artifacts — put the tale in the job log itself.
      daemon_events = File.join(ENV["HIVE_HOME"], "logs", "daemon.log")
      if File.exist?(daemon_events)
        puts "===== daemon events (tail) ====="
        puts File.readlines(daemon_events).last(40).join
      end
      if @daemon_log && File.exist?(@daemon_log)
        puts "===== daemon stdout ====="
        puts File.read(@daemon_log)
      end
      if @daemon_pid
        alive = (Process.kill(0, @daemon_pid) && true rescue false)
        puts "===== daemon pid #{@daemon_pid} alive=#{alive} ====="
      end
      puts "===== HIVE_HOME/logs: #{Dir[File.join(ENV["HIVE_HOME"], "logs", "*")].inspect} ====="
      debug_dir = "/tmp/golden-e2e-debug"
      FileUtils.rm_rf(debug_dir)
      FileUtils.mkdir_p(debug_dir)
      daemon_events = File.join(ENV["HIVE_HOME"], "logs", "daemon.log")
      FileUtils.cp(daemon_events, debug_dir) if File.exist?(daemon_events)
      stages = Dir[File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", "*", ".hive-state", "stages", "*", "*")]
      File.write(File.join(debug_dir, "stages.txt"), stages.join("
"))
      stages.each do |folder|
        Dir[File.join(folder, "*")].each do |f|
          next unless File.file?(f)

          FileUtils.cp(f, File.join(debug_dir, "#{File.basename(folder)}-#{File.basename(f)}"))
        end
      end
      Dir[File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", "*", ".hive-state", "logs", "*", "*.log")].each do |f|
        FileUtils.cp(f, File.join(debug_dir, "agent-#{File.basename(f)}"))
      end
    end
  end

  test "claim the box, drop an idea, answer the brainstorm, reach the PR gate" do
    # --- Claim: the first device-flow login becomes the owner -------------
    visit "/login"
    assert_text "first GitHub sign-in becomes its owner"
    click_button "Continue with GitHub"
    assert_text "ABCD-1234" # the one-time code must be shown to the operator

    # The wait page meta-refreshes once per interval; the next render polls
    # the (stubbed) token endpoint and admits.
    assert_selector "#projects", wait: 15
    config = YAML.safe_load_file(File.join(ENV["HIVE_HOME"], "config.yml"))
    assert_equal "goldenpath", config.dig("web", "github", "owner"),
                 "the claim must be persisted as the box's owner"

    # --- Sample idea -------------------------------------------------------
    fill_in "New idea", with: "Golden path sample idea"
    find(".composer select[name='project']").find("option[value='#{@project}']").select_option
    click_button "Add idea"
    assert_selector ".task-row", text: "Golden path sample idea", wait: 10

    # --- The daemon pulls it from the inbox on its own ----------------------
    # No clicking: the golden path is "drop the idea, the pipeline runs".
    # (A manual Force approve here would race the daemon's own advance.)

    # --- Brainstorm round 1: the daemon's agent asks, we answer ------------
    # Turbo may replace the grid row while the daemon advances the task, so
    # re-resolve the link if the row detaches during the click.
    slug = task_slug_from_grid!("Golden path sample idea")
    click_task_link!("Golden path sample idea")
    answer_field = find("textarea[name='answers[1]']", wait: 45)
    assert_text "Ship the sample feature?"
    # Answer only AFTER the daemon has reaped the round-1 child: the edit
    # baseline is seeded from the state file's mtime at child_exited, so an
    # answer written before the reap is swallowed and the resume never
    # fires (recorded in wiki/gaps.md as a real product edge — an operator
    # answering within one daemon tick of the agent finishing strands the
    # task). The daemon's event log and the state file's mtime are the
    # observable artifacts; waiting on them keeps this out of blind sleeps.
    wait_for_answer_window!(slug)
    answer_field.fill_in with: "Yes — ship it."
    click_button "Send answers"
    assert_text "Recorded answer", wait: 10

    # --- The daemon drives brainstorm→plan→execute on its own --------------
    # Each hop is a real dispatch + real fake-agent run + real stage logic;
    # the page is push-morphed, so these waits ride live updates, no reloads.
    assert_selector ".stage-badge", text: "execute", wait: 90
    assert_selector ".task-meta", text: "Ready to open PR", wait: 90

    # The implementation commit is real and lives in a real worktree.
    worktrees = Dir[File.join(ENV["HIVE_TEST_HOME_ROOT"], "worktrees", "*")]
    assert worktrees.any?, "execute must have created a worktree"
    log = `git -C #{worktrees.first} log --oneline -1`
    assert_includes log, "golden path sample implementation",
                    "the fake agent's commit must be a real commit in a real worktree"
  end

  private

  # The status grid is Turbo-replaced while the daemon advances tasks. Read the
  # slug from a single current-DOM query instead of retaining a Capybara element.
  def task_slug_from_grid!(title, timeout: 10)
    title_json = title.to_json
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      slug = page.evaluate_script(<<~JS)
        (() => {
          const rows = Array.from(document.querySelectorAll(".task-row"));
          const row = rows.find((node) => node.textContent.includes(#{title_json}));
          return row?.querySelector(".task-slug")?.textContent?.trim();
        })()
      JS
      return slug if slug && !slug.empty?

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "task row for #{title.inspect} never exposed a slug"
      end

      sleep 0.1
    end
  end

  # The resume watcher only sees edits NEWER than its baseline, and the
  # baseline is seeded by the first classification tick AFTER the round-1
  # child is reaped. Answering inside that window strands the task
  # (wiki/gaps.md records this as a real product edge). Wait for both
  # events IN ORDER in the daemon's own log, then wait for a distinct
  # state-file mtime tick so coarse CI filesystems cannot collapse the
  # answer write onto the baseline mtime.
  def wait_for_answer_window!(slug, timeout: 60)
    events = File.join(ENV["HIVE_HOME"], "logs", "daemon.log")
    slug_re = Regexp.escape(slug)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      log = File.exist?(events) ? File.read(events) : ""
      exited = log.match(/"child_exited".*#{slug_re}|#{slug_re}.*"child_exited"/)
      if exited
        rest = log[exited.end(0)..]
        break if rest.lines.any? do |line|
          line.include?(slug) && line.include?("2-brainstorm") &&
            line.match?(/"(skipped|debouncing|dispatched)"/)
        end
      end
      raise "daemon never opened the answer window for #{slug}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.2
    end
    wait_for_next_state_file_mtime_tick!(slug)
  end

  def wait_for_next_state_file_mtime_tick!(slug, timeout: 5)
    path = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", @project,
                     ".hive-state", "stages", "2-brainstorm", slug, "brainstorm.md")
    baseline_sec = File.mtime(path).to_i
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if Time.now.to_i > baseline_sec

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "state-file mtime second did not advance for #{slug}"
      end

      sleep 0.05
    end
  end

  def click_task_link!(title, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      find(".task-row", text: title, wait: 1).find("a", match: :first).click
      return
    rescue Capybara::ElementNotFound
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    rescue Playwright::Error => e
      raise unless e.message.include?("not attached to the DOM")
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def install_github_stub(login:)
    device = http_ok(JSON.generate(
                       "device_code" => "dev-1", "user_code" => "ABCD-1234",
                       "verification_uri" => "https://github.com/login/device",
                       # interval 1: the wait page must actually RENDER with the
                       # code before the meta-refresh polls and admits.
                       "expires_in" => 900, "interval" => 1
                     ))
    token = http_ok(JSON.generate("access_token" => "gho_e2e"))
    user = http_ok(JSON.generate("login" => login))
    SessionsController.http_client = FakeGithubHttp.new(device: device, token: token, user: user)
  end

  def http_ok(body)
    res = Net::HTTPOK.new("1.1", "200", "OK")
    res.instance_variable_set(:@read, true)
    res.define_singleton_method(:body) { body }
    res
  end

  def speed_up_daemon!
    path = File.join(ENV["HIVE_HOME"], "config.yml")
    data = File.exist?(path) ? YAML.safe_load_file(path) : {}
    data ||= {}
    # poll floor is 5s; fast_poll (child-exit advancement) and the answer
    # edit debounce carry the speed.
    data["daemon"] = { "poll_interval_sec" => 5, "fast_poll_sec" => 1, "edit_debounce_sec" => 1 }
    File.write(path, data.to_yaml)
  end

  def force_headless_claude!(project)
    path = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", project, ".hive-state", "config.yml")
    data = YAML.safe_load_file(path)
    data["claude"] = (data["claude"] || {}).merge("mode" => "headless")
    # The default implementer is codex; this E2E fakes only claude, so every
    # stage must run through it.
    data["execute"] = (data["execute"] || {}).merge("agent" => "claude")
    # Keep worktrees inside the sandbox (the config default would put them
    # in the operator's real ~/Dev; config beats HIVE_WORKTREE_BASE).
    data["worktree_root"] = File.join(ENV["HIVE_TEST_HOME_ROOT"], "worktrees")
    File.write(path, data.to_yaml)
  end

  def spawn_daemon!
    env = {
      "HIVE_HOME" => ENV["HIVE_HOME"],
      # Worktrees must live INSIDE the sandbox — the project-config default
      # would land them in the operator's real ~/Dev.
      "HIVE_WORKTREE_BASE" => File.join(ENV["HIVE_TEST_HOME_ROOT"], "worktrees"),
      "PATH" => "#{SUPPORT}:#{ENV["PATH"]}",
      # The web app's bundler env must not leak into the gem's process —
      # on CI, ruby/setup-ruby exports BUNDLE_PATH pointing at web/vendor,
      # which makes the ROOT bundle's gems "not found". nil DELETES the
      # inherited key; GOLDEN_E2E_BUNDLE_PATH lets CI point at wherever it
      # installed the root bundle.
      "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile"),
      "BUNDLE_PATH" => ENV["GOLDEN_E2E_BUNDLE_PATH"],
      "BUNDLE_APP_CONFIG" => nil, "BUNDLE_DEPLOYMENT" => nil, "BUNDLE_FROZEN" => nil,
      "RUBYOPT" => nil, "RUBYLIB" => nil
    }
    # Fail fast with the REAL error: on CI a broken spawn env produced a
    # daemon that died silently before its first log line, leaving an
    # undiagnosable timeout 90s later.
    probe_out, probe_err, probe = Open3.capture3(env, "bundle", "exec", "ruby", "-Ilib",
                                                 "bin/hive", "--version", chdir: REPO_ROOT)
    unless probe.success?
      raise "daemon env probe failed (#{probe.exitstatus}): #{probe_err.strip}\n#{probe_out.strip}"
    end

    @daemon_log = ENV.fetch("GOLDEN_E2E_DAEMON_LOG", File.join(ENV["HIVE_TEST_HOME_ROOT"], "golden-daemon.log"))
    @daemon_pid = Process.spawn(env, "bundle", "exec", "ruby", "-Ilib", "bin/hive",
                                "daemon", "start", "--foreground",
                                chdir: REPO_ROOT, out: @daemon_log, err: @daemon_log)
  end
end
