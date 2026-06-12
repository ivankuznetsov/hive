#!/usr/bin/env ruby
# Records the hivebox "from idea to PR" demo reel (~45s) in a real browser
# against a STAGED local box: real Rails server, real `hive daemon`, real
# git worktree/commits — only the agent is the stage-aware fake claude from
# the golden-path E2E, so the pipeline advances in seconds instead of
# minutes. Produces tmp/box-demo.webm + tmp/box-demo.mp4.
#
#   cd web && bundle exec ruby script/record_box_demo.rb
#
# NOT a test: deliberate sleeps pace the footage for human eyes.
require "fileutils"
require "json"
require "net/http"
require "open3"
require "playwright"
require "timeout"
require "socket"
require "tmpdir"
require "yaml"

WEB_ROOT = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../..", __dir__)
SUPPORT = File.join(WEB_ROOT, "test", "e2e", "support")
OUT_DIR = File.join(WEB_ROOT, "tmp")
IDEA = "Add a dark mode toggle to the settings page"
ANSWER = "Yes — light & dark, follow the system setting."

sandbox = Dir.mktmpdir("box-demo")
hive_home = File.join(sandbox, "hive-home")
repos = File.join(sandbox, "repos")
FileUtils.mkdir_p([ hive_home, repos, OUT_DIR ])

