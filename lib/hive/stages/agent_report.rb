require "open3"
require "hive/markers"

module Hive
  module Stages
    # Strict parser and local-repository verifier for the one-agent draft-PR
    # handoff. The report is evidence only: it never carries a Hive marker and
    # it cannot make a remote mutation authoritative.
    module AgentReport
      module_function

      MAX_BYTES = 24 * 1024
      MAX_SECTION_CHARS = 4_000
      MAX_TITLE_CHARS = 120
      DECISIONS = %i[ready no-fix blocked].freeze
      REQUIRED_SECTIONS = %i[reproduction cause changes tests risks].freeze
      OPTIONAL_SECTIONS = %i[compact_plan debug_trace].freeze
      SECTION_LABELS = {
        "Reproduction" => :reproduction,
        "Cause" => :cause,
        "Changes" => :changes,
        "Tests" => :tests,
        "Risks" => :risks,
        "Compact plan" => :compact_plan,
        "Debug trace" => :debug_trace
      }.freeze

      Report = Data.define(
        :decision, :reproduction, :cause, :changes, :tests, :risks,
        :suggested_pr_title, :compact_plan, :debug_trace
      )
      RepositoryState = Data.define(:head_oid, :commit_count, :clean)

      def read(path)
        initial_stat = File.lstat(path)
        if initial_stat.symlink?
          raise Hive::StageError, "fix-report.md must be a regular file, not a symlink"
        end
        source = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          stat = file.stat
          raise Hive::StageError, "fix-report.md must be a regular file" unless stat.file?
          raise Hive::StageError, "fix-report.md is empty" if stat.size.zero?
          raise Hive::StageError, "fix-report.md exceeds #{MAX_BYTES} bytes" if stat.size > MAX_BYTES

          file.read(MAX_BYTES + 1)
        end
        source.force_encoding(Encoding::UTF_8)
        raise Hive::StageError, "fix-report.md must be valid UTF-8" unless source.valid_encoding?

        parse(source)
      rescue Errno::ENOENT
        raise Hive::StageError, "fix-report.md is missing"
      rescue SystemCallError, IOError => e
        raise Hive::StageError, "fix-report.md is unreadable: #{e.class}: #{e.message}"
      end

      def parse(source)
        text = source.to_s
        raise Hive::StageError, "fix-report.md is empty" if text.empty?
        raise Hive::StageError, "fix-report.md exceeds #{MAX_BYTES} bytes" if text.bytesize > MAX_BYTES
        raise Hive::StageError, "fix-report.md must be valid UTF-8" unless text.encoding == Encoding::UTF_8 && text.valid_encoding?
        if text.match?(Hive::Markers::MARKER_RE)
          raise Hive::StageError, "fix-report.md must not contain Hive terminal markers"
        end

        lines = text.lines(chomp: true)
        decision_line = lines.shift
        decision_match = decision_line&.match(/\ADecision: (ready|no-fix|blocked)\z/)
        raise Hive::StageError, "fix-report.md must start with Decision: ready|no-fix|blocked" unless decision_match

        fields = parse_sections(lines)
        decision = decision_match[1].to_sym
        Report.new(
          decision: decision,
          reproduction: fields.fetch(:reproduction),
          cause: fields.fetch(:cause),
          changes: fields.fetch(:changes),
          tests: fields.fetch(:tests),
          risks: fields.fetch(:risks),
          suggested_pr_title: fields.fetch(:suggested_pr_title),
          compact_plan: fields[:compact_plan],
          debug_trace: fields[:debug_trace]
        )
      end

      def validate_repository!(report, context)
        path = context.worktree_path
        branch = git!(path, "symbolic-ref", "--quiet", "--short", "HEAD").strip
        unless branch == context.task_branch
          raise Hive::StageError,
                "agent worktree is on branch #{branch.inspect}; expected #{context.task_branch.inspect}"
        end

        ancestry_out, ancestry_err, ancestry_status = Open3.capture3(
          "git", "-C", path, "merge-base", "--is-ancestor", context.base_oid, "HEAD"
        )
        unless ancestry_status.success?
          detail = ancestry_err.to_s.strip
          detail = ancestry_out.to_s.strip if detail.empty?
          raise Hive::StageError,
                "agent worktree HEAD is not descended from recorded base #{context.base_oid}: #{detail}".rstrip
        end

        head_oid = git!(path, "rev-parse", "HEAD").strip
        commit_count = Integer(git!(path, "rev-list", "--count", "#{context.base_oid}..HEAD").strip, 10)
        clean = git!(path, "status", "--porcelain=v1", "--untracked-files=all").empty?

        case report.decision
        when :ready
          raise Hive::StageError, "ready report requires at least one descendant commit" if commit_count.zero?
          raise Hive::StageError, "ready report requires a clean worktree" unless clean
        when :"no-fix"
          unless commit_count.zero? && clean
            raise Hive::StageError, "no-fix report requires no descendant commit or worktree diff"
          end
        when :blocked
          # Preserve partial local work as evidence. U4 never publishes a
          # blocked report, but branch and ancestry checks above still apply.
        else
          raise Hive::StageError, "unknown fix-report decision #{report.decision.inspect}"
        end

        RepositoryState.new(head_oid: head_oid, commit_count: commit_count, clean: clean)
      rescue ArgumentError => e
        raise Hive::StageError, "could not count agent commits: #{e.message}"
      end

      def parse_sections(lines)
        sections = []
        current = nil
        buffer = []
        suggested_title = nil

        flush = lambda do
          next unless current

          body = buffer.join("\n").strip
          raise Hive::StageError, "fix-report.md #{label_for(current)} section is empty" if body.empty?
          if body.length > MAX_SECTION_CHARS
            raise Hive::StageError, "fix-report.md #{label_for(current)} section exceeds #{MAX_SECTION_CHARS} characters"
          end
          sections << [ current, body ]
          current = nil
          buffer = []
        end

        lines.each do |line|
          if (match = line.match(/\A([A-Z][A-Za-z ]{0,39}):(?: (.*))?\z/))
            label = match[1]
            value = match[2]
            if label == "Suggested PR title"
              flush.call
              raise Hive::StageError, "fix-report.md Suggested PR title must be a single non-empty line" if value.to_s.strip.empty?
              raise Hive::StageError, "fix-report.md contains duplicate Suggested PR title" if suggested_title
              unless sections.map(&:first) == REQUIRED_SECTIONS
                raise Hive::StageError,
                      "fix-report.md Suggested PR title must follow the required sections"
              end
              suggested_title = value.strip
              if suggested_title.length > MAX_TITLE_CHARS
                raise Hive::StageError, "fix-report.md Suggested PR title exceeds #{MAX_TITLE_CHARS} characters"
              end
              next
            end

            key = SECTION_LABELS[label]
            raise Hive::StageError, "fix-report.md contains unknown field #{label.inspect}" unless key
            if suggested_title && REQUIRED_SECTIONS.include?(key)
              raise Hive::StageError,
                    "fix-report.md required sections must precede Suggested PR title"
            end
            raise Hive::StageError, "fix-report.md section headers must not have inline content" unless value.nil? || value.empty?
            flush.call
            current = key
            next
          end

          if current.nil? && !line.strip.empty?
            location = suggested_title ? "after Suggested PR title" : "outside a section"
            raise Hive::StageError, "fix-report.md contains content #{location}"
          end
          buffer << line if current
        end
        flush.call

        names = sections.map(&:first)
        duplicates = names.tally.select { |_key, count| count > 1 }.keys
        raise Hive::StageError, "fix-report.md contains duplicate sections: #{duplicates.map { |key| label_for(key) }.join(', ')}" unless duplicates.empty?

        missing = REQUIRED_SECTIONS - names
        raise Hive::StageError, "fix-report.md is missing sections: #{missing.map { |key| label_for(key) }.join(', ')}" unless missing.empty?
        raise Hive::StageError, "fix-report.md is missing Suggested PR title" unless suggested_title

        expected_order = REQUIRED_SECTIONS + OPTIONAL_SECTIONS
        positions = names.map { |key| expected_order.index(key) }
        unless positions == positions.sort
          raise Hive::StageError, "fix-report.md sections are out of order"
        end
        unless names.take(REQUIRED_SECTIONS.length) == REQUIRED_SECTIONS
          raise Hive::StageError, "fix-report.md required sections must use the documented order"
        end

        sections.to_h.merge(suggested_pr_title: suggested_title)
      end
      private_class_method :parse_sections

      def label_for(key)
        SECTION_LABELS.key(key) || key.to_s.tr("_", " ")
      end
      private_class_method :label_for

      def git!(path, *args)
        out, err, status = Open3.capture3("git", "-C", path, *args)
        return out if status.success?

        detail = err.to_s.strip
        detail = out.to_s.strip if detail.empty?
        raise Hive::StageError, "git #{args.join(' ')} failed: #{detail}"
      end
      private_class_method :git!
    end
  end
end
