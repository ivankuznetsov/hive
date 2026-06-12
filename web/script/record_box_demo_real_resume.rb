#!/usr/bin/env ruby
# Resumes record_box_demo_real.rb after the plan agent hit the Claude
# session limit: segments A (idea) and B (Q&A) are already on disk; the
# task is stranded in 3-plan with an ERROR marker in an otherwise empty
# plan.md. Deleting that plan.md clears the error and the daemon reruns
# the stage fresh — brainstorm.md (answered, COMPLETE) is intact, so the
# plan agent keeps its full context. Films segments C + D and concats all
# four into box-demo-real.mp4.
#
#   cd web && bundle exec ruby script/record_box_demo_real_resume.rb \
#     <segment-a.webm> <segment-b.webm>
require "fileutils"
require "net/http"
require "open3"
require "playwright"
require "timeout"
require "socket"

WEB_ROOT = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../..", __dir__)
OUT_DIR = File.join(WEB_ROOT, "tmp")

seg_a, seg_b = ARGV[0], ARGV[1]
raise "usage: resume <seg-a.webm> <seg-b.webm>" unless seg_a && File.file?(seg_a) && seg_b && File.file?(seg_b)

sandbox = File.join(OUT_DIR, "real-take")
hive_home = File.join(sandbox, "hive-home")
project_dir = File.join(sandbox, "repos", "shipped")
slug = "implement-the-pull-git-command-260612-bd0e"
raise "sandbox missing" unless File.directory?(project_dir)

env_base = {
  "HIVE_HOME" => hive_home,
  "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile"),
  "RUBYOPT" => nil, "RUBYLIB" => nil
}

def stage_glob(project_dir, slug)
  Dir[File.join(project_dir, ".hive-state", "stages", "*", slug)].first
end

folder = stage_glob(project_dir, slug) or raise "task folder vanished"
if folder.include?("3-plan")
  plan_md = File.join(folder, "plan.md")
  if File.file?(plan_md) && File.read(plan_md).include?("<!-- ERROR")
    FileUtils.rm_f([ plan_md, "#{plan_md}.markers-lock" ])
    puts "==> cleared stranded plan error marker"
  end
end

puts "==> booting rails + daemon"
port = TCPServer.open(0) { |s| s.addr[1] }
server_env = env_base.merge("HIVEBOX_STORAGE_DIR" => File.join(sandbox, "storage"),
                            "RAILS_ENV" => "development",
                            "BUNDLE_GEMFILE" => File.join(WEB_ROOT, "Gemfile"))
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

seg_c = seg_d = nil
begin
  Playwright.create(playwright_cli_executable_path: "npx playwright") do |pw|
    browser = pw.chromium.launch(headless: true)

    puts "==> waiting for execute"
    $stdout.flush
    deadline = Time.now + 1800
    until (f = stage_glob(project_dir, slug)) && f.include?("4-execute")
      raise "never reached execute" if Time.now > deadline

      sleep 5
    end
    sleep 25

    puts "==> segment C: execute"
    $stdout.flush
    seg_c = record_segment(browser, base) do |page|
      page.goto("#{base}/tasks/shipped/#{slug}")
      page.wait_for_selector(".stage-badge", timeout: 15_000)
      sleep 6.5
    end

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

    puts "==> segment D: the PR"
    $stdout.flush
    seg_d = record_segment(browser, base) do |page|
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

segments = [ seg_a, seg_b, seg_c, seg_d ]
raise "missing segments: #{segments.inspect}" unless segments.all? { |s| s && File.exist?(s) }

named = segments.each_with_index.map do |seg, i|
  dest = File.join(OUT_DIR, "box-demo-real-#{i}.webm")
  FileUtils.cp(seg, dest) unless seg == dest
  dest
end
list = File.join(OUT_DIR, "box-demo-real-concat.txt")
File.write(list, named.map { |s| "file '#{s}'\n" }.join)
out_mp4 = File.join(OUT_DIR, "box-demo-real.mp4")
system("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", list,
       "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
       "-crf", "23", "-movflags", "+faststart", "-an", out_mp4,
       out: File::NULL, err: File::NULL) or raise "ffmpeg failed"
dur = `ffprobe -v error -show_entries format=duration -of csv=p=0 #{out_mp4}`.strip
puts "==> done: #{out_mp4} (#{dur}s)"
