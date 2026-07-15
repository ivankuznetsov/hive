require "pathname"
require "hive/honeycomb/manifest"
require "hive/permission_scope"

module Hive
  module Honeycomb
    SecurityReport = Data.define(:summary, :findings) do
      SHELL_LINE_RE = /\A\s*(?:\$\s+)?(?:sudo\s+|doas\s+)?(?:curl|wget|git|gh|rm|cp|mv|chmod|chown|bash|sh|zsh|fish|python\d*|ruby|node|npm|npx|bundle|gem|env|printenv|export)\b/
      SHELL_FENCE_RE = /\A\s*```(?:ba)?sh|\A\s*```(?:zsh|fish|shell|console)\b/i
      HIGH_RISK_PATTERNS = {
        "network_to_interpreter" => /(?:\bcurl\b|\bwget\b)[^|\n]*\|\s*(?:sh|bash|zsh|fish|python\d*|ruby|node|perl)\b/i,
        "destructive_filesystem" => /\brm\s+(?:-[^\s]*[rf][^\s]*\s+|--recursive\b|--force\b)/i,
        "privilege_escalation" => /(?:\A|\s)(?:sudo|doas|su)(?:\s|\z)/i,
        "credential_access" => /\b(?:env|printenv|TOKEN|PASSWORD|SECRET|API_KEY|AWS_[A-Z_]+|GITHUB_TOKEN)\b/i
      }.freeze

      def self.build(workflow:, package_root:)
        exposures = permission_exposures(workflow)
        summary = summarize(exposures)
        findings = instruction_paths(workflow).uniq.sort.flat_map do |path|
          scan_instruction(path, package_root: package_root)
        end
        new(summary: summary.freeze, findings: findings.freeze)
      end

      def self.permission_exposures(workflow)
        workflow.stages.flat_map do |stage|
          next [] unless %i[agent council].include?(stage.kind)
          rows = [ exposure(stage.permissions, "stage #{stage.name}") ]
          Array(stage.reviewers).each do |reviewer|
            rows << exposure(reviewer.permissions, "stage #{stage.name} reviewer #{reviewer.name}")
          end
          rows << exposure(stage.council.revise.permissions, "stage #{stage.name} revise") if stage.council&.revise
          rows
        end
      end

      def self.exposure(spec, location)
        return { "location" => location, "preset" => "inherited", "tools" => [], "dirs" => [], "bash" => false } unless spec

        parsed = Hive::PermissionScope.parse_spec(spec, stage: location)
        preset = parsed.fetch("preset")
        tools = case preset
        when "read-only" then Hive::PermissionScope::READ_ONLY_ALLOWED
        when "scoped"
          parsed.key?("tools") ? parsed.fetch("tools").map(&:to_s) :
            Hive::PermissionScope::READ_ONLY_ALLOWED + (parsed["bash"] == true ? [ "Bash" ] : [])
        else []
        end
        {
          "location" => location,
          "preset" => preset,
          "tools" => tools.uniq.sort,
          "dirs" => Array(parsed["dirs"]).map(&:to_s).uniq.sort,
          "bash" => preset == "yolo" || tools.include?("Bash") || parsed["bash"] == true
        }
      end

      def self.summarize(exposures)
        presets = exposures.map { |row| row.fetch("preset") }.uniq.sort
        tools = exposures.flat_map { |row| row.fetch("tools") }.uniq.sort
        dirs = exposures.flat_map { |row| row.fetch("dirs") }.uniq.sort
        yolo = presets.include?("yolo")
        bash = exposures.any? { |row| row.fetch("bash") }
        {
          "presets" => presets.freeze,
          "tools" => tools.freeze,
          "dirs" => dirs.freeze,
          "bash" => bash,
          "yolo" => yolo,
          "shell_capable" => bash || yolo,
          "locations" => exposures.freeze
        }
      end

      def self.instruction_paths(workflow)
        workflow.stages.flat_map do |stage|
          paths = [ stage.instruction ]
          Array(stage.reviewers).each { |reviewer| paths << reviewer.instruction }
          paths << stage.council.revise.instruction if stage.council&.revise
          paths.compact
        end
      end

      def self.scan_instruction(path, package_root:)
        raw = File.binread(path)
        text = raw.dup.force_encoding(Encoding::UTF_8)
        raise IntegrityError, "instruction #{path} is not valid UTF-8" unless text.valid_encoding?

        relative = Pathname.new(path).relative_path_from(Pathname.new(package_root)).to_s
        lines = text.lines
        findings = []
        index = 0
        while index < lines.length
          line = lines[index]
          if SHELL_FENCE_RE.match?(line)
            start = index
            block = []
            index += 1
            while index < lines.length && !lines[index].match?(/\A\s*```\s*\z/)
              block << lines[index]
              index += 1
            end
            command = block.join
            findings << finding(relative, start + 1, "shell_fence", command) unless command.empty?
          elsif SHELL_LINE_RE.match?(line)
            findings << finding(relative, index + 1, "command_line", line)
          end
          index += 1
        end
        findings
      end

      def self.finding(path, line, kind, command)
        risks = HIGH_RISK_PATTERNS.filter_map { |name, pattern| name if pattern.match?(command) }
        { "path" => path, "line" => line, "kind" => kind, "command" => command, "high_risk" => risks.freeze }.freeze
      end

      def validate_manifest_summary!(declared)
        return true if declared.fetch("yolo", false)

        missing = []
        missing << "yolo" if summary.fetch("yolo")
        missing << "presets" unless (summary.fetch("presets") - [ "inherited" ] - declared.fetch("presets", [])).empty?
        missing << "tools" unless (summary.fetch("tools") - declared.fetch("tools", [])).empty?
        unless declared.fetch("dirs", []).include?("*") || (summary.fetch("dirs") - declared.fetch("dirs", [])).empty?
          missing << "dirs"
        end
        missing << "bash" if summary.fetch("bash") && !declared.fetch("bash", false)
        return true if missing.empty?

        raise ManifestError,
              "manifest permissions summary understates descriptor-derived exposure: #{missing.uniq.sort.join(', ')}"
      end

      def render
        lines = [
          "permissions: #{summary.fetch('presets').join(', ')}",
          "tools: #{summary.fetch('tools').empty? ? 'none' : summary.fetch('tools').join(', ')}",
          "dirs: #{summary.fetch('dirs').empty? ? 'none' : summary.fetch('dirs').join(', ')}",
          "shell-capable: #{summary.fetch('shell_capable') ? 'yes' : 'no'}"
        ]
        findings.each do |finding|
          risks = finding.fetch("high_risk")
          lines << "instruction #{finding.fetch('path')}:#{finding.fetch('line')} #{finding.fetch('kind')}" \
                   "#{risks.empty? ? '' : " [#{risks.join(', ')}]"}"
        end
        lines.join("\n")
      end
    end
  end
end
