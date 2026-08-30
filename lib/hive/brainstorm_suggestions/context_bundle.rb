# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require "hive/brainstorm_parser"
require "hive/brainstorm_suggestions/binding"
require "hive/secret_patterns"

module Hive
  module BrainstormSuggestions
    # A deterministic, bounded snapshot of eligible repository/wiki evidence
    # and already-settled operator context. It never enumerates untracked files.
    class ContextBundle
      RECIPE = "tracked-relevance"
      RECIPE_VERSION = 2
      MAX_CAPTURE_SECONDS = 5
      MAX_GIT_OUTPUT_BYTES = 8 * 1024 * 1024
      MAX_CANDIDATE_FILES = 160
      MAX_SELECTED_FILES = 24
      MAX_SELECTED_BYTES = 96 * 1024
      MAX_FILE_BYTES = 48 * 1024
      MAX_REQUEST_BYTES = 16 * 1024
      MAX_MAIN_WIKI_FILES = 6
      TEXT_EXTENSIONS = %w[
        .rb .rake .md .erb .yml .yaml .json .toml .txt .js .ts .tsx .jsx
        .css .scss .html .sh .zsh .fish .py .go .rs .java .kt .swift .sql
      ].freeze
      STOP_WORDS = %w[
        about after again also and are can could does for from have how into
        its should that the their then there these they this use what when
        which will with would your
      ].freeze

      Entry = Data.define(:path, :mode, :digest, :source, :content) do
        def manifest
          {
            "path" => path,
            "mode" => mode,
            "digest" => digest,
            "source" => source,
            "bytes" => content.bytesize
          }
        end
      end

      class CaptureError < Error
        attr_reader :code

        def initialize(code, message = nil)
          @code = code.to_s
          super(message || "brainstorm suggestion context is unavailable (#{@code})")
        end
      end

      attr_reader :manifest, :diagnostics, :settled_answers, :question, :task_request

      def self.capture(project_root:, task_root:, question_ordinal:, deadline: nil)
        new(
          project_root: project_root,
          task_root: task_root,
          question_ordinal: question_ordinal,
          deadline: deadline
        ).tap(&:capture!)
      end

      def initialize(project_root:, task_root:, question_ordinal:, deadline: nil)
        @project_root = canonical_directory(project_root, "project_unavailable")
        @task_root = canonical_directory(task_root, "task_unavailable")
        @question_ordinal = Integer(question_ordinal)
        @deadline = deadline || monotonic_now + MAX_CAPTURE_SECONDS
        raise CaptureError.new("question_unavailable") unless @question_ordinal.positive?
      rescue ArgumentError, TypeError
        raise CaptureError.new("question_unavailable")
      end

      def capture!
        check_deadline!
        @task_request = redact_untrusted(
          stable_read(File.join(@task_root, "idea.md"), max_bytes: MAX_REQUEST_BYTES,
                      code: "task_request_unavailable")
        )
        brainstorm = stable_read(
          File.join(@task_root, "brainstorm.md"), max_bytes: MAX_FILE_BYTES,
          code: "brainstorm_unavailable"
        )
        questions = Hive::BrainstormParser.parse_text(brainstorm)
        selected_question = questions[@question_ordinal - 1]
        raise CaptureError.new("question_unavailable") unless selected_question

        @question = {
          "ordinal" => @question_ordinal,
          "round" => selected_question.round,
          "number" => selected_question.n,
          "text" => selected_question.text,
          "fingerprint" => Hive::BrainstormParser.question_fingerprint(selected_question.text)
        }.freeze
        @settled_answers = questions.first(@question_ordinal - 1).filter_map do |item|
          next unless item.answered?

          {
            "round" => item.round,
            "question_number" => item.n,
            "question" => redact_untrusted(item.text),
            "answer" => redact_untrusted(item.answer)
          }.freeze
        end.freeze

        tokens = relevance_tokens([ @task_request, @question.fetch("text") ].join("\n"))
        index = tracked_index
        overlay_paths = tracked_overlay_paths
        repository_entries = select_repository_entries(index, tokens, overlay_paths)
        main_wiki_entries = select_main_wiki_entries(tokens)
        @entries = fixed_context_entries + repository_entries + main_wiki_entries
        @entries = @entries.freeze
        @manifest = {
          "recipe" => RECIPE,
          "recipe_version" => RECIPE_VERSION,
          "entries" => @entries.map(&:manifest)
        }.freeze
        @diagnostics = {
          "head" => git_output("rev-parse", "--verify", "HEAD").strip,
          "tracked_entries" => index.length,
          "selected_entries" => @entries.length
        }.freeze
        self
      end

      def selected_identity
        Binding.digest(manifest)
      end

      def source_classes
        manifest.fetch("entries").map { |entry| entry.fetch("source") }.uniq.sort.freeze
      end

      def render_context
        @entries.each_with_index.map do |entry, index|
          <<~SOURCE
            <untrusted-source index="#{index + 1}" class="#{entry.source}" path="#{entry.path}" sha256="#{entry.digest}">
            #{entry.content}
            </untrusted-source>
          SOURCE
        end.join("\n")
      end

      def materialize(runtime_root)
        validate_materialization_root!(runtime_root)
        bundle_root = File.join(runtime_root, "bundle")
        Dir.mkdir(bundle_root, 0o700)
        evidence_root = File.join(bundle_root, "evidence")
        Dir.mkdir(evidence_root, 0o700)
        materialized_entries = @entries.each_with_index.map do |entry, index|
          relative = format("evidence/%03d.txt", index + 1)
          write_immutable(File.join(bundle_root, relative), entry.content)
          entry.manifest.merge("bundle_path" => relative)
        end
        write_immutable(
          File.join(bundle_root, "manifest.json"),
          "#{JSON.pretty_generate(manifest.merge('entries' => materialized_entries))}\n"
        )
        write_immutable(File.join(bundle_root, "context.md"), render_context)
        bundle_root
      end

      private

      def fixed_context_entries
        entries = [ build_entry("task/request.txt", "100400", "request", @task_request) ]
        if @settled_answers.any?
          entries << build_entry(
            "task/settled-answers.json", "100400", "settled_answers",
            "#{JSON.pretty_generate(@settled_answers)}\n"
          )
        end
        entries
      end

      def tracked_index
        output = git_output("ls-files", "-s", "-z")
        output.split("\0", -1).filter_map do |row|
          next if row.empty?

          header, path = row.split("\t", 2)
          mode, oid, stage = header.to_s.split(" ", 3)
          raise CaptureError.new("index_conflict") unless stage == "0"
          raise CaptureError.new("unsafe_tracked_entry") unless %w[100644 100755].include?(mode)
          raise CaptureError.new("unsafe_tracked_entry") unless safe_relative_path?(path)

          { path: path, mode: mode, oid: oid }
        end
      end

      def tracked_overlay_paths
        git_output("diff", "--name-only", "-z", "HEAD", "--")
          .split("\0", -1)
          .filter_map { |path| path unless path.empty? || !safe_relative_path?(path) }
          .to_h { |path| [ path, true ] }
      end

      def select_repository_entries(index, tokens, overlay_paths)
        candidates = index.sort_by do |row|
          overlay = overlay_paths[row.fetch(:path)] ? 1_000 : 0
          [ -(overlay + path_rank_score(row.fetch(:path), tokens)), row.fetch(:path) ]
        end.first(MAX_CANDIDATE_FILES).filter_map do |row|
          check_deadline!
          path = row.fetch(:path)
          next unless text_candidate?(path)

          content = stable_tracked_read(path)
          next if content.nil? || content.include?("\0") || !content.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          content = content.force_encoding(Encoding::UTF_8)
          next if Hive::SecretPatterns.match?(content)

          source = path.start_with?("wiki/") ? "project_wiki" : "repository"
          relevance = path_relevance_score(path, tokens) + content_score(content, tokens)
          next unless overlay_paths[path] || relevance.positive?

          score = relevance + path_type_bonus(path) + (overlay_paths[path] ? 1_000 : 0)
          [ score, build_entry(path, row.fetch(:mode), source, content) ]
        end

        choose_bounded(candidates)
      end

      def select_main_wiki_entries(tokens)
        config_path = File.join(@project_root, ".llm-wiki", "config.json")
        return [] unless File.file?(config_path) && !File.symlink?(config_path)

        raw = stable_read(config_path, max_bytes: 16 * 1024, code: "main_wiki_unavailable")
        config = JSON.parse(raw)
        configured = config["main_wiki_path"] if config.is_a?(Hash)
        return [] unless configured.is_a?(String) && !configured.empty?

        root = File.expand_path(configured, @project_root)
        root = canonical_directory(root, "main_wiki_unavailable")
        candidates = Dir.glob(File.join(root, "**", "*.md")).sort.first(MAX_CANDIDATE_FILES).filter_map do |path|
          check_deadline!
          relative = path.delete_prefix("#{root}/")
          next unless safe_relative_path?(relative)

          content = stable_external_read(root, relative)
          next if content.nil? || Hive::SecretPatterns.match?(content)

          relevance = path_relevance_score(relative, tokens) + content_score(content, tokens)
          next unless relevance.positive?

          score = relevance + path_type_bonus(relative)
          [ score, build_entry("main-wiki/#{relative}", "100400", "main_wiki", content) ]
        end
        choose_bounded(candidates, max_files: MAX_MAIN_WIKI_FILES, max_bytes: MAX_SELECTED_BYTES / 4)
      rescue JSON::ParserError, CaptureError
        []
      end

      def choose_bounded(candidates, max_files: MAX_SELECTED_FILES, max_bytes: MAX_SELECTED_BYTES)
        total = 0
        candidates.sort_by { |score, entry| [ -score, entry.path ] }.filter_map do |_score, entry|
          next if total + entry.content.bytesize > max_bytes
          break if total >= max_bytes

          total += entry.content.bytesize
          entry
        end.first(max_files)
      end

      def build_entry(path, mode, source, content)
        normalized = content.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        Entry.new(
          path: path.freeze,
          mode: mode.freeze,
          digest: Digest::SHA256.hexdigest(normalized.b).freeze,
          source: source.freeze,
          content: normalized.freeze
        )
      end

      def stable_tracked_read(relative)
        full = File.join(@project_root, relative)
        return nil unless File.exist?(full) || File.symlink?(full)

        stable_regular_read(@project_root, relative, max_bytes: MAX_FILE_BYTES)
      rescue Errno::ENOENT
        nil
      end

      def stable_external_read(root, relative)
        stable_regular_read(root, relative, max_bytes: MAX_FILE_BYTES)
      rescue SystemCallError, IOError, CaptureError
        nil
      end

      def stable_regular_read(root, relative, max_bytes:)
        verify_components!(root, relative)
        full = File.join(root, relative)
        status = File.lstat(full)
        raise CaptureError.new("unsafe_tracked_entry") unless status.file? && !status.symlink?
        return nil if status.size > max_bytes

        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(full, flags) do |file|
          opened = file.stat
          current = File.lstat(full)
          raise CaptureError.new("capture_race") unless
            opened.file? && !current.symlink? && opened.dev == current.dev && opened.ino == current.ino

          value = file.read(max_bytes + 1)
          raise CaptureError.new("capture_too_large") if value.bytesize > max_bytes

          value
        end
      end

      def stable_read(path, max_bytes:, code:)
        status = File.lstat(path)
        raise CaptureError.new(code) unless status.file? && !status.symlink? && status.size <= max_bytes

        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          opened = file.stat
          current = File.lstat(path)
          raise CaptureError.new(code) unless opened.dev == current.dev && opened.ino == current.ino

          value = file.read(max_bytes + 1)
          raise CaptureError.new(code) if value.bytesize > max_bytes

          value.dup.force_encoding(Encoding::UTF_8).scrub
        end
      rescue SystemCallError, IOError
        raise CaptureError.new(code)
      end

      def verify_components!(root, relative)
        current = root
        relative.split("/").each_with_index do |part, index|
          current = File.join(current, part)
          status = File.lstat(current)
          raise CaptureError.new("unsafe_tracked_entry") if status.symlink?
          next if index == relative.split("/").length - 1

          raise CaptureError.new("unsafe_tracked_entry") unless status.directory?
        end
        real = File.realpath(current)
        raise CaptureError.new("unsafe_tracked_entry") unless
          real == root || real.start_with?("#{root}/")
      end

      def relevance_tokens(text)
        text.downcase.scan(/[a-z0-9_]{3,}/).reject { |token| STOP_WORDS.include?(token) }.uniq.first(64)
      end

      def path_relevance_score(path, tokens)
        normalized = path.downcase
        tokens.sum { |token| normalized.include?(token) ? 20 : 0 }
      end

      def path_rank_score(path, tokens)
        path_relevance_score(path, tokens) + path_type_bonus(path)
      end

      def path_type_bonus(path)
        score = path.start_with?("wiki/") ? 5 : 0
        score += 2 if TEXT_EXTENSIONS.include?(File.extname(path).downcase)
        score
      end

      def content_score(content, tokens)
        sample = content.downcase
        tokens.sum { |token| [ sample.scan(token).length, 5 ].min }
      end

      def text_candidate?(path)
        TEXT_EXTENSIONS.include?(File.extname(path).downcase) || File.basename(path).match?(/\A(?:Gemfile|Rakefile|Makefile)\z/)
      end

      def safe_relative_path?(path)
        return false unless path.is_a?(String) && !path.empty? && !path.start_with?("/")

        parts = path.split("/")
        parts.none? { |part| part.empty? || part == "." || part == ".." }
      end

      def redact_untrusted(value)
        Hive::SecretPatterns.redact(value.to_s)
      end

      def git_output(*arguments)
        run_process(
          [ "git", "-C", @project_root, *arguments ],
          environment: { "GIT_OPTIONAL_LOCKS" => "0", "GIT_TERMINAL_PROMPT" => "0" }
        )
      end

      def run_process(argv, environment: {})
        reader, writer = IO.pipe
        pid = Process.spawn(environment, *argv, pgroup: true, in: File::NULL, out: writer, err: writer)
        writer.close
        output = +"".b
        reading = Thread.new do
          while (chunk = reader.read(65_536))
            output << chunk
            break if output.bytesize > MAX_GIT_OUTPUT_BYTES
          end
        end
        status = nil
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          if waited
            status = waited.last
            break
          end
          raise CaptureError.new("capture_timeout") if monotonic_now >= @deadline

          IO.select(nil, nil, nil, 0.02)
        end
        reading.join
        raise CaptureError.new("capture_too_large") if output.bytesize > MAX_GIT_OUTPUT_BYTES
        raise CaptureError.new("repository_unavailable") unless status.success?

        output.force_encoding(Encoding::UTF_8).scrub
      rescue CaptureError
        terminate_process_group(pid)
        raise
      rescue SystemCallError, IOError
        terminate_process_group(pid)
        raise CaptureError.new("repository_unavailable")
      ensure
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
        reading&.kill if reading&.alive?
      end

      def terminate_process_group(pid)
        return unless pid

        Process.kill("TERM", -pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def canonical_directory(path, code)
        expanded = File.expand_path(path)
        status = File.lstat(expanded)
        raise CaptureError.new(code) unless status.directory? && !status.symlink?

        File.realpath(expanded)
      rescue SystemCallError
        raise CaptureError.new(code)
      end

      def validate_materialization_root!(path)
        status = File.lstat(path)
        raise UnsafePath, "bundle runtime root must be an owned directory" unless
          status.directory? && !status.symlink? && status.uid == Process.uid
      end

      def write_immutable(path, content)
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags, 0o400) do |file|
          file.write(content)
          file.flush
          file.fsync
        end
        File.chmod(0o400, path)
      end

      def check_deadline!
        raise CaptureError.new("capture_timeout") if monotonic_now >= @deadline
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
