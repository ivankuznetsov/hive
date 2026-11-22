require "fileutils"
require "json"
require "hive/atomic_file"

module Hive
  module Stages
    module Review
      # Retires one review generation's numbered pass files when a backward
      # `hive approve` rewinds through 6-review.
      #
      # Review derives its next pass from the highest `reviews/*-NN.md` on
      # disk and refuses (`REVIEW_ERROR reason=config_error`) a pass above
      # its admitted ceiling. A rewind from 7-artifacts/8-finalize is an
      # intentional new review generation, so the prior generation's pass
      # files must not be counted again. Moving them aside (rather than
      # teaching every pass reader about generations) keeps one source of
      # truth: the top-level `reviews/*-NN.md` set is always the current
      # generation. Every review reader globs `reviews/` non-recursively,
      # so `reviews/archive/<label>/` is never consumed as a live pass.
      #
      # Unnumbered state (`ci-blocked.md`, `deferred-findings.md`,
      # `suppressed.md`) and subdirectories stay in place.
      module PassArchive
        ARCHIVE_DIR = "archive".freeze
        NUMBERED_PASS_RE = /\A.+-\d{2}\.md\z/
        RETIREMENT_RECEIPT = "retirement.json".freeze
        RETIREMENT_SCHEMA = "hive.review-generation-retirement".freeze

        module_function

        # Retires the live review generation without a stage move: review
        # grants expire in the budget audit (`expiry_reason`), then numbered
        # pass files and grant/completion receipts move into a fresh
        # `reviews/archive/<label>/`. This is the same reset a rewind or an
        # outcome-evidence rework applies, so the next review starts at pass
        # 1 and no grant or finding bound to the old work can be reused.
        #
        # A `receipt` (deterministic Hash) is written into the archive first.
        # A retry after an interruption finds that receipt and finishes the
        # move into the same directory instead of starting another one; with
        # a receipt the directory is created even when nothing is left to
        # move. Returns the task-relative archive directory, or nil.
        def retire!(task, label:, expiry_reason:, receipt: nil)
          require "hive/review_budget"
          require "hive/review_pass"
          reviews = File.join(task.folder, "reviews")
          return nil unless File.directory?(reviews) && !File.symlink?(reviews)

          document = receipt && retirement_document(receipt, expiry_reason)
          relative = document && existing_retirement(task.folder, document)
          names = Dir.children(reviews).select do |name|
            (Hive::ReviewPass.number(name) || Hive::ReviewPass.budget_receipt?(name)) &&
              File.lstat(File.join(reviews, name)).then { |stat| stat.file? || stat.symlink? }
          end.sort_by { |name| Hive::ReviewPass.sort_key(name) }
          return relative if names.empty? && (relative || document.nil?)

          if names.any? { |name| Hive::ReviewPass.budget_receipt?(name) }
            Hive::ReviewBudget.new(task: task, project: task.project_name).record_expiry!(reason: expiry_reason)
          end
          unless relative
            relative = create_archive_dir!(reviews, label)
            write_retirement(File.join(task.folder, relative), document) if document
          end
          names.each do |name|
            File.rename(File.join(reviews, name), File.join(task.folder, relative, name))
          end
          Hive::AtomicFile.fsync_directory(File.join(task.folder, relative))
          Hive::AtomicFile.fsync_directory(reviews)
          relative
        end

        def retirement_document(receipt, expiry_reason)
          { "schema" => RETIREMENT_SCHEMA, "schema_version" => 1,
            "expiry_reason" => expiry_reason.to_s }.merge(receipt.transform_keys(&:to_s))
        end

        def existing_retirement(task_folder, document)
          root = File.join(task_folder, "reviews", ARCHIVE_DIR)
          return nil unless File.directory?(root) && !File.symlink?(root)

          Dir.children(root).sort.each do |name|
            path = File.join(root, name, RETIREMENT_RECEIPT)
            next unless File.file?(path) && !File.symlink?(path)

            existing = JSON.parse(File.read(path, 64 * 1024))
            return File.join("reviews", ARCHIVE_DIR, name) if existing == document
          rescue JSON::ParserError
            next
          end
          nil
        end

        def write_retirement(directory, document)
          Hive::AtomicFile.create(File.join(directory, RETIREMENT_RECEIPT), "#{JSON.pretty_generate(document)}\n")
        end

        # Moves numbered pass files into a fresh `reviews/archive/<label>[-N]/`
        # directory. Each completed move is appended to +moves+ as a
        # task-relative `[from, to]` pair before the next one starts, so a
        # failure part-way through can still be undone with `restore!`.
        def archive!(task_folder, label:, moves: [])
          reviews = File.join(task_folder, "reviews")
          return moves unless File.directory?(reviews) && !File.symlink?(reviews)

          names = Dir.children(reviews).sort.select do |name|
            next false unless name.match?(NUMBERED_PASS_RE)

            # rename(2) moves a symlink itself, never its target, and the
            # review glob would still count a link named like a pass.
            stat = File.lstat(File.join(reviews, name))
            stat.file? || stat.symlink?
          end
          return moves if names.empty?

          relative_dir = create_archive_dir!(reviews, label)
          names.each do |name|
            from = File.join("reviews", name)
            to = File.join(relative_dir, name)
            File.rename(File.join(task_folder, from), File.join(task_folder, to))
            moves << [ from, to ]
          end
          moves
        end

        # Reverses `archive!` inside +task_folder+ (the folder may have moved
        # stages since). Returns nil on success or a diagnostic string.
        def restore!(task_folder, moves)
          return nil if moves.nil? || moves.empty?

          issues = moves.reverse.filter_map do |from, to|
            source = File.join(task_folder, to)
            target = File.join(task_folder, from)
            next "#{to} missing; cannot restore #{from}" unless present?(source)
            next "#{from} reappeared; left #{to} archived" if present?(target)

            File.rename(source, target)
            nil
          end
          archive_dir = File.dirname(File.join(task_folder, moves.first.last))
          Dir.rmdir(archive_dir) if issues.empty? && Dir.empty?(archive_dir)
          issues.empty? ? nil : "review pass archive restore incomplete: #{issues.join('; ')}"
        end

        # 1-based ordinal of the live review generation: one more than the
        # number of archived generations under `reviews/archive/`. It only
        # changes when `archive!` creates (or `restore!` removes) a directory,
        # so every pass of one generation observes the same value.
        def generation(task_folder)
          root = File.join(task_folder, "reviews", ARCHIVE_DIR)
          return 1 unless File.directory?(root) && !File.symlink?(root)

          1 + Dir.children(root).count do |name|
            path = File.join(root, name)
            File.directory?(path) && !File.symlink?(path)
          end
        end

        def present?(path)
          File.exist?(path) || File.symlink?(path)
        end

        def create_archive_dir!(reviews, label)
          safe = label.to_s.gsub(/[^A-Za-z0-9_-]+/, "-")
          root = File.join(reviews, ARCHIVE_DIR)
          FileUtils.mkdir_p(root)
          suffix = 0
          begin
            name = suffix.zero? ? safe : "#{safe}-#{suffix}"
            Dir.mkdir(File.join(root, name))
          rescue Errno::EEXIST
            suffix += 1
            retry
          end
          File.join("reviews", ARCHIVE_DIR, name)
        end
      end
    end
  end
end
