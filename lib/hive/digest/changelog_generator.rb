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

      RunnerTask = Data.define(:folder, :state_file, :log_dir, :slug, :stage_name)
      TemplateBindings = Struct.new(
        :date, :manifest_path, :output_path, :user_supplied_tag,
        keyword_init: true
      ) do
        def binding_for_erb = binding
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
        output_path = File.join(dir, "changelog.json")
        tag = Hive::Stages::Base.user_supplied_tag
        manifest, manifest_path, chunk_dir = materialize_manifest(rows, dir: dir, tag: tag)
        prompt = render_prompt(
          local_date, manifest_path: manifest_path, output_path: output_path, user_supplied_tag: tag
        )
        task = runner_task(dir: dir, output_path: output_path, date: local_date)
        result = agent_for(task, prompt, output_path).run!
        unless result.is_a?(Hash) && result[:status] == :ok
          raise_generation_error(
            "digest changelog agent failed: #{agent_error_message(result)}", output_path: output_path
          )
        end

        changelog = self.class.parse_output!(
          output_path, repositories: rows, manifest: manifest, logger: @logger
        )
        changelog = sanitize_changelog(changelog)
        retain_ledger(changelog, manifest, dir: dir)
        changelog
      rescue GenerationError
        raise
      rescue SystemCallError, JSON::ParserError => e
        raise_generation_error(
          "digest changelog generation failed: #{e.class}: #{e.message}",
          output_path: defined?(output_path) ? output_path : nil
        )
      ensure
        FileUtils.rm_f(manifest_path) if defined?(manifest_path) && manifest_path
        FileUtils.rm_rf(chunk_dir) if defined?(chunk_dir) && chunk_dir
        FileUtils.rm_f(output_path) if defined?(output_path) && output_path
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
        def parse_output!(output_path, repositories:, manifest:, logger: Logger.new($stderr))
          unless File.file?(output_path) && File.size(output_path).positive?
            raise GenerationError, "digest changelog output is missing or empty: #{output_path}"
          end
          document = JSON.parse(File.read(output_path))
          validate_document!(document, repositories: repositories, manifest: manifest)
        rescue JSON::ParserError => e
          logger&.error("digest changelog output was not valid JSON: #{e.message}")
          raise GenerationError, "digest changelog output was not valid JSON: #{e.message}"
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
            evidence_ids = string_array!(row.fetch("evidence_ids"), "fact evidence_ids")
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

          expected_repositories = repositories.map { |repo| repo.target.repository }
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
            name = repository.target.repository
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
              if normalize_text(text) == normalize_text(pr.title)
                raise GenerationError, "digest changelog repeated the raw title for #{pr.repository}##{pr.number}"
              end
              fact_ids = string_array!(bullet.fetch("fact_ids"), "bullet fact_ids")
              fact_ids.each do |fact_id|
                fact = facts[fact_id]
                raise GenerationError, "digest changelog cited unknown fact #{fact_id.inspect}" unless fact
                unless fact.kind == "material" && pr_key(fact.repository, fact.pr_number) == pr_key(pr.repository, pr.number)
                  raise GenerationError, "digest changelog cited fact #{fact_id.inspect} from the wrong PR or kind"
                end
                covered_material[fact_id] = true
              end
              ChangeBullet.new(text: text, fact_ids: fact_ids)
            end
            GeneratedPullRequest.new(pull_request: pr, bullets: bullets.freeze)
          end
        end

        def pr_index(repositories)
          Array(repositories).flat_map(&:pull_requests).to_h do |pr|
            [ pr_key(pr.repository, pr.number), pr ]
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

        def string_array!(value, label)
          unless value.is_a?(Array) && !value.empty? && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
            raise GenerationError, "digest changelog #{label} must be a nonempty string array"
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
          value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
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
            "repository" => repository.target.repository,
            "project_name" => fenced(repository.target.project_name, tag),
            "description" => fenced(repository.metadata.description, tag),
            "pull_requests" => repository.pull_requests.map do |pr|
              evidence = evidence_chunks(pr).map do |chunk|
                write_chunk(chunk, chunk_dir: chunk_dir, tag: tag)
              end
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

      def evidence_chunks(pr)
        prefix = "#{::Digest::SHA256.hexdigest(pr.repository.downcase)[0, 12]}-pr#{pr.number}"
        body_chunks(pr.body).each_with_index.map do |text, index|
          { id: "#{prefix}-body-#{format('%03d', index + 1)}", kind: "body_section", text: text }
        end + diff_chunks(pr.diff, prefix: prefix)
      end

      def body_chunks(body)
        text = body.to_s.strip
        return [] if text.empty?

        sections = []
        current = []
        text.each_line do |line|
          if line.match?(/\A\s{0,3}\#{1,6}\s+\S/) && !current.empty?
            sections << current.join.rstrip
            current = []
          end
          current << line
        end
        sections << current.join.rstrip unless current.empty?
        sections.reject(&:empty?)
      end

      def diff_chunks(diff, prefix:)
        chunks = []
        file_index = 0
        hunk_index = 0
        file_lines = []
        hunk_lines = nil
        flush_hunk = lambda do
          next unless hunk_lines

          hunk_index += 1
          chunks << {
            id: "#{prefix}-hunk-#{format('%03d', file_index)}-#{format('%03d', hunk_index)}",
            kind: "diff_hunk", text: hunk_lines.join.rstrip
          }
          hunk_lines = nil
        end
        flush_file = lambda do
          flush_hunk.call
          unless file_lines.empty?
            chunks << {
              id: "#{prefix}-file-#{format('%03d', file_index)}",
              kind: "diff_file", text: file_lines.join.rstrip
            }
          end
          file_lines = []
        end

        diff.to_s.each_line do |line|
          if line.start_with?("diff --git ")
            flush_file.call if file_index.positive?
            file_index += 1
            hunk_index = 0
            file_lines << line
          elsif line.start_with?("@@")
            flush_hunk.call
            hunk_lines = [ line ]
          elsif hunk_lines
            hunk_lines << line
          else
            file_lines << line
          end
        end
        flush_file.call if file_index.positive?
        chunks
      end

      def write_chunk(chunk, chunk_dir:, tag:)
        path = File.join(chunk_dir, "#{chunk.fetch(:id)}.txt")
        content = "<#{tag}>\n#{chunk.fetch(:text)}\n</#{tag}>\n"
        private_write(path, content)
        {
          "id" => chunk.fetch(:id),
          "kind" => chunk.fetch(:kind),
          "path" => path,
          "bytes" => content.bytesize,
          "sha256" => ::Digest::SHA256.hexdigest(content)
        }
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
        facts = changelog.facts.map do |fact|
          GeneratedFact.new(
            id: fact.id,
            repository: fact.repository,
            pr_number: fact.pr_number,
            kind: fact.kind,
            text: sanitize_text(
              fact.text, repository: fact.repository, pr_number: fact.pr_number, warnings: warnings
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
                fact_ids: bullet.fact_ids
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

      def agent_for(task, prompt, output_path)
        return @agent_factory.call(task: task, prompt: prompt, output_path: output_path) if @agent_factory

        profile = Hive::AgentProfiles.lookup(agent_name, cfg: @cfg)
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
          permission_mode: profile.name == :claude ? Hive::Config.claude_permission_mode(@cfg) : nil,
          cli_flags: profile.name == :claude ? Hive::Config.claude_cli_flags(@cfg) : []
        )
      end

      def agent_name
        @cfg.dig("digest", "agent") || @cfg.dig("patrol", "agent") || "claude"
      end

      def budget_usd = @cfg.dig("budget_usd", "digest") || DEFAULT_BUDGET_USD
      def timeout_sec = @cfg.dig("timeout_sec", "digest") || DEFAULT_TIMEOUT_SEC

      def agent_error_message(result)
        return result.inspect unless result.is_a?(Hash)

        result[:error_message] || result[:status] || result.inspect
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
    end
  end
end
