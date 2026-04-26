module Hive
  module Stages
    module Review
      # Per-spawn context passed by the 5-review runner to every
      # sub-runner: reviewers (`Hive::Reviewers::Agent`), triage
      # (`Hive::Stages::Review::Triage`), ci-fix
      # (`Hive::Stages::Review::CiFix`), browser-test
      # (`Hive::Stages::Review::BrowserTest`), and the fix-guardrail
      # (`Hive::Stages::Review::FixGuardrail`). Frozen so consumers
      # can't mutate it.
      #
      # Lives under `Hive::Stages::Review::` because the 5-review stage
      # owns this type — only one of its consumers (the reviewer
      # adapter) is in the `Hive::Reviewers::` namespace. The previous
      # location at `Hive::Reviewers::Context` is retained as an alias
      # for backward compatibility (see lib/hive/reviewers/base.rb).
      Context = Data.define(:worktree_path, :task_folder, :default_branch, :pass)
    end
  end
end
