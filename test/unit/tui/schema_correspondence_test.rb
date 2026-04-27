require "test_helper"
require "hive/commands/status"
require "hive/tui/snapshot"

# `Hive::Tui::Snapshot::Row` is the value-object that represents one
# task in the TUI's grid. Its fields shadow the JSON keys emitted by
# `Hive::Commands::Status#task_payload` 1:1, with one rename: the JSON
# key `"action"` lands on `:action_key` to avoid shadowing Ruby's
# `Kernel#action`-style ambient namespace.
#
# This test pins the boundary mapping so a silent rename on either
# side is loud at test time:
#   - if Status grows a new payload key, Snapshot::Row must grow a
#     matching field; otherwise the new column is invisible to the TUI.
#   - if Snapshot::Row drops or renames a field, the test names the
#     gap explicitly.
class TuiSchemaCorrespondenceTest < Minitest::Test
  include HiveTestHelper

  # Build a row hash with every key Status's `task_payload` returns. The
  # values are placeholders — the test only inspects keys.
  FAKE_ROW = {
    stage: "1-inbox",
    slug: "probe",
    folder: "/tmp/hive/probe",
    state_file: "/tmp/hive/probe/idea.md",
    marker_name: :waiting,
    marker_attrs: {},
    mtime: Time.now,
    claude_pid: nil,
    claude_pid_alive: nil,
    action_key: "ready_to_brainstorm",
    action_label: "Ready to brainstorm",
    suggested_command: "hive brainstorm probe --from 1-inbox"
  }.freeze

  # Map JSON keys -> Row member symbols. The single rename is
  # `"action" -> :action_key`; everything else maps to a same-name
  # symbol.
  KEY_TO_FIELD = {
    "action" => :action_key
  }.freeze

  def test_every_task_payload_key_maps_to_a_snapshot_row_field
    payload = Hive::Commands::Status.new(json: true).task_payload(FAKE_ROW)
    members = Hive::Tui::Snapshot::Row.members

    payload.each_key do |json_key|
      field = KEY_TO_FIELD.fetch(json_key, json_key.to_sym)
      assert_includes members, field,
                      "Snapshot::Row must expose a field for JSON key #{json_key.inspect} " \
                      "(expected member #{field.inspect})"
    end
  end

  # The reverse direction: every Row field other than the
  # back-reference `:project_name` must originate from a `task_payload`
  # JSON key (or be the `:action_key` rename of the `"action"` key).
  def test_every_snapshot_row_field_originates_in_task_payload
    payload = Hive::Commands::Status.new(json: true).task_payload(FAKE_ROW)
    payload_field_names = payload.keys.map { |k| KEY_TO_FIELD.fetch(k, k.to_sym) }
    members = Hive::Tui::Snapshot::Row.members - [ :project_name ]

    members.each do |member|
      assert_includes payload_field_names, member,
                      "Snapshot::Row field #{member.inspect} has no source in task_payload"
    end
  end
end
