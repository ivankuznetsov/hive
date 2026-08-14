require "test_helper"
require "hive/artifacts/outcome_evidence/document"

class OutcomeEvidenceDocumentTest < Minitest::Test
  Document = Hive::Artifacts::OutcomeEvidence::Document

  def test_rejects_nonobject_and_schema_invalid_json
    error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Document.parse(
        "[]", schema: "hive-outcome-evidence-requirement",
        label: "requirement"
      )
    end
    assert_match(/JSON object/, error.message)

    error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Document.parse(
        "{}", schema: "hive-outcome-evidence-requirement",
        label: "requirement"
      )
    end
    assert_match(%r{/.*required|violates}, error.message)
  end
end
