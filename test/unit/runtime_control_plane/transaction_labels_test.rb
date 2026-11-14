require "test_helper"

# `Database#transaction` logs long holds as `runtime_writer` events. Without
# an `operation:` label a hold is reported as the generic `runtime.write`,
# which made the daemon's multi-second writers unattributable. The daemon,
# attempt supervisors, stage runners, and `hive act` write through these files.
class RuntimeTransactionLabelsTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  LABELLED_WRITERS = %w[
    lib/hive/attempts/coordination.rb
    lib/hive/attempts/log_archive.rb
    lib/hive/attempts/lost_outcome.rb
    lib/hive/attempts/publication.rb
    lib/hive/attempts/repository.rb
    lib/hive/command_receipt_maintenance.rb
    lib/hive/command_receipt_pruner.rb
    lib/hive/command_receipt_store.rb
    lib/hive/command_receipt_store/effects.rb
    lib/hive/command_receipt_store/pins.rb
    lib/hive/command_receipt_store/reclamation.rb
    lib/hive/config.rb
    lib/hive/daemon/quiescence.rb
    lib/hive/project_identity.rb
    lib/hive/runtime_control_plane/command_schema_installation.rb
    lib/hive/runtime_control_plane/dispatch_repository.rb
    lib/hive/runtime_control_plane/lifecycle_repository.rb
    lib/hive/runtime_control_plane/operational_repository.rb
    lib/hive/runtime_control_plane/process_registry.rb
    lib/hive/runtime_control_plane/task_lease_repository.rb
    lib/hive/task_counter.rb
    lib/hive/usage_db.rb
  ].freeze
  CALL = /\.transaction\b(?!_)/

  def test_runtime_writers_name_their_operation
    unlabelled = LABELLED_WRITERS.flat_map do |relative|
      lines = File.readlines(File.join(ROOT, relative))
      lines.each_with_index.filter_map do |line, index|
        next if line.lstrip.start_with?("#") || !CALL.match?(line)

        # A call may wrap; its arguments end at the block opener.
        call = lines[index, 6].join[/#{CALL.source}.*?(?:\bdo\b|&\w+\))/m].to_s
        "#{relative}:#{index + 1}" unless call.include?("operation:")
      end
    end

    assert_empty unlabelled, "runtime writes without an operation label"
  end
end
