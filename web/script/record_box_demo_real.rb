#!/usr/bin/env ruby
# Records the hivebox demo against the REAL ivankuznetsov/shipped repo with
# REAL agents — no fake claude, no fake gh. The pipeline genuinely
# brainstorms, plans, implements and opens a public PR; the camera films
# short segments at each beat while the work happens off camera between
# them. The resulting PR is publicly auditable.
#
# Interactive: when the real brainstorm asks questions, this script writes
# them to <sandbox>/questions-<round>.txt and waits for the operator to
# write <sandbox>/answers-<round>.txt (one line per question, in order).
#
#   cd web && bundle exec ruby script/record_box_demo_real.rb
#
# NOT a test: deliberate sleeps pace the footage for human eyes.
require "fileutils"
require "json"
require "net/http"
require "open3"
require "playwright"
require "timeout"
require "socket"
require "yaml"

WEB_ROOT = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../..", __dir__)
OUT_DIR = File.join(WEB_ROOT, "tmp")
REPO_URL = "https://github.com/ivankuznetsov/shipped.git"
IDEA = "Implement the pull-git command — the README promises it but it's still a stub"

sandbox = File.join(OUT_DIR, "real-take")
FileUtils.rm_rf(sandbox)
hive_home = File.join(sandbox, "hive-home")
repos = File.join(sandbox, "repos")
FileUtils.mkdir_p([ hive_home, repos, OUT_DIR ])
puts "==> sandbox: #{sandbox}"
$stdout.flush

env_base = {
  "HIVE_HOME" => hive_home,
  "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile"),
  "RUBYOPT" => nil, "RUBYLIB" => nil
}

def run!(env, *cmd, chdir: nil)
  out, err, status = Open3.capture3(env, *cmd, chdir: chdir || Dir.pwd)
  raise "#{cmd.join(' ')} failed: #{err}\n#{out}" unless status.success?

  out
end

puts "==> cloning #{REPO_URL}"
project_dir = File.join(repos, "shipped")
run!({}, "git", "clone", "-q", REPO_URL, project_dir)
run!({}, "git", "-C", project_dir, "config", "user.email", "ivan@ikuznetsov.com")
run!({}, "git", "-C", project_dir, "config", "user.name", "Ivan Kuznetsov")

File.write(File.join(hive_home, "config.yml"), {
  "web" => { "origin" => "http://127.0.0.1", "github" => { "owner" => "ivankuznetsov", "client_id" => "client" } },
  "daemon" => { "poll_interval_sec" => 5, "fast_poll_sec" => 1, "edit_debounce_sec" => 1 }
}.to_yaml)

run!(env_base, "bundle", "exec", "ruby", "-Ilib", "bin/hive", "init", project_dir, chdir: REPO_ROOT)
project_cfg = File.join(project_dir, ".hive-state", "config.yml")
cfg = YAML.safe_load_file(project_cfg)
cfg["claude"] = (cfg["claude"] || {}).merge("mode" => "headless")
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

