require "fileutils"

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

        module_function

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
