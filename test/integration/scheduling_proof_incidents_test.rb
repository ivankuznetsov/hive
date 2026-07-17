require "test_helper"
require "hive/scheduling_proof"

class SchedulingProofIncidentsTest < Minitest::Test
  FIXTURES = Dir[File.expand_path("../fixtures/scheduling_proofs/*/input.json", __dir__)].sort.freeze

  def test_sanitized_incidents_are_explainable_from_proof_objects_alone
    assert_equal 4, FIXTURES.size

    FIXTURES.each do |path|
      fixture = JSON.parse(File.read(path))
      now = Time.iso8601(fixture.fetch("as_of"))
      observation = fixture.fetch("observation")
      proof = Hive::SchedulingProof::Projector.new(
        as_of: now, daemon_running: true, heartbeat_at: now - 5, poll_interval_sec: 30
      ).project_task(
        row: fixture.fetch("row"), enrolled: true, observation: observation
      )
      fleet = Hive::SchedulingProof::FleetProjector.new(
        as_of: now, daemon_running: true, heartbeat_at: now - 5, poll_interval_sec: 30
      ).project(
        configured_slots: fixture.fetch("configured_slots"), owners: [], candidates: [ observation ]
      )
      actual = { "proof" => proof, "fleet" => fleet }

      fixture.fetch("expected").each do |field, expected|
        assert_equal expected, dig_path(actual, field), "#{File.basename(File.dirname(path))}: #{field}"
      end
      assert_operator proof.fetch("summary").length, :<=, Hive::DiagnosticHelpers::SUMMARY_MAX
      assert_operator fleet.fetch("summary").length, :<=, Hive::DiagnosticHelpers::SUMMARY_MAX
      assert_equal fleet.fetch("unused_slots"), fleet.fetch("causal_buckets").sum { |bucket| bucket.fetch("units") }
      refute_match(/(?:sk-[A-Za-z0-9_-]{20,}|bearer\s+\S+|authorization:)/i, JSON.generate(actual))
    end
  end

  private

  def dig_path(value, path)
    path.split(".").reduce(value) do |current, component|
      component.match?(/\A\d+\z/) ? current.fetch(component.to_i) : current.fetch(component)
    end
  end
end
