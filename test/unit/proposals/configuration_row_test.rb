require "test_helper"
require "hive/proposals/configuration_row"

class ProposalConfigurationRowTest < Minitest::Test
  def test_evaluator_rows_normalize_and_reject_unknown_fields_and_oversize_entries
    row = { "workflows" => %w[coding bench], "stages" => [ "4-execute" ], "agent_profiles" => [] }
    assert_equal(
      { "workflows" => %w[bench coding], "stages" => [ "4-execute" ], "agent_profiles" => [] },
      Hive::Proposals::ConfigurationRow.evaluator!(row)
    )

    unknown = assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::ConfigurationRow.evaluator!(row.merge("models" => [], "extra" => []))
    end
    assert_includes unknown.message, "unknown fields: extra, models"

    oversize = assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::ConfigurationRow.evaluator!(row.merge("stages" => [ "s" * 129 ]))
    end
    assert_includes oversize.message, "stages entry exceeds 128 bytes"
  end
end
