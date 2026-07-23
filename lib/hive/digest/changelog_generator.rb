require "digest"
require "fileutils"
require "json"
require "logger"
require "securerandom"
require "hive/agent"
require "hive/agent_profiles"
require "hive/config"
require "hive/digest/errors"
require "hive/digest/london_window"
require "hive/digest/repository"
require "hive/paths"
require "hive/secret_patterns"
require "hive/stages/base"
require "hive/workflow_package/runtime_policy"

module Hive
  module Digest
    GeneratedFact = Data.define(:id, :repository, :pr_number, :kind, :text, :evidence_ids)
    ChangeBullet = Data.define(:text, :fact_ids) do
      def initialize(text:, fact_ids:)
        value = text.to_s.strip
        ids = Array(fact_ids).map(&:to_s)
        raise ArgumentError, "digest bullet text must not be blank" if value.empty?
        raise ArgumentError, "digest bullet must cite at least one fact" if ids.empty?

        super(text: value, fact_ids: ids.freeze)
      end
    end
    GeneratedPullRequest = Data.define(:pull_request, :bullets)
    GeneratedProject = Data.define(:repository, :significance, :pull_requests)
    Changelog = Data.define(:projects, :facts, :warnings)

    class ChangelogGenerator
      DEFAULT_BUDGET_USD = 50
      DEFAULT_TIMEOUT_SEC = 1800
      RUN_DIR_RETENTION = 20
      FACT_KINDS = %w[material no_user_facing_change].freeze
      TITLE_DECORATION_TOKENS = %w[
        change changed changes update updated updates implementation implement implemented
        fix fixed fixes release released releases migration migrate migrated pr pull request
      ].freeze

      RunnerTask = Data.define(:folder, :state_file, :log_dir, :slug, :stage_name)
      TemplateBindings = Struct.new(
        :date, :manifest_path, :output_path, :user_supplied_tag,
        keyword_init: true
      ) do
        def binding_for_erb = binding
      end

      class EvidenceChunkWriter
        NON_CONTENT_BYTES = [ 0, 9, 10, 11, 12, 13, 32 ].freeze

        def initialize(id:, kind:, path:, tag:)
          @id = id
          @kind = kind
          @path = path
          @closing = "</#{tag}>\n"
          @digest = ::Digest::SHA256.new
          @bytes = 0
          @nonblank = false
          @ends_with_newline = true
          @file = File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600)
          append("<#{tag}>\n")
        end

        def write(line)
          value = line.to_s
          @nonblank ||= value.each_byte.any? { |byte| !NON_CONTENT_BYTES.include?(byte) }
          @ends_with_newline = value.end_with?("\n")
          append(value)
        end

        def finish
          unless @nonblank
            @file.close
            FileUtils.rm_f(@path)
            return nil
          end

          append("\n") unless @ends_with_newline
          append(@closing)
          @file.close
          File.chmod(0o600, @path)
          {
            "id" => @id,
            "kind" => @kind,
            "path" => @path,
            "bytes" => @bytes,
            "sha256" => @digest.hexdigest
          }
        ensure
          @file.close unless @file.closed?
        end

        private

        def append(value)
          @file.write(value)
          @digest.update(value)
          @bytes += value.bytesize
        end
      end

      def initialize(cfg:, run_root: nil, logger: Logger.new($stderr), agent_factory: nil,
                     redactor: Hive::SecretPatterns)
        @cfg = cfg
        @run_root = run_root
        @logger = logger
        @agent_factory = agent_factory
        @redactor = redactor
      end

      def generate(repositories, date:)
        rows = Array(repositories)
        raise GenerationError, "digest changelog needs at least one pull request" if rows.flat_map(&:pull_requests).empty?

        local_date = LondonWindow.parse_date(date)
        dir = run_dir(local_date)
        agent_dir = File.join(dir, "agent")
        policy_dir = File.join(dir, "control")
        FileUtils.mkdir_p(agent_dir, mode: 0o700)
        File.chmod(0o700, agent_dir)
        output_path = File.join(agent_dir, "changelog.json")
        tag = Hive::Stages::Base.user_supplied_tag
        manifest, manifest_path, = materialize_manifest(rows, dir: agent_dir, tag: tag)
        prompt = render_prompt(
          local_date, manifest_path: manifest_path, output_path: output_path, user_supplied_tag: tag
        )
        task = runner_task(dir: agent_dir, output_path: output_path, date: local_date)
        result = agent_for(task, prompt, output_path, policy_dir: policy_dir).run!
        unless result.is_a?(Hash) && result[:status] == :ok
          raise_generation_error(
            "digest changelog agent failed: #{safe_agent_error(result)}", output_path: output_path
          )
        end

        changelog = self.class.parse_output!(
          output_path, repositories: rows, manifest: manifest, logger: @logger, redactor: @redactor
        )
        changelog = sanitize_changelog(changelog)
        retain_ledger(changelog, manifest, dir: dir)
        retained = true
        changelog
      rescue GenerationError
        raise
      rescue SystemCallError, JSON::ParserError => e
        raise_generation_error(
          "digest changelog generation failed: #{e.class}: #{e.message}",
          output_path: defined?(output_path) ? output_path : nil
        )
      ensure
        cleanup_run_dir(dir, retain_ledger: defined?(retained) && retained) if defined?(dir) && dir
      end

      def render_prompt(date, manifest_path:, output_path:, user_supplied_tag: Hive::Stages::Base.user_supplied_tag)
        Hive::Stages::Base.render(
          "digest_prompt.md.erb",
          TemplateBindings.new(
            date: LondonWindow.parse_date(date),
            manifest_path: manifest_path,
            output_path: output_path,
            user_supplied_tag: user_supplied_tag
          )
        )
      end

      class << self
        def parse_output!(output_path, repositories:, manifest:, logger: Logger.new($stderr),
                          redactor: Hive::SecretPatterns)
          unless File.file?(output_path) && File.size(output_path).positive?
            raise GenerationError, "digest changelog output is missing or empty: #{output_path}"
          end
          document = JSON.parse(File.read(output_path))
          validate_document!(document, repositories: repositories, manifest: manifest)
        rescue JSON::ParserError
          logger&.error("digest changelog output was not valid JSON")
          raise GenerationError, "digest changelog output was not valid JSON"
        rescue GenerationError => e
          message = safe_validation_message(e.message, redactor: redactor)
          logger&.error(message)
          raise GenerationError, message
        end

        def validate_document!(document, repositories:, manifest:)
          require_keys!(document, %w[facts projects], "document")
          facts = validate_facts!(document.fetch("facts"), repositories: repositories, manifest: manifest)
          projects = validate_projects!(document.fetch("projects"), repositories: repositories, facts: facts)
          Changelog.new(projects: projects.freeze, facts: facts.values.freeze, warnings: [].freeze)
        end

        private

        def validate_facts!(rows, repositories:, manifest:)
          raise GenerationError, "digest changelog facts must be an array" unless rows.is_a?(Array)

          pr_by_key = pr_index(repositories)
          evidence_owner = evidence_index(manifest)
          facts = {}
          used_evidence = {}
          rows.each do |row|
            require_keys!(row, %w[id repository number kind text evidence_ids], "fact")
            id = nonblank!(row.fetch("id"), "fact id")
            raise GenerationError, "digest changelog returned duplicate fact #{id.inspect}" if facts.key?(id)

            key = pr_key(row.fetch("repository"), row.fetch("number"))
            raise GenerationError, "digest changelog returned a fact for unknown PR #{key}" unless pr_by_key.key?(key)
            kind = row.fetch("kind").to_s
            raise GenerationError, "digest changelog returned invalid fact kind #{kind.inspect}" unless FACT_KINDS.include?(kind)
            text = nonblank!(row.fetch("text"), "fact text")
            evidence_ids = string_array!(
              row.fetch("evidence_ids"), "fact evidence_ids",
              allow_empty: kind == "no_user_facing_change"
            )
            if evidence_ids.empty? && evidence_owner.value?(key)
              raise GenerationError,
                    "digest changelog used an empty evidence list for a PR that has evidence #{key}"
            end
            evidence_ids.each do |evidence_id|
              owner = evidence_owner[evidence_id]
              raise GenerationError, "digest changelog cited unknown evidence #{evidence_id.inspect}" unless owner
              unless owner == key
                raise GenerationError, "digest changelog mapped evidence #{evidence_id.inspect} to the wrong PR"
              end
              if used_evidence.key?(evidence_id)
                raise GenerationError, "digest changelog mapped evidence #{evidence_id.inspect} more than once"
              end
              used_evidence[evidence_id] = id
            end
            facts[id] = GeneratedFact.new(
              id: id, repository: row.fetch("repository"), pr_number: Integer(row.fetch("number")),
              kind: kind, text: text, evidence_ids: evidence_ids.freeze
            )
          end
          missing = evidence_owner.keys - used_evidence.keys
          extra = used_evidence.keys - evidence_owner.keys
          unless missing.empty? && extra.empty?
            raise GenerationError,
                  "digest changelog evidence coverage mismatch: missing=#{missing.sort.inspect}, unknown=#{extra.sort.inspect}"
          end
          pr_by_key.each_key do |key|
            unless facts.values.any? { |fact| pr_key(fact.repository, fact.pr_number) == key }
              raise GenerationError, "digest changelog produced no facts for #{key}"
            end
          end
          facts
        end

        def validate_projects!(rows, repositories:, facts:)
          raise GenerationError, "digest changelog projects must be an array" unless rows.is_a?(Array)

          expected_repositories = repositories.map { |repo| repo.target.key }
          by_repository = {}
          rows.each do |row|
            require_keys!(row, %w[repository significance pull_requests], "project")
            repository = row.fetch("repository").to_s
            if by_repository.key?(repository)
              raise GenerationError, "digest changelog returned duplicate project #{repository.inspect}"
            end
            by_repository[repository] = row
          end
          exact_set!(by_repository.keys, expected_repositories, "project")

          covered_material = {}
          projects = repositories.map do |repository|
            name = repository.target.key
            row = by_repository.fetch(name)
            significance = one_line!(row.fetch("significance"), "project significance for #{name}")
            generated_prs = validate_project_prs!(
              row.fetch("pull_requests"), repository: repository,
              facts: facts, covered_material: covered_material
            )
            GeneratedProject.new(
              repository: repository, significance: significance, pull_requests: generated_prs.freeze
            )
          end
          material_ids = facts.values.select { |fact| fact.kind == "material" }.map(&:id)
          exact_set!(covered_material.keys, material_ids, "material fact")
          projects
        end

        def validate_project_prs!(rows, repository:, facts:, covered_material:)
          raise GenerationError, "digest changelog project pull_requests must be an array" unless rows.is_a?(Array)

          by_number = {}
          rows.each do |row|
            require_keys!(row, %w[number bullets], "pull request")
            number = Integer(row.fetch("number"))
            raise GenerationError, "digest changelog returned duplicate PR #{repository.target.repository}##{number}" if by_number.key?(number)
            by_number[number] = row
          rescue ArgumentError, TypeError
            raise GenerationError, "digest changelog returned an invalid PR number"
          end
          exact_set!(by_number.keys, repository.pull_requests.map(&:number), "PR for #{repository.target.repository}")

          repository.pull_requests.map do |pr|
            bullet_rows = by_number.fetch(pr.number).fetch("bullets")
            raise GenerationError, "digest changelog bullets must be a nonempty array" unless bullet_rows.is_a?(Array) && !bullet_rows.empty?
            bullets = bullet_rows.map do |bullet|
              require_keys!(bullet, %w[text fact_ids], "bullet")
              text = nonblank!(bullet.fetch("text"), "bullet text")
              if title_only_bullet?(text, pr.title)
                raise GenerationError, "digest changelog repeated the raw title for #{pr.repository}##{pr.number}"
              end
              fact_ids = string_array!(bullet.fetch("fact_ids"), "bullet fact_ids")
              fact_ids.each do |fact_id|
                fact = facts[fact_id]
                raise GenerationError, "digest changelog cited unknown fact #{fact_id.inspect}" unless fact
                unless pr_key(fact.repository, fact.pr_number) == pr_key(pr.target.key, pr.number)
                  raise GenerationError, "digest changelog cited fact #{fact_id.inspect} from the wrong PR"
                end
                covered_material[fact_id] = true if fact.kind == "material"
              end
              ChangeBullet.new(text: text, fact_ids: fact_ids)
            end
            GeneratedPullRequest.new(pull_request: pr, bullets: bullets.freeze)
          end
        end

        def pr_index(repositories)
          Array(repositories).flat_map(&:pull_requests).to_h do |pr|
            [ pr_key(pr.target.key, pr.number), pr ]
          end
        end

        def evidence_index(manifest)
          manifest.fetch("projects").flat_map do |project|
            project.fetch("pull_requests").flat_map do |pr|
              key = pr_key(project.fetch("repository"), pr.fetch("number"))
              pr.fetch("evidence").map { |item| [ item.fetch("id"), key ] }
            end
          end.to_h
        end

        def require_keys!(value, keys, label)
          unless value.is_a?(Hash) && value.keys.sort == keys.sort
            raise GenerationError, "digest changelog #{label} must contain exactly #{keys.sort.inspect}"
          end
        end

        def exact_set!(actual, expected, label)
          missing = expected - actual
          unknown = actual - expected
          return if missing.empty? && unknown.empty? && actual.size == expected.size

          raise GenerationError,
                "digest changelog #{label} coverage mismatch: missing=#{missing.inspect}, unknown=#{unknown.inspect}"
        end

        def string_array!(value, label, allow_empty: false)
          unless value.is_a?(Array) && (allow_empty || !value.empty?) &&
                 value.all? { |item| item.is_a?(String) && !item.strip.empty? }
            requirement = allow_empty ? "a string array" : "a nonempty string array"
            raise GenerationError, "digest changelog #{label} must be #{requirement}"
          end
          raise GenerationError, "digest changelog #{label} contains duplicates" unless value.uniq.size == value.size

          value
        end

        def nonblank!(value, label)
          text = value.to_s.strip
          raise GenerationError, "digest changelog #{label} must not be blank" if text.empty?

          text
        end

        def one_line!(value, label)
          text = nonblank!(value, label)
          sentence_endings = text.scan(/[.!?](?=\s|\z)/).size
          if text.lines.size != 1 || sentence_endings > 1
            raise GenerationError, "digest changelog #{label} must be one sentence"
          end

          text
        end

        def normalize_text(value)
          value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^\p{L}\p{N}]+/u, " ").strip
        end

        def title_only_bullet?(text, title)
          bullet_tokens = normalize_text(text).split
          title_tokens = normalize_text(title).split
          return true if bullet_tokens == title_tokens
          return false if title_tokens.empty? || bullet_tokens.length < title_tokens.length

          last_start = bullet_tokens.length - title_tokens.length
          (0..last_start).any? do |offset|
            next false unless bullet_tokens.slice(offset, title_tokens.length) == title_tokens

            residual = bullet_tokens.take(offset) + bullet_tokens.drop(offset + title_tokens.length)
            residual.empty? || residual.all? { |token| TITLE_DECORATION_TOKENS.include?(token) }
          end
        end

        def safe_validation_message(message, redactor:)
          redacted = redactor.redact(message.to_s)
          return "digest changelog output failed validation" unless redactor.scan(redacted).empty?

          redacted
        rescue EncodingError, SystemCallError
          "digest changelog output failed validation"
        end

        def pr_key(repository, number)
          "#{repository}##{Integer(number)}"
        rescue ArgumentError, TypeError
          raise GenerationError, "digest changelog returned an invalid PR identity"
        end
      end

      private

      def materialize_manifest(repositories, dir:, tag:)
        chunk_dir = File.join(dir, "evidence")
        FileUtils.mkdir_p(chunk_dir, mode: 0o700)
        File.chmod(0o700, chunk_dir)
        projects = repositories.map do |repository|
          {
            "repository" => repository.target.key,
            "project_name" => fenced(repository.target.project_name, tag),
            "description" => fenced(repository.metadata.description, tag),
            "pull_requests" => repository.pull_requests.map do |pr|
              evidence = write_evidence_chunks(pr, chunk_dir: chunk_dir, tag: tag)
              {
                "number" => pr.number,
                "title" => fenced(pr.title, tag),
                "url" => pr.url,
                "evidence" => evidence
              }
            end
          }
        end
        manifest = { "version" => 1, "projects" => projects }
        manifest_path = private_write(File.join(dir, "manifest.json"), JSON.pretty_generate(manifest))
        [ manifest, manifest_path, chunk_dir ]
      end

      def write_evidence_chunks(pr, chunk_dir:, tag:)
        prefix = "#{::Digest::SHA256.hexdigest(pr.target.key)[0, 12]}-pr#{pr.number}"
        write_body_chunks(pr.body, prefix: prefix, chunk_dir: chunk_dir, tag: tag) +
          write_diff_chunks(pr.diff, prefix: prefix, chunk_dir: chunk_dir, tag: tag)
      end

      def write_body_chunks(body, prefix:, chunk_dir:, tag:)
        chunks = []
        writer = nil
        index = 0
        each_evidence_line(body) do |line|
          if line.match?(/\A\s{0,3}\#{1,6}\s+\S/) && writer
            chunks << writer.finish
            writer = nil
          end
          unless writer
            index += 1
            writer = chunk_writer(
              id: "#{prefix}-body-#{format('%03d', index)}", kind: "body_section",
              chunk_dir: chunk_dir, tag: tag
            )
          end
          writer.write(line)
        end
        chunks << writer.finish if writer
        chunks.compact
      end

      def write_diff_chunks(diff, prefix:, chunk_dir:, tag:)
        chunks = []
        file_index = 0
        hunk_index = 0
        file_writer = nil
        hunk_writer = nil
        each_evidence_line(diff) do |line|
          if line.start_with?("diff --git ")
            chunks << hunk_writer.finish if hunk_writer
            chunks << file_writer.finish if file_writer
            file_index += 1
            hunk_index = 0
            hunk_writer = nil
            file_writer = chunk_writer(
              id: "#{prefix}-file-#{format('%03d', file_index)}", kind: "diff_file",
              chunk_dir: chunk_dir, tag: tag
            )
            file_writer.write(line)
          elsif line.start_with?("@@")
            chunks << hunk_writer.finish if hunk_writer
            hunk_index += 1
            hunk_writer = chunk_writer(
              id: "#{prefix}-hunk-#{format('%03d', file_index)}-#{format('%03d', hunk_index)}",
              kind: "diff_hunk", chunk_dir: chunk_dir, tag: tag
            )
            hunk_writer.write(line)
          elsif hunk_writer
            hunk_writer.write(line)
          elsif file_writer
            file_writer.write(line)
          else
            next unless line.each_byte.any? { |byte| !EvidenceChunkWriter::NON_CONTENT_BYTES.include?(byte) }

            raise GenerationError, "digest raw diff did not start with a file header"
          end
        end
        chunks << hunk_writer.finish if hunk_writer
        chunks << file_writer.finish if file_writer
        chunks.compact
      end

      def each_evidence_line(evidence, &block)
        return evidence.each_line(&block) if evidence.is_a?(EvidenceFile)

        evidence.to_s.each_line(&block)
      end

      def chunk_writer(id:, kind:, chunk_dir:, tag:)
        EvidenceChunkWriter.new(id: id, kind: kind, path: File.join(chunk_dir, "#{id}.txt"), tag: tag)
      end

      def fenced(text, tag)
        "<#{tag}>\n#{text}\n</#{tag}>"
      end

      def retain_ledger(changelog, manifest, dir:)
        checksums = manifest.fetch("projects").flat_map do |project|
          project.fetch("pull_requests").flat_map do |pr|
            pr.fetch("evidence").map { |item| [ item.fetch("id"), item.fetch("sha256") ] }
          end
        end.to_h
        private_write(
          File.join(dir, "ledger.json"),
          JSON.pretty_generate("evidence_checksums" => checksums, "output" => changelog_to_h(changelog))
        )
      end

      def sanitize_changelog(changelog)
        warnings = []
        display_repository = changelog.projects.to_h do |project|
          [ project.repository.target.key, project.repository.target.repository ]
        end
        fact_ids = sanitize_fact_ids(changelog.facts, warnings: warnings, display_repository: display_repository)
        facts = changelog.facts.map do |fact|
          repository = display_repository.fetch(fact.repository)
          GeneratedFact.new(
            id: fact_ids.fetch(fact.id),
            repository: fact.repository,
            pr_number: fact.pr_number,
            kind: fact.kind,
            text: sanitize_text(
              fact.text, repository: repository, pr_number: fact.pr_number, warnings: warnings
            ),
            evidence_ids: fact.evidence_ids
          )
        end
        projects = changelog.projects.map do |project|
          repository = project.repository.target.repository
          generated_prs = project.pull_requests.map do |generated_pr|
            number = generated_pr.pull_request.number
            bullets = generated_pr.bullets.map do |bullet|
              ChangeBullet.new(
                text: sanitize_text(
                  bullet.text, repository: repository, pr_number: number, warnings: warnings
                ),
                fact_ids: bullet.fact_ids.map { |fact_id| fact_ids.fetch(fact_id) }.freeze
              )
            end
            GeneratedPullRequest.new(pull_request: generated_pr.pull_request, bullets: bullets.freeze)
          end
          GeneratedProject.new(
            repository: project.repository,
            significance: sanitize_text(
              project.significance, repository: repository, pr_number: nil, warnings: warnings
            ),
            pull_requests: generated_prs.freeze
          )
        end
        Changelog.new(projects: projects.freeze, facts: facts.freeze, warnings: warnings.freeze)
      end

      def sanitize_fact_ids(facts, warnings:, display_repository:)
        scanned_facts = facts.map { |fact| [ fact, @redactor.scan(fact.id.to_s) ] }
        reserved = scanned_facts.filter_map do |fact, hits|
          fact.id if hits.empty?
        end.to_h { |id| [ id, true ] }
        sequence = 0
        scanned_facts.to_h do |fact, hits|
          if hits.empty?
            [ fact.id, fact.id ]
          else
            begin
              sequence += 1
              replacement = format("redacted-fact-%04d", sequence)
            end while reserved.key?(replacement)
            reserved[replacement] = true
            repository = display_repository.fetch(fact.repository)
            warnings << Warning.new(
              kind: "generated_identifier_redacted",
              repository: repository,
              pr_number: fact.pr_number,
              message: "Redacted a recognized secret pattern from a generated fact identifier for " \
                       "#{repository}##{fact.pr_number}"
            )
            [ fact.id, replacement ]
          end
        end
      rescue EncodingError, SystemCallError => e
        raise GenerationError, "digest generated-identifier redaction failed: #{e.class}"
      end

      def sanitize_text(text, repository:, pr_number:, warnings:)
        hits = @redactor.scan(text.to_s)
        value = @redactor.redact(text.to_s)
        unless @redactor.scan(value).empty?
          raise GenerationError, "digest generated-text redaction could not be verified"
        end
        unless hits.empty?
          counts = hits.map { |hit| hit.fetch(:name).to_s }.tally
          scope = pr_number ? "#{repository}##{pr_number}" : repository
          warnings << Warning.new(
            kind: "generated_text_redacted",
            repository: repository,
            pr_number: pr_number,
            message: "Redacted recognized secret patterns from generated text for #{scope}: " \
                     "#{counts.sort.map { |name, count| "#{name}=#{count}" }.join(', ')}"
          )
        end
        value
      rescue EncodingError, SystemCallError => e
        raise GenerationError, "digest generated-text redaction failed: #{e.class}"
      end

      def changelog_to_h(changelog)
        {
          "facts" => changelog.facts.map do |fact|
            {
              "id" => fact.id,
              "repository" => fact.repository,
              "number" => fact.pr_number,
              "kind" => fact.kind,
              "text" => fact.text,
              "evidence_ids" => fact.evidence_ids
            }
          end,
          "projects" => changelog.projects.map do |project|
            {
              "repository" => project.repository.target.repository,
              "significance" => project.significance,
              "pull_requests" => project.pull_requests.map do |generated_pr|
                {
                  "number" => generated_pr.pull_request.number,
                  "bullets" => generated_pr.bullets.map do |bullet|
                    { "text" => bullet.text, "fact_ids" => bullet.fact_ids }
                  end
                }
              end
            }
          end,
          "warnings" => changelog.warnings.map(&:to_h)
        }
      end

      def run_dir(date)
        root = @run_root || File.join(Hive::Paths.state_home, "digest", "runs")
        FileUtils.mkdir_p(root, mode: 0o700)
        File.chmod(0o700, root)
        prune_old_runs(root)
        dir = File.join(root, "#{date.iso8601}-#{SecureRandom.hex(4)}")
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.chmod(0o700, dir)
        dir
      end

      def prune_old_runs(root)
        dirs = Dir.children(root).map { |name| File.join(root, name) }.select { |path| File.directory?(path) }
        return if dirs.size <= RUN_DIR_RETENTION

        dirs.sort_by { |path| File.mtime(path) }
            .first(dirs.size - RUN_DIR_RETENTION)
            .each { |path| FileUtils.rm_rf(path) }
      rescue SystemCallError => e
        @logger&.warn("digest: run-dir prune failed under #{root}: #{e.class}")
      end

      def runner_task(dir:, output_path:, date:)
        RunnerTask.new(
          folder: dir,
          state_file: File.join(dir, "state.yml"),
          log_dir: File.join(dir, "logs"),
          slug: "digest-#{date.iso8601}",
          stage_name: "digest"
        )
      end

      def agent_for(task, prompt, output_path, policy_dir: nil)
        return @agent_factory.call(task: task, prompt: prompt, output_path: output_path) if @agent_factory

        profile = Hive::AgentProfiles.lookup(agent_name, cfg: @cfg)
        unless profile.name == :claude
          raise Hive::ConfigError,
                "hive digest: agent #{profile.name.inspect} cannot enforce the confidential evidence runtime policy"
        end
        policy_dir ||= File.join(File.dirname(task.folder), ".#{File.basename(task.folder)}-control")
        runtime_policy = Hive::WorkflowPackage::RuntimePolicy.compile(
          {
            "tools" => %w[Read Write],
            "deny" => [],
            "directories" => [],
            "commands" => [],
            "domains" => [],
            "credentials" => []
          },
          task_folder: task.folder,
          profile: profile,
          policy_dir: policy_dir
        )
        Hive::Agent.new(
          task: task,
          prompt: prompt,
          profile: profile,
          add_dirs: [],
          cwd: task.folder,
          max_budget_usd: budget_usd,
          timeout_sec: timeout_sec,
          expected_output: output_path,
          status_mode: :output_file_exists,
          log_label: "digest",
          runtime_policy: runtime_policy,
          log_stream: false
        )
      end

      def agent_name
        @cfg.dig("digest", "agent") || @cfg.dig("patrol", "agent") || "claude"
      end

      def budget_usd = @cfg.dig("budget_usd", "digest") || DEFAULT_BUDGET_USD
      def timeout_sec = @cfg.dig("timeout_sec", "digest") || DEFAULT_TIMEOUT_SEC

      def safe_agent_error(result)
        value = if result.is_a?(Hash)
          result[:error_message] || result[:status] || "unknown failure"
        else
          "unknown failure"
        end
        redacted = @redactor.redact(value.to_s)
        return "unknown failure" unless @redactor.scan(redacted).empty?

        redacted.lines.first.to_s.strip
      rescue EncodingError, SystemCallError
        "unknown failure"
      end

      def raise_generation_error(message, output_path:)
        run_dir = output_path ? File.dirname(output_path) : "<unavailable>"
        detailed = "#{message} (run dir: #{run_dir}; logs: #{File.join(run_dir, 'logs')})"
        @logger&.error(detailed)
        raise GenerationError, detailed
      end

      def private_write(path, content)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(content) }
        File.chmod(0o600, path)
        path
      end

      def cleanup_run_dir(dir, retain_ledger:)
        retained = retain_ledger ? [ "ledger.json" ] : []
        Dir.children(dir).each do |name|
          next if retained.include?(name)

          FileUtils.rm_rf(File.join(dir, name))
        end
      rescue SystemCallError => e
        @logger&.warn("digest: run cleanup failed under #{dir}: #{e.class}")
        raise GenerationError, "digest changelog private-run cleanup failed: #{e.class}"
      end
    end
  end
end