# Answer-window detection, offset-aware so round 2+ doesn't match round 1's
# events: the brainstorm child must have EXITED and the daemon must have
# classified the task afterwards — submitting before that loses the answers
# to the baseline seed.
def wait_answer_window!(events_path, slug, from: 0, timeout: 900)
  deadline = Time.now + timeout
  loop do
    log = File.exist?(events_path) ? File.read(events_path)[from..] || "" : ""
    exited = log.match(/"child_exited".*#{Regexp.escape(slug)}|#{Regexp.escape(slug)}.*"child_exited"/)
    if exited && log[exited.end(0)..].lines.any? { |l| l.include?(slug) && l.include?("2-brainstorm") && l.match?(/"(skipped|debouncing|dispatched)"/) }
      return
    end
    raise "answer window never opened" if Time.now > deadline

    sleep 1
  end
end

def stage_glob(project_dir, slug)
  Dir[File.join(project_dir, ".hive-state", "stages", "*", slug)].first
end

# The operator (a human or an agent watching this script's output) reads the
# real questions and writes real answers — they can't be known in advance.
def collect_answers!(sandbox, brainstorm_md, round, timeout: 1200)
  q_path = File.join(sandbox, "questions-#{round}.txt")
  a_path = File.join(sandbox, "answers-#{round}.txt")
  File.write(q_path, File.read(brainstorm_md))
  puts "==> QUESTIONS round #{round}: #{q_path}"
  puts "==> waiting for #{a_path} (one line per question, in order)"
  $stdout.flush
  deadline = Time.now + timeout
  until File.file?(a_path) && !File.read(a_path).strip.empty?
    raise "no answers provided for round #{round}" if Time.now > deadline

    sleep 2
  end
  File.read(a_path).lines.map(&:strip).reject(&:empty?)
end

def type_answers(page, answers, first_delay:, rest_delay:)
  fields = page.query_selector_all("textarea[name^='answers[']")
  fields.each_with_index do |field, i|
    break if i >= answers.size

    field.click
    page.keyboard.type(answers[i], delay: i.zero? ? first_delay : rest_delay)
    sleep 0.6
  end
end

def newest_webm(existing)
  (Dir[File.join(OUT_DIR, "*.webm")] - existing).max_by { |f| File.mtime(f) }
end

def record_segment(browser, base)
  existing = Dir[File.join(OUT_DIR, "*.webm")]
  context = browser.new_context(
    viewport: { width: 1280, height: 800 },
    record_video_dir: OUT_DIR,
    record_video_size: { width: 1280, height: 800 }
  )
  page = context.new_page
  page.goto("#{base}/dev_login?as=ivan")
  page.wait_for_selector(".composer textarea")
  yield page
  Timeout.timeout(60) { context.close }
  newest_webm(existing)
end

segments = []
slug = nil
begin
  Playwright.create(playwright_cli_executable_path: "npx playwright") do |pw|
    browser = pw.chromium.launch(headless: true)

    # Segment A — the idea, typed like a human, lands on the board.
    puts "==> segment A: the idea"
    $stdout.flush
    segments << record_segment(browser, base) do |page|
      sleep 3.0
      page.click(".composer textarea")
      page.keyboard.type(IDEA, delay: 52)
      sleep 0.8
      page.click("input[type='submit'][value='Add idea']")
      page.wait_for_selector(".task-row")
      href = page.query_selector(".task-row a").get_attribute("href")
      slug = href.split("/").last
      sleep 3.4
    end
    puts "==> task: #{slug}"
    $stdout.flush

    # Off camera: the real brainstorm thinks for a while.
    wait_answer_window!(daemon_events, slug)
    log_offset = File.size(daemon_events)
    folder = stage_glob(project_dir, slug) or raise "task folder vanished"
    answers = collect_answers!(sandbox, File.join(folder, "brainstorm.md"), 1)

    # Segment B — real questions, real answers, on camera.
    puts "==> segment B: Q&A"
    $stdout.flush
    segments << record_segment(browser, base) do |page|
      page.goto("#{base}/tasks/shipped/#{slug}")
      page.wait_for_selector("textarea[name^='answers[']", timeout: 30_000)
      sleep 2.6
      type_answers(page, answers, first_delay: 40, rest_delay: 14)
      sleep 0.5
      page.click("input[type='submit'][value='Send answers']")
      sleep 2.6
    end

    # Off camera: follow-up rounds (answered without recording) until the
    # task leaves brainstorm.
    round = 1
    loop do
      folder = stage_glob(project_dir, slug) or raise "task folder vanished"
      break unless folder.include?("2-brainstorm")

      bm = File.join(folder, "brainstorm.md")
      if File.file?(bm) && File.read(bm).include?("<!-- WAITING -->")
        wait_answer_window!(daemon_events, slug, from: log_offset)
        round += 1
        more = collect_answers!(sandbox, bm, round)
        log_offset = File.size(daemon_events)
        existing = Dir[File.join(OUT_DIR, "*.webm")]
        context = browser.new_context(viewport: { width: 1280, height: 800 })
        page = context.new_page
        page.goto("#{base}/dev_login?as=ivan")
        page.goto("#{base}/tasks/shipped/#{slug}")
        page.wait_for_selector("textarea[name^='answers[']", timeout: 30_000)
        type_answers(page, more, first_delay: 1, rest_delay: 1)
        page.click("input[type='submit'][value='Send answers']")
        sleep 1
        Timeout.timeout(60) { context.close }
        _ = existing
      end
      sleep 5
    end

    # Off camera: wait for execute to be visibly under way.
    puts "==> waiting for execute"
    $stdout.flush
    deadline = Time.now + 1800
    until (f = stage_glob(project_dir, slug)) && f.include?("4-execute")
      raise "never reached execute" if Time.now > deadline

      sleep 5
    end
    sleep 25 # let the worktree agent produce some log to film

    # Segment C — agents at work: live log, execute badge.
    puts "==> segment C: execute"
    $stdout.flush
    segments << record_segment(browser, base) do |page|
      page.goto("#{base}/tasks/shipped/#{slug}")
      page.wait_for_selector(".stage-badge", timeout: 15_000)
      sleep 6.5
    end

    # Off camera: the implementation + PR creation take as long as they take.
    puts "==> waiting for the PR"
    $stdout.flush
    deadline = Time.now + 2400
    pr_md = nil
    loop do
      f = stage_glob(project_dir, slug)
      candidate = f && File.join(f, "pr.md")
      if candidate && File.file?(candidate) && File.read(candidate).include?("pr_url:")
        pr_md = candidate
        break
      end
      raise "PR never appeared" if Time.now > deadline

      sleep 10
    end
    puts "==> PR: #{File.read(pr_md)[/pr_url:\s*(\S+)/, 1]}"
    $stdout.flush
    sleep 3

    # Segment D — the payoff: the task page with the real PR link.
    puts "==> segment D: the PR"
    $stdout.flush
    segments << record_segment(browser, base) do |page|
      page.goto("#{base}/tasks/shipped/#{slug}")
      page.wait_for_selector("details[data-artifact-name='pr.md']", timeout: 15_000)
      sleep 2.4
      page.click("details[data-artifact-name='pr.md'] summary")
      sleep 7.0
    end

    Timeout.timeout(30) { browser.close }
  end
ensure
  Process.kill("TERM", daemon_pid) if daemon_pid
  Process.kill("TERM", server_pid) if server_pid
  Process.wait(server_pid) rescue nil
  Process.wait(daemon_pid) rescue nil
end

raise "missing segments: #{segments.inspect}" unless segments.size == 4 && segments.all? { |s| s && File.exist?(s) }

list = File.join(OUT_DIR, "box-demo-real-concat.txt")
named = segments.each_with_index.map do |seg, i|
  dest = File.join(OUT_DIR, "box-demo-real-#{i}.webm")
  FileUtils.mv(seg, dest)
  dest
end
File.write(list, named.map { |s| "file '#{s}'\n" }.join)
out_mp4 = File.join(OUT_DIR, "box-demo-real.mp4")
system("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", list,
       "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
       "-crf", "23", "-movflags", "+faststart", "-an", out_mp4,
       out: File::NULL, err: File::NULL) or raise "ffmpeg failed"
dur = `ffprobe -v error -show_entries format=duration -of csv=p=0 #{out_mp4}`.strip
puts "==> done: #{out_mp4} (#{dur}s)"
