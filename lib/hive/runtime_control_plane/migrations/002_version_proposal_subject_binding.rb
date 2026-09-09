# `attempts.subject_json` already stores the closed subject value, so the v5
# attempt contract needs no column rewrite. Advancing SQLite's migration version
# is still required: an older Hive must refuse the database before it encounters
# a task-stage subject carrying the new `proposal` member.
Sequel.migration do
  up do
    # Version fence only; the existing subject_json column holds the v5 value.
  end

  down do
    # Reverting the fence does not rewrite subject bytes already stored in rows.
  end
end
