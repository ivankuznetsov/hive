require "test_helper"
require "hive/stages/review/guardrail_waivers"

class HiveStagesReviewGuardrailWaiversTest < Minitest::Test
  def test_resolve_accepts_exact_waivers_and_rejects_malformed_entries
    waiver = { "pattern" => "secrets.password", "sha256" => "A" * 64 }

    assert_equal Set[[ "secrets.password", "a" * 64 ]],
                 Hive::Stages::Review::GuardrailWaivers.resolve(
                   "review" => { "fix" => { "guardrail" => { "waivers" => [ waiver ] } } }
                 )

    error = assert_raises(Hive::ConfigError) do
      Hive::Stages::Review::GuardrailWaivers.resolve(
        "review" => { "fix" => { "guardrail" => { "waivers" => [ "invalid" ] } } }
      )
    end
    assert_match(/pattern and sha256/, error.message)

    error = assert_raises(Hive::ConfigError) do
      Hive::Stages::Review::GuardrailWaivers.resolve(
        "review" => { "fix" => { "guardrail" => { "waivers" => [ { pattern: "" } ] } } }
      )
    end
    assert_match(/pattern and SHA-256/, error.message)
  end
end
