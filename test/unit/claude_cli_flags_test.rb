require "test_helper"
require "hive/config"

# The model/effort → argv table is asymmetric on purpose: model "default" is
# a LIVE Claude Code alias and passes through, while effort "default" means
# "omit the flag, keep Claude Code's own tier". Pinning the table prevents a
# refactor from re-symmetrizing it — which would either send a bogus
# `--effort default` or stop pinning the model, silently re-inheriting the
# operator's expensive interactive selection (the production bug the feature
# exists to fix).
class ClaudeCliFlagsTest < Minitest::Test
  CASES = {
    # cfg claude block            => expected flags
    nil                           => [ "--model", "default" ],
    {}                            => [ "--model", "default" ],
    { "model" => "default" }      => [ "--model", "default" ],
    { "model" => "inherit" }      => [],
    { "model" => "  " }           => [],
    { "model" => "sonnet" }       => [ "--model", "sonnet" ],
    { "effort" => "default" }     => [ "--model", "default" ],
    { "effort" => "inherit" }     => [ "--model", "default" ],
    { "effort" => "low" }         => [ "--model", "default", "--effort", "low" ],
    { "model" => "sonnet", "effort" => "high" } => [ "--model", "sonnet", "--effort", "high" ],
    { "model" => "inherit", "effort" => "xhigh" } => [ "--effort", "xhigh" ]
  }.freeze

  def test_flag_table
    CASES.each do |claude, expected|
      cfg = claude.nil? ? {} : { "claude" => claude }
      assert_equal expected, Hive::Config.claude_cli_flags(cfg),
                   "claude config #{claude.inspect} must resolve to #{expected.inspect}"
    end
  end

  def test_stage_resolution_is_field_independent
    cfg = {
      "claude" => { "model" => "default", "effort" => "default" },
      "models" => {
        "review" => { "model" => "opus", "effort" => "high" },
        "review_fix" => { "model" => "sonnet" }
      }
    }

    assert_equal [ "--model", "sonnet", "--effort", "high" ],
                 Hive::Config.claude_cli_flags(cfg, stage: :review_fix)
  end

  def test_no_stage_ignores_models_map
    cfg = {
      "claude" => { "model" => "default", "effort" => "low" },
      "models" => { "plan" => { "model" => "opus", "effort" => "high" } }
    }

    assert_equal [ "--model", "default", "--effort", "low" ],
                 Hive::Config.claude_cli_flags(cfg)
  end
end
