# frozen_string_literal: true

module HiveBench
  # Scoring tier 2 — the blind, family-disjoint LLM judge. Grades one candidate
  # diff against the task on an absolute rubric (the reference is a *signal*, not
  # "closest wins"), with the bias defenses the research prescribed:
  #   - blind: the agent's identity never enters the prompt (the caller passes
  #     only plan + diff + optional reference; this class adds no agent id).
  #   - verbosity-neutral: the rubric instructs the judge to ignore diff length.
  #   - stability: the judge is sampled across N seeds; the result carries the
  #     mean AND a spread (stddev) so the leaderboard can mark close cells as ties.
  #   - ablation: `reference: nil` runs the reference-withheld variant (R24) to
  #     bound incumbent-anchoring.
  #
  # The judge model invocation is a seam (`judge_fn`) so the family-disjoint
  # model choice + live calls live at the edge, and tests run offline.
  class Judge
    Result = Data.define(:mean, :stddev, :scores, :interval, :reference_withheld, :reasons) do
      # reasons defaults empty so pre-existing constructions (tests, merge paths)
      # stay valid — older records simply carry no rationale.
      def initialize(reasons: [], **rest) = super

      # Two cells are a tie when their judge intervals overlap — the leaderboard
      # must not order within noise.
      def ties_with?(other)
        interval.first <= other.interval.last && other.interval.first <= interval.last
      end
    end

    PROMPT_PATH = File.expand_path("judge-prompt.md", __dir__)

    # judge_fn: ->(prompt:, seed:) => { score: Float, reason: String }
    def initialize(judge_fn:, seeds: 3, template: nil)
      raise ArgumentError, "seeds must be >= 1" if seeds < 1

      @judge_fn = judge_fn
      @seeds = seeds
      @template = template || File.read(PROMPT_PATH)
    end

    def call(plan:, candidate_diff:, reference: nil)
      prompt = render(plan: plan, candidate_diff: candidate_diff, reference: reference)
      verdicts = (1..@seeds).map { |seed| @judge_fn.call(prompt: prompt, seed: seed) }
      aggregate(verdicts.map { |v| clamp(v.fetch(:score)) },
                reasons: verdicts.map { |v| v[:reason].to_s },
                reference_withheld: reference.nil?)
    end

    # Builds the judge prompt. Public so tests can assert blinding/verbosity rules.
    def render(plan:, candidate_diff:, reference:)
      ref_section = if reference.nil? || reference.to_s.strip.empty?
                      "(No reference provided — grade on the task alone.)"
                    else
                      "<reference>\n#{reference}\n</reference>"
                    end
      # Block form (not the 2-arg string form): substituted diffs/plans routinely
      # contain backslash sequences (regex literals, escapes, Windows paths), and
      # the 2-arg gsub would interpret \0/\1/\\ as backreferences, silently
      # mangling the candidate shown to the judge.
      @template
        .gsub("{{PLAN}}") { plan.to_s }
        .gsub("{{REFERENCE_SECTION}}") { ref_section }
        .gsub("{{CANDIDATE}}") { candidate_diff.to_s }
    end

    private

    def aggregate(scores, reference_withheld:, reasons: [])
      mean = scores.sum.to_f / scores.size
      var = scores.map { |s| (s - mean)**2 }.sum / scores.size
      stddev = Math.sqrt(var)
      Result.new(
        mean: mean.round(3), stddev: stddev.round(3), scores: scores, reasons: reasons,
        interval: [(mean - stddev).round(3), (mean + stddev).round(3)],
        reference_withheld: reference_withheld
      )
    end

    def clamp(score)
      Float(score).clamp(0.0, 10.0)
    rescue ArgumentError, TypeError
      0.0
    end
  end
end
