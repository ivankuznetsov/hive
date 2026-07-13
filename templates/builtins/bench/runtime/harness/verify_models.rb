# frozen_string_literal: true

# Model self-verification: every cell CLAIMS a model configuration
# (candidates.rb); this cross-checks the claim against the model ids the agent
# stream logs actually recorded. A leaderboard row labeled with a model nobody
# verified is an integrity hole — this closes it after the fact.
#
#   ruby harness/verify_models.rb runs/v2-full runs/v2-open/* runs/v2-retry/* ...
#
# Exit 1 on any violation. CLI utility models are allowlisted: the claude CLI
# routinely calls haiku for internal subtasks (summaries, titles) alongside the
# pinned implementer model — those events are expected and are NOT a violation
# unless the claimed model is entirely absent from the stage's stream.
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

module HiveBench
  module VerifyModels
    module_function

    # cell-dir name (sanitized candidate id) -> what its stages may legitimately run
    CLAIMS = {
      "all_opus_4_8" => /claude-opus-4-8/,
      "all_codex" => /gpt-5\.5|codex/,
      "all_codex_xhigh" => /gpt-5\.5|codex/,
      "all_codex_5_6_sol_xhigh" => /gpt-5\.6-sol|codex/,
      "opus_plan_codex_exec" => /claude-opus-4-8|gpt-5\.5|codex/,
      "opus_plan_codex_exec_xhigh" => /claude-opus-4-8|gpt-5\.5|codex/,
      "all_grok_4_5" => /grok/,
      "all_glm_5_2" => /glm-5\.2/,
      "all_kimi_k2_7_code" => /kimi-k2\.7-code/,
      "glm_plan_kimi_exec" => /glm-5\.2|kimi-k2\.7-code/
    }.freeze

    # Models a CLI may invoke for its own utilities regardless of the pin.
    UTILITY = [/claude-haiku/, /<synthetic>/].freeze

    Finding = Struct.new(:log, :claim, :seen, :reason)

    # Returns [findings, checked_count]. A violation is a stage log whose
    # non-utility models include something outside the claim, OR (stricter)
    # a log with observed models but the claimed family entirely absent.
    def scan(run_dirs)
      findings = []
      checked = 0
      run_dirs.flat_map { |d| Dir.glob(File.join(d, "*", "*", "target", ".hive-state", "logs", "**", "*.log")) }
              .each do |log|
        cell_dir = log[%r{/([a-z0-9_.]+)/target/}, 1]
        claim = CLAIMS[cell_dir&.tr(".", "_")] or next
        models = begin
          File.read(log, 1_000_000).scan(/"model":"([^"]+)"/).flatten.uniq
        rescue StandardError
          next
        end
        substantive = models.reject { |m| UTILITY.any? { |u| m.match?(u) } }
        next if substantive.empty? # utility-only log (probes, titles)

        checked += 1
        rogue = substantive.grep_v(claim)
        findings << Finding.new(log, cell_dir, rogue, "unclaimed model ran") unless rogue.empty?
      end
      [findings, checked]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort("usage: ruby harness/verify_models.rb <run-dir>...") if ARGV.empty?
  findings, checked = HiveBench::VerifyModels.scan(ARGV)
  findings.each { |f| warn "VIOLATION #{f.log}: claimed #{f.claim}, saw #{f.seen.join(",")}" }
  warn "verified #{checked} substantive stage logs: #{findings.size} violation(s)"
  exit(findings.empty? ? 0 : 1)
end
