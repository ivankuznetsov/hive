# frozen_string_literal: true

require "json"

# Frozen compatibility fixture extracted from the released JobStore v2 read
# boundary. It intentionally knows nothing about the candidate v3 runtime.
module ReleasedV2JobReader
  SCHEMA = "hive-refactor-patrol-job"
  SCHEMA_VERSION = 2
  TOP_LEVEL_KEYS = %w[
    schema schema_version job_id source analysis_sha policy state complete
    dispositions feature_results review_errors zero_reason attempts actions
    created_at updated_at
  ].freeze

  module_function

  def read(project_root, job_id, hive_state_path: ".hive-state")
    id = job_id.to_s
    raise ArgumentError, "invalid released v2 job id" unless
      id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/)

    path = File.join(
      File.expand_path(hive_state_path, project_root),
      "refactor_patrol", "v2", "jobs", "#{id}.json"
    )
    data = JSON.parse(File.binread(path))
    valid = data.is_a?(Hash) &&
      data.keys.sort == TOP_LEVEL_KEYS.sort &&
      data["schema"] == SCHEMA &&
      data["schema_version"] == SCHEMA_VERSION &&
      data["job_id"] == id &&
      data["attempts"].is_a?(Array) &&
      data["actions"].is_a?(Array) &&
      !data.key?("occurrence_id") &&
      !data.key?("intake_transition_id")
    raise "released JobStore v2 reader rejected restored aggregate" unless valid

    data
  end

  # Released resume flows paired the aggregate with its immutable intake
  # manifest. Keeping the job alone is insufficient to reopen that workflow.
  def resume(project_root, job_id, hive_state_path: ".hive-state")
    job = read(
      project_root, job_id, hive_state_path: hive_state_path
    )
    manifest_path = File.join(
      File.expand_path(hive_state_path, project_root),
      "refactor_patrol", "v2", "manifests", "#{job_id}.json"
    )
    manifest = JSON.parse(File.binread(manifest_path))
    unless manifest.is_a?(Hash) && manifest["job_id"] == job.fetch("job_id")
      raise "released JobStore v2 resume manifest is malformed"
    end

    { "job" => job, "manifest" => manifest }
  end
end