demo_bin = File.join(sandbox, "bin")
FileUtils.mkdir_p(demo_bin)
# The demo claude extends the E2E fake with an open-pr personality: that
# stage's AGENT owns `gh pr create` + pr.md (cwd there is the worktree, so
# the stage is keyed on --add-dir instead).
File.write(File.join(demo_bin, "claude"), <<~SH)
  #!/usr/bin/env bash
  set -u
  if [[ "${1:-}" == "--version" ]]; then
    printf '%s (Claude Code)\n' "2.1.118"; exit 0
  fi
  task_dir=""; prev=""
  for a in "$@"; do
    [[ "$prev" == "--add-dir" ]] && task_dir="$a"
    prev="$a"
  done
  if [[ "$task_dir" == */5-open-pr/* ]]; then
    url="https://github.com/ivan/demo-app/pull/42"
    gh pr create --draft --title "Add a dark mode toggle" --head demo >/dev/null 2>&1 || true
    cat > "$task_dir/pr.md" <<EOF
  ---
  pr_url: $url
  pr_number: 42
  ---

  # PR #42 — Add a dark mode toggle to the settings page

  Adds a \`theme\` setting (light / dark / system), persists it per user,
  and applies it via a `data-theme` attribute. Tests cover the toggle and
  the system-preference fallback.

  [$url]($url)

  <!-- COMPLETE pr_url=$url is_draft=true -->
  EOF
    exit 0
  fi
  cwd="$(pwd)"
  # The camera needs to SEE stages run: a real agent thinks for minutes,
  # the fake for a beat or two.
  case "$cwd" in
    */stages/2-brainstorm/*)
      sleep 2.0
      if ! grep -q '^### Q1' brainstorm.md 2>/dev/null; then
        printf '### Q1. Should dark mode follow the system setting?\n\n### A1.\n\n<!-- WAITING -->\n' > brainstorm.md
      else
        answered="$(awk '/^### A1\./{f=1;next} /^###|^<!--/{f=0} f && NF {print "yes"; exit}' brainstorm.md)"
        if [[ "$answered" == "yes" ]]; then
          grep -v '<!--' brainstorm.md > brainstorm.md.tmp
          printf '\n<!-- COMPLETE -->\n' >> brainstorm.md.tmp
          mv brainstorm.md.tmp brainstorm.md
        fi
      fi
      ;;
    */stages/3-plan/*)
      sleep 3.0
      printf '# Plan\n\n1. Add a theme setting (light / dark / system).\n2. Persist per user; apply via data-theme.\n3. Tests for toggle + system fallback.\n\n<!-- COMPLETE -->\n' > plan.md
      ;;
    *worktrees/*)
      sleep 3.2
      printf 'theme toggle implemented\n' > implementation.txt
      git add implementation.txt
      git -c user.email=demo@hivecli.sh -c user.name="Hive Demo" \
        commit -qm "feat: add dark mode toggle" || true
      ;;
    *)
      printf 'Dark Mode Toggle\n'
      ;;
  esac
  exit 0
SH
FileUtils.chmod(0o755, File.join(demo_bin, "claude"))
File.write(File.join(demo_bin, "gh"), <<~SH)
  #!/usr/bin/env bash
  # Demo gh: enough for the open-pr runner — auth ok, create prints the
  # pretty URL, list reports the PR once created.
  set -u
  STATE="#{sandbox}/gh-pr-created"
  case "${1:-} ${2:-}" in
    "auth status") exit 0 ;;
    "pr create") touch "$STATE"; echo "https://github.com/ivan/demo-app/pull/42" ;;
    "pr list")
      if [ -f "$STATE" ]; then
        printf '[{"url":"https://github.com/ivan/demo-app/pull/42","number":42,"state":"OPEN","isDraft":true,"headRefOid":"%s","headRefName":"%s"}]\n' \
          "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
          "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
      else
        echo '[]'
      fi ;;
    *) exit 0 ;;
  esac
SH
FileUtils.chmod(0o755, File.join(demo_bin, "gh"))

env_base = {
  "HIVE_HOME" => hive_home,
  "PATH" => "#{demo_bin}:#{ENV["PATH"]}",
  "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile"),
  "RUBYOPT" => nil, "RUBYLIB" => nil
}

def run!(env, *cmd, chdir: nil)
  out, err, status = Open3.capture3(env, *cmd, chdir: chdir || Dir.pwd)
  raise "#{cmd.join(' ')} failed: #{err}\n#{out}" unless status.success?

  out
end

puts "==> staging project"
project_dir = File.join(repos, "demo-app")
FileUtils.mkdir_p(project_dir)
run!({}, "git", "init", "-q", project_dir)
run!({}, "git", "-C", project_dir, "config", "user.email", "demo@hivecli.sh")
run!({}, "git", "-C", project_dir, "config", "user.name", "Hive Demo")
File.write(File.join(project_dir, "README.md"), "# demo-app\n")
run!({}, "git", "-C", project_dir, "add", ".")
run!({}, "git", "-C", project_dir, "commit", "-qm", "init")
# A local bare origin lets the REAL open-pr stage push offline.
bare = File.join(sandbox, "origin.git")
run!({}, "git", "init", "-q", "--bare", bare)
run!({}, "git", "-C", project_dir, "remote", "add", "origin", bare)
run!({}, "git", "-C", project_dir, "push", "-q", "origin", "HEAD")

File.write(File.join(hive_home, "config.yml"), {
  "web" => { "origin" => "http://127.0.0.1", "github" => { "owner" => "ivan", "client_id" => "client" } },
  "daemon" => { "poll_interval_sec" => 5, "fast_poll_sec" => 1, "edit_debounce_sec" => 1 }
}.to_yaml)

run!(env_base, "bundle", "exec", "ruby", "-Ilib", "bin/hive", "init", project_dir, chdir: REPO_ROOT)
project_cfg = File.join(project_dir, ".hive-state", "config.yml")
cfg = YAML.safe_load_file(project_cfg)
cfg["claude"] = (cfg["claude"] || {}).merge("mode" => "headless")
cfg["execute"] = (cfg["execute"] || {}).merge("agent" => "claude")
cfg["worktree_root"] = File.join(sandbox, "worktrees")
File.write(project_cfg, cfg.to_yaml)

puts "==> booting rails + daemon"
port = TCPServer.open(0) { |s| s.addr[1] }
storage = File.join(sandbox, "storage")
server_env = env_base.merge("HIVEBOX_STORAGE_DIR" => storage, "RAILS_ENV" => "development",
                            "BUNDLE_GEMFILE" => File.join(WEB_ROOT, "Gemfile"))
run!(server_env, "bin/rails", "db:prepare", chdir: WEB_ROOT)
server_pid = Process.spawn(server_env, "bin/rails", "server", "-p", port.to_s,
                           "-P", File.join(sandbox, "server.pid"),
                           chdir: WEB_ROOT, out: File.join(sandbox, "server.log"),
                           err: File.join(sandbox, "server.log"))
daemon_pid = Process.spawn(env_base, "bundle", "exec", "ruby", "-Ilib", "bin/hive",
                           "daemon", "start", "--foreground",
                           chdir: REPO_ROOT, out: File.join(sandbox, "daemon.log"),
                           err: File.join(sandbox, "daemon.log"))

base = "http://127.0.0.1:#{port}"
healthy = false
60.times do
  healthy = (Net::HTTP.get_response(URI("#{base}/health")).is_a?(Net::HTTPSuccess) rescue false)
  break if healthy

  sleep 1
end
raise "rails server never became healthy — #{File.join(sandbox, 'server.log')}" unless healthy

daemon_events = File.join(hive_home, "logs", "daemon.log")

def wait_answer_window!(events_path, slug, timeout: 60)
  deadline = Time.now + timeout
  loop do
    log = File.exist?(events_path) ? File.read(events_path) : ""
    exited = log.match(/"child_exited".*#{Regexp.escape(slug)}|#{Regexp.escape(slug)}.*"child_exited"/)
    if exited && log[exited.end(0)..].lines.any? { |l| l.include?(slug) && l.include?("2-brainstorm") && l.match?(/"(skipped|debouncing|dispatched)"/) }
      return
    end
    raise "answer window never opened" if Time.now > deadline

    sleep 0.2
  end
end

def newest_webm(existing)
  (Dir[File.join(OUT_DIR, "*.webm")] - existing).max_by { |f| File.mtime(f) }
end

video = nil
begin
  Playwright.create(playwright_cli_executable_path: "npx playwright") do |pw|
    browser = pw.chromium.launch(headless: true)
    context = browser.new_context(
      viewport: { width: 1280, height: 800 },
      record_video_dir: OUT_DIR,
      record_video_size: { width: 1280, height: 800 }
    )
    page = context.new_page
    webms_before_a = Dir[File.join(OUT_DIR, "*.webm")]

    puts "==> recording"
    $stdout.flush
    page.goto("#{base}/dev_login?as=ivan")
    page.wait_for_selector(".composer textarea")
    sleep 3.0

    # Beat 1 — the idea, typed like a human.
    page.click(".composer textarea")
    page.keyboard.type(IDEA, delay: 52)
    sleep 0.8
    page.click("input[type='submit'][value='Add idea']")
    page.wait_for_selector(".task-row")
    sleep 3.2

    # Beat 2 — open the task; the daemon's brainstorm asks a question.
    page.click(".task-row a")
    page.wait_for_selector("textarea[name='answers[1]']", timeout: 60_000)
    slug = page.url.split("/").last
    wait_answer_window!(daemon_events, slug)
    sleep 2.0
    page.click("textarea[name='answers[1]']")
    page.keyboard.type(ANSWER, delay: 42)
    sleep 0.5
    page.click("input[type='submit'][value='Send answers']")
    sleep 2.4

    # Beat 3 — hands off: the pipeline advances live (push morphs, no
    # reloads). The camera lingers; the script only waits for the terminal
    # milestone — individual badges can flash by faster than a wait can
    # register them.
    page.wait_for_selector(
      ".task-meta:has-text('Ready to open PR'), .stage-badge:has-text('open-pr'), .stage-badge:has-text('review')",
      timeout: 120_000
    )
    sleep 3.4

    # CUT — segment A ends here. The daemon blows through open-pr and
    # into review within a tick; instead of fighting that race on camera,
    # segment B is a clean shot of the PR state. Video paths come from the
    # filesystem, not page.video.path — that call rides the playwright
    # channel and can futex-wedge forever; the dir is ours anyway. Each
    # close gets a hard deadline for the same reason.
    sleep 0.4
    Timeout.timeout(60) { context.close }
    video = newest_webm(webms_before_a)
    puts "==> segment A: #{video}"
    $stdout.flush

    # Off camera: freeze the world at "PR opened".
    Process.kill("KILL", daemon_pid)
    Process.wait(daemon_pid)
    daemon_pid = nil
    # Strays from the daemon's last tick — argv contains demo-app, which is
    # unique to this sandbox (the operator's real daemons never see it).
    system("pkill", "-KILL", "-f", "bin/hive (open-pr|review|artifacts|finalize).*demo-app")
    sleep 0.5
    folder = Dir[File.join(project_dir, ".hive-state", "stages", "*", "*")].first
    slug = File.basename(folder)
    if folder.include?("4-execute")
      run!(env_base, "bundle", "exec", "ruby", "-Ilib", "bin/hive",
           "open-pr", slug, "--project", "demo-app", "--from", "4-execute",
           chdir: REPO_ROOT)
    elsif folder.include?("6-review")
      target = folder.sub("6-review", "5-open-pr")
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.mv(folder, target)
      task_md = File.join(target, "task.md")
      if File.file?(task_md)
        File.write(task_md, File.read(task_md).gsub(/<!--\s*REVIEW[^>]*-->\n?/, ""))
      end
    end

    # Segment B — the payoff: the task page at open-pr with the PR link.
    webms_before_b = Dir[File.join(OUT_DIR, "*.webm")]
    context = browser.new_context(
      viewport: { width: 1280, height: 800 },
      record_video_dir: OUT_DIR,
      record_video_size: { width: 1280, height: 800 }
    )
    page = context.new_page
    page.goto("#{base}/dev_login?as=ivan")
    page.wait_for_selector(".composer textarea")
    page.goto("#{base}/tasks/demo-app/#{slug}")
    page.wait_for_selector(".stage-badge:has-text('open-pr')", timeout: 15_000)
    sleep 2.4
    page.click("details[data-artifact-name='pr.md'] summary")
    sleep 7.0
    Timeout.timeout(60) { context.close }
    @video_b = newest_webm(webms_before_b)
    puts "==> segment B: #{@video_b}"
    $stdout.flush
    Timeout.timeout(30) { browser.close }
  end
ensure
  Process.kill("TERM", daemon_pid) if daemon_pid
  Process.kill("TERM", server_pid) if server_pid
  Process.wait(server_pid) rescue nil
end

video_b = @video_b
raise "no video produced" unless video && File.exist?(video) && video_b && File.exist?(video_b)

seg_a = File.join(OUT_DIR, "box-demo-a.webm")
seg_b = File.join(OUT_DIR, "box-demo-b.webm")
FileUtils.mv(video, seg_a)
FileUtils.mv(video_b, seg_b)
out_mp4 = File.join(OUT_DIR, "box-demo.mp4")
list = File.join(OUT_DIR, "box-demo-concat.txt")
File.write(list, "file '#{seg_a}'\nfile '#{seg_b}'\n")
system("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", list,
       "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
       "-crf", "23", "-movflags", "+faststart", "-an", out_mp4,
       out: File::NULL, err: File::NULL) or raise "ffmpeg failed"
dur = `ffprobe -v error -show_entries format=duration -of csv=p=0 #{out_mp4}`.strip
puts "==> done: #{out_mp4} (#{dur}s)"
FileUtils.rm_rf(sandbox) if ENV["KEEP_SANDBOX"].nil?
