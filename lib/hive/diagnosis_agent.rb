require "digest"
require "fileutils"
require "open3"
require "tempfile"
require "timeout"
require "time"
require "hive"
require "hive/agent_profiles"
require "hive/markers"
require "hive/secret_patterns"
require "hive/stages/base"

module Hive
  class DiagnosisAgent
    DEFAULT_TIMEOUT_SECONDS = 600
    DEFAULT_BUDGET_USD = 5

    def self.run!(task:, local_diagnostic: nil)
      new(task: task, local_diagnostic: local_diagnostic).run!
    end

    def initialize(task:, local_diagnostic: nil, spawn: nil)
      @task = task
      @local_diagnostic = local_diagnostic
      @spawn = spawn || method(:spawn_profile)
    end

    def run!
      cfg = Hive::Config.load(@task.project_root)
      profile = Hive::Stages::Base.stage_profile(cfg, "execute")
      profile.check_version!
      profile.preflight!

      marker = Hive::Markers.current(@task.state_file)
      output = @spawn.call(
        profile: profile,
        prompt: prompt_for(marker),
        cwd: @task.worktree_path || @task.project_root,
        add_dirs: [ @task.folder ],
        timeout_sec: cfg.dig("timeout_sec", "diagnose") || DEFAULT_TIMEOUT_SECONDS,
        max_budget_usd: cfg.dig("budget_usd", "diagnose") || DEFAULT_BUDGET_USD
      )
      artifact = artifact_body(profile: profile, marker: marker, body: output)
      path = write_artifact(redact(artifact))
      { path: path, generated_by: profile.name.to_s }
    end

    private

    def prompt_for(marker)
      <<~PROMPT
        Diagnose this Hive red task and return a concise markdown verdict.

        Use this exact structure:
        ## What Happened
        ## Can Auto-Fix Continue?
        Yes/No, with a short reason.
        ## Recommended Action
        Manual fix / autofix retry / needs user answer.

        Task: #{@task.slug}
        Stage: #{@task.stage_index}-#{@task.stage_name}
        Marker: #{marker.name}
        Marker attrs: #{marker.attrs.inspect}
        Task folder: #{@task.folder}
        Worktree: #{@task.worktree_path}

        Local diagnostic:
        #{@local_diagnostic.inspect}
      PROMPT
    end

    def artifact_body(profile:, marker:, body:)
      <<~MD
        ---
        generated_by: #{profile.name}
        marker_signature: #{marker_signature(marker)}
        diagnosed_at: #{Time.now.utc.iso8601}
        ---
        # Red Status Diagnosis

        #{body.to_s.strip}
      MD
    end

    def write_artifact(body)
      dir = File.join(@task.folder, "diagnostics")
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "red-status.md")
      Tempfile.create([ ".red-status", ".md" ], dir) do |file|
        file.write(body)
        file.flush
        file.fsync
        File.rename(file.path, path)
      end
      path
    end

    def marker_signature(marker)
      attrs = marker.attrs.sort_by { |key, _value| key.to_s }.map { |key, value| "#{key}=#{value}" }
      Digest::SHA256.hexdigest(([ marker.name.to_s ] + attrs).join("\n"))
    end

    def redact(text)
      output = text.to_s.dup
      Hive::SecretPatterns::PATTERNS.each do |name, regex|
        output.gsub!(regex, "[REDACTED:#{name}]")
      end
      output
    end

    def spawn_profile(profile:, prompt:, cwd:, add_dirs:, timeout_sec:, max_budget_usd:)
      cmd = build_cmd(profile, prompt, add_dirs, max_budget_usd)
      stdin_data = profile.name == :codex ? prompt : nil
      out, err, status = Timeout.timeout(timeout_sec) do
        Open3.capture3(*cmd, chdir: cwd, stdin_data: stdin_data)
      end
      raise Hive::Error, "diagnosis agent failed: #{err.strip.empty? ? "exit #{status.exitstatus}" : err.strip}" unless status.success?

      out
    rescue Timeout::Error
      raise Hive::Error, "diagnosis agent timed out after #{timeout_sec}s"
    end

    def build_cmd(profile, prompt, add_dirs, max_budget_usd)
      cmd = [ profile.bin ]
      cmd << profile.headless_flag if profile.headless_flag
      cmd << profile.permission_skip_flag if profile.permission_skip_flag
      if profile.add_dir_flag
        add_dirs.each { |dir| cmd << profile.add_dir_flag << dir }
      end
      cmd << profile.budget_flag << max_budget_usd.to_s if profile.budget_flag && max_budget_usd
      cmd.concat(profile.output_format_flags)
      cmd.concat(profile.extra_flags)
      cmd << (profile.name == :codex ? "-" : prompt)
      cmd
    end
  end
end
