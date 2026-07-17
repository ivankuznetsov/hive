# frozen_string_literal: true

require "judge"

module HiveBench
  # Judge deliberation: after each judge independently grades a diff (round 1,
  # the existing blind rubric), the verdicts are shared — anonymized — and each
  # judge writes one discussion round responding to the others' specific points,
  # then gives a final score (round 2).
  #
  # DIAGNOSTIC, not the leaderboard score. The published number stays the
  # round-1 independent mean: a discussion round can surface real misses (one
  # judge caught a deleted guard the other skimmed past), but it also risks
  # anchoring — agreement bought by convergence pressure is not agreement about
  # the diff. Recording both rounds makes that measurable instead of invisible:
  # a judge that revises only when shown a concrete factual claim is behaving
  # like a referee; one that always meets the other in the middle is not.
  #
  # Blinding is preserved: judges are presented to each other as "Referee B",
  # never by model name, and the prompt forbids identity speculation.
  class Deliberation
    PROMPT_PATH = File.expand_path("../deliberate-prompt.md", __dir__)

    Verdict = Data.define(:initial, :initial_reason, :final, :final_reason, :discussion) do
      def revised? = !final.nil? && (final - initial).abs >= 0.05
      def delta = final && (final - initial).round(3)
    end

    # judge_fns: { "<name>" => ->(prompt:, seed:) => { score:, reason:, discussion?: } }
    def initialize(judge_fns:, judge_template: nil, deliberate_template: nil)
      raise ArgumentError, "deliberation needs >= 2 judges" if judge_fns.size < 2

      @judge_fns = judge_fns
      @round1 = Judge.new(judge_fn: ->(*) {}, template: judge_template).method(:render)
      @template = deliberate_template || File.read(PROMPT_PATH)
    end

    # Returns { "<judge-name>" => Verdict }. Fail-soft per judge and per round:
    # a judge that errors in round 1 sits out entirely; one that errors in
    # round 2 keeps its initial verdict with final=nil (recorded, not invented).
    def call(plan:, candidate_diff:, reference: nil)
      initial = round_one(plan, candidate_diff, reference)
      return {} if initial.size < 2 # nothing to discuss

      round_two(initial, plan, candidate_diff, reference)
    end

    private

    def round_one(plan, diff, reference)
      prompt = @round1.call(plan: plan, candidate_diff: diff, reference: reference)
      @judge_fns.filter_map do |name, fn|
        v = fn.call(prompt: prompt, seed: 1)
        [name, { score: Float(v.fetch(:score)).clamp(0.0, 10.0), reason: v[:reason].to_s }]
      rescue StandardError => e
        warn "deliberation: #{name} failed round 1 (#{e.class}: #{e.message.to_s[0, 80]}) — sitting out"
        nil
      end.to_h
    end

    def round_two(initial, plan, diff, reference)
      initial.to_h do |name, own|
        prompt = render_discussion(own: own, others: initial.except(name), plan: plan,
                                   diff: diff, reference: reference)
        final = begin
          @judge_fns.fetch(name).call(prompt: prompt, seed: 2)
        rescue StandardError => e
          warn "deliberation: #{name} failed round 2 (#{e.class}: #{e.message.to_s[0, 80]}) — keeping initial"
          nil
        end
        [name, Verdict.new(
          initial: own[:score], initial_reason: own[:reason],
          final: final && Float(final.fetch(:score)).clamp(0.0, 10.0),
          final_reason: final && final[:reason].to_s,
          discussion: final && final[:discussion].to_s
        )]
      end
    end

    # Other judges appear as "Referee B/C/…" — order-stable but nameless, so a
    # judge can address a specific verdict without learning whose it is.
    def render_discussion(own:, others:, plan:, diff:, reference:)
      other_block = others.each_with_index.map do |(_name, v), i|
        "<referee-#{("B".ord + i).chr}>\nscore: #{v[:score]}\nreason: #{v[:reason]}\n</referee-#{("B".ord + i).chr}>"
      end.join("\n\n")
      ref_section = if reference.nil? || reference.to_s.strip.empty?
                      "(No reference provided — discuss on the task alone.)"
                    else
                      "<reference>\n#{reference}\n</reference>"
                    end
      # Block-form gsub throughout: diffs/reasons routinely contain backslash
      # sequences the 2-arg form would mangle as backreferences.
      @template
        .gsub("{{PLAN}}") { plan.to_s }
        .gsub("{{REFERENCE_SECTION}}") { ref_section }
        .gsub("{{CANDIDATE}}") { diff.to_s }
        .gsub("{{OWN_SCORE}}") { own[:score].to_s }
        .gsub("{{OWN_REASON}}") { own[:reason].to_s }
        .gsub("{{OTHER_VERDICTS}}") { other_block }
    end
  end
end
