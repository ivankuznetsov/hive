module Hive
  module Reviewers
    # Per-spawn context passed by the 5-review runner to every reviewer
    # adapter. Frozen so adapters can't mutate it.
    Context = Data.define(:worktree_path, :task_folder, :default_branch, :pass)

    # Reviewer outcome. Status is :ok | :error. error_message is set when
    # status == :error so the runner can surface it as a stub finding.
    Result = Data.define(:name, :output_path, :status, :error_message) do
      def ok?
        status == :ok
      end

      def error?
        status == :error
      end
    end

    # Common interface for "anything that produces reviews/<name>-<pass>.md
    # for the 5-review stage". Subclasses implement #run! and inherit the
    # spec/ctx/output_path conventions so the runner's per-reviewer loop
    # is shape-uniform across agent and linter reviewers.
    class Base
      attr_reader :spec, :ctx

      def initialize(spec, ctx)
        @spec = spec
        @ctx = ctx
      end

      def name
        spec.fetch("name")
      end

      def output_basename
        spec.fetch("output_basename")
      end

      # Per-pass output path. The 5-review runner finalizes by reading
      # every `reviews/<*>-<pass>.md` for the current pass; output_path
      # must follow the same convention so dedup and triage work.
      def output_path
        File.join(
          ctx.task_folder,
          "reviews",
          "#{output_basename}-#{format('%02d', ctx.pass)}.md"
        )
      end

      def run!
        raise NotImplementedError, "#{self.class} must implement #run!"
      end

      # Helper for subclasses to ensure the reviews directory exists
      # before writing.
      def ensure_reviews_dir!
        FileUtils.mkdir_p(File.dirname(output_path))
      end
    end
  end
end
