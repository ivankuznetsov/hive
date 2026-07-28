require "psych"

module Hive
  module WorkflowPackage
    class AuthoringLint
      class CommandExtractor
        Command = Data.define(:path, :line, :column, :raw)
        ExtractionEvent = Data.define(
          :rule_id, :severity, :path, :line, :column, :message, :review, :evidence
        )
        CommandBatch = Data.define(:commands, :events)

        COMMAND_START = /\A\s*(?:\$\s*)?(?:(?:bash|sh|zsh|pwsh|powershell|curl|wget|iwr|invoke-webrequest|git|gh|ruby|python\d*|node|npm|npx|bundle|rake|cat|grep|rg|find|ls|head|tail|sed|awk|tar|zip|gzip|base64|openssl|env|printenv|export|set|cp|mv|rm|mkdir|chmod|chown|tee|echo|printf|source)\b|\.\/[^\s]+)(?:\s|[|;&<>()]|\z)/i
        SHELL_FENCE = /\A\s*```\s*(bash|sh|shell|zsh|powershell|pwsh)?\s*\z/i
        RUBY_SINK = %r{
          https?://|(?:Kernel\.)?(?:system|exec|spawn)\s*\(|Open3\.|IO\.popen|`[^`]+`|
          File\.(?:read|binread|open|write|binwrite|delete|unlink|rename|chmod|chown|truncate)|
          (?:Net::H[T]TP|URI[.]open|OpenURI)|ENV(?:\.fetch\s*\(|\s*\[)
        }ix

        private_constant :Command, :ExtractionEvent, :CommandBatch

        class RubyExtractor
          def initialize(append:)
            @append = append
          end

          def extract(entry)
            entry.text.each_line.with_index(1).filter_map do |line, line_number|
              next unless line.match?(RUBY_SINK)

              @append.call(
                entry.path, line_number, first_column(line), line.chomp
              )
            end
          end

          private

          def first_column(line)
            line.index(/\S/) ? line.index(/\S/) + 1 : 1
          end
        end

        class MarkdownExtractor
          def initialize(append:, command_like:)
            @append = append
            @command_like = command_like
          end

          def extract(entry)
            commands = []
            fence = nil
            entry.text.each_line.with_index(1) do |line, line_number|
              stripped = line.chomp
              if (opening = SHELL_FENCE.match(stripped))
                fence = fence ? nil : { shell: !opening[1].nil? }
                next
              end
              if fence
                if !stripped.strip.empty? &&
                    (fence.fetch(:shell) || @command_like.call(stripped))
                  command = @append.call(
                    entry.path, line_number, first_column(line), stripped
                  )
                  commands << command if command
                end
                next
              end
              if !stripped.strip.empty? && @command_like.call(stripped)
                command = @append.call(
                  entry.path, line_number, first_column(line), stripped
                )
                commands << command if command
              end
              line.to_enum(:scan, /`([^`\r\n]+)`/).each do
                match = Regexp.last_match
                next unless @command_like.call(match[1])

                command = @append.call(
                  entry.path, line_number, match.begin(1) + 1, match[1]
                )
                commands << command if command
              end
            end
            commands
          end

          private

          def first_column(line)
            line.index(/\S/) ? line.index(/\S/) + 1 : 1
          end
        end

        class JsonExtractor < MarkdownExtractor; end
        class ShellExtractor < MarkdownExtractor; end
        class ExtensionlessExtractor < MarkdownExtractor; end

        class YamlExtractor
          def initialize(append:, command_like:, permission_field:)
            @append = append
            @command_like = command_like
            @permission_field = permission_field
          end

          def extract(entry)
            stream = safe_yaml_stream!(entry)
            commands = []
            walk_yaml(stream, entry.path, commands, mapping_key: false, yaml_path: [])
            commands
          end

          private

          def safe_yaml_stream!(entry)
            stream = Psych.parse_stream(entry.text, filename: entry.path)
            unless stream.is_a?(Psych::Nodes::Stream) &&
                   stream.children.length == 1 && stream.children.first&.root
              raise UnsafeYAML, "YAML must contain one non-empty document"
            end
            inspect_yaml_node!(stream.children.first.root)
            value = Psych.safe_load(
              entry.text, permitted_classes: [], permitted_symbols: [], aliases: false,
              filename: entry.path, fallback: nil
            )
            inspect_json_value!(value)
            stream
          end

          def inspect_yaml_node!(node)
            raise UnsafeYAML, "YAML aliases are not allowed" if node.is_a?(Psych::Nodes::Alias)
            if node.respond_to?(:tag) && node.tag &&
               !node.tag.start_with?("tag:yaml.org,2002:")
              raise UnsafeYAML, "custom YAML tags are not allowed"
            end
            case node
            when Psych::Nodes::Mapping
              seen = {}
              node.children.each_slice(2) do |key, value|
                unless key.is_a?(Psych::Nodes::Scalar)
                  raise UnsafeYAML, "YAML mapping keys must be strings"
                end
                raise UnsafeYAML, "YAML mapping keys must be unique" if seen[key.value]

                seen[key.value] = true
                inspect_yaml_node!(key)
                inspect_yaml_node!(value)
              end
            when Psych::Nodes::Sequence
              node.children.each { |child| inspect_yaml_node!(child) }
            end
          end

          def inspect_json_value!(value)
            case value
            when Hash
              value.each do |key, child|
                unless key.is_a?(String)
                  raise UnsafeYAML, "YAML mapping keys must be strings"
                end
                inspect_json_value!(child)
              end
            when Array
              value.each { |child| inspect_json_value!(child) }
            when String, Integer, TrueClass, FalseClass, NilClass
              nil
            when Float
              raise UnsafeYAML, "YAML numbers must be finite" unless value.finite?
            else
              raise UnsafeYAML, "YAML contains a non-JSON value"
            end
          end

          def walk_yaml(node, path, commands, mapping_key:, yaml_path:)
            case node
            when Psych::Nodes::Mapping
              node.children.each_slice(2) do |key, value|
                walk_yaml(key, path, commands, mapping_key: true, yaml_path: yaml_path)
                child_path =
                  if key.is_a?(Psych::Nodes::Scalar)
                    yaml_path + [ key.value ]
                  else
                    yaml_path
                  end
                walk_yaml(
                  value, path, commands, mapping_key: false, yaml_path: child_path
                )
              end
            when Psych::Nodes::Sequence, Psych::Nodes::Stream, Psych::Nodes::Document
              node.children.each do |child|
                walk_yaml(
                  child, path, commands, mapping_key: false, yaml_path: yaml_path
                )
              end
            when Psych::Nodes::Scalar
              return if mapping_key || !yaml_string?(node) ||
                        @permission_field.call(path, yaml_path)

              lines = node.value.lines
              if lines.length > 1
                lines.each_with_index do |line, index|
                  raw = line.chomp
                  next unless @command_like.call(raw)

                  command = @append.call(
                    path, node.start_line + index + 1, 1, raw
                  )
                  commands << command if command
                end
              elsif @command_like.call(node.value)
                command = @append.call(
                  path, node.start_line + 1, node.start_column + 1, node.value
                )
                commands << command if command
              end
            end
          end

          def yaml_string?(node)
            return true if node.quoted || node.style != Psych::Nodes::Scalar::PLAIN
            return false if node.tag && node.tag != "tag:yaml.org,2002:str"

            !node.value.match?(
              /\A(?:null|~|true|false|yes|no|on|off|[-+]?\d+(?:\.\d+)?)\z/i
            )
          end
        end

        private_constant(
          :RubyExtractor, :MarkdownExtractor, :JsonExtractor, :ShellExtractor,
          :ExtensionlessExtractor, :YamlExtractor
        )

        def self.command_start?(value)
          value.to_s.match?(COMMAND_START)
        end

        def initialize(manifest:, limits:)
          @manifest = manifest
          @limits = limits
        end

        def extract(files)
          @events = []
          @command_count = 0
          behavior_paths = declared_behavior_paths
          scoped = files.select do |entry|
            entry.path == "workflow.yml" || entry.path == "README.md" ||
              entry.path.start_with?("instructions/") ||
              behavior_paths.include?(entry.path)
          end
          commands = scoped.flat_map do |entry|
            unless entry.text
              @events << event(
                "policy.invalid-file", :error, entry.path, nil, nil,
                "declared behavior must be scannable UTF-8 text"
              )
              next []
            end

            extract_entry(entry)
          end.sort_by { |command| [ command.path, command.line, command.column, command.raw ] }
          CommandBatch.new(
            commands: commands.freeze, events: @events.freeze
          ).freeze
        end

        def inspect_json_value!(value)
          yaml_extractor.send(:inspect_json_value!, value)
        end

        private

        def extract_entry(entry)
          return extract_yaml(entry) if entry.path.match?(/\.ya?ml\z/i)
          return extract_executable(entry) if executable_path?(entry.path)
          return json_extractor.extract(entry) if entry.path.match?(/\.json\z/i)

          markdown_extractor.extract(entry)
        end

        def extract_executable(entry)
          return ruby_extractor.extract(entry) if entry.path.match?(/\.rb\z/i)
          if entry.path.match?(/\.(?:sh|bash|zsh|ps1)\z/i)
            return shell_extractor.extract(entry)
          end
          return extensionless_extractor.extract(entry) if File.extname(entry.path).empty?

          @events << event(
            "policy.invalid-file", :error, entry.path, nil, nil,
            "declared executable type is unsupported by the lint contract"
          )
          []
        end

        def extract_yaml(entry)
          yaml_extractor.extract(entry)
        rescue Psych::Exception, UnsafeYAML
          @events << event(
            "instruction.malformed-yaml", :error, entry.path, nil, nil,
            "instruction YAML could not be parsed safely"
          )
          []
        end

        def declared_behavior_paths
          extension = @manifest.data["x-hive"]
          return [] unless extension.is_a?(Hash)

          %w[tools prompt_assets].flat_map do |key|
            Array(extension[key]).filter_map do |entry|
              entry["path"] if entry.is_a?(Hash) && entry["path"].is_a?(String)
            end
          end.uniq
        end

        def executable_path?(path)
          extension = @manifest.data["x-hive"]
          Array(extension.is_a?(Hash) && extension["tools"]).any? do |entry|
            entry.is_a?(Hash) && entry["path"] == path
          end
        end

        def append_command(path, line, column, raw)
          command = Command.new(
            path: path.to_s.dup.freeze, line: line, column: column,
            raw: raw.to_s.dup.freeze
          ).freeze
          if @command_count >= @limits.fetch("max_commands")
            @events << event(
              "policy.command-limit", :error, command.path, command.line,
              command.column, "extracted command count exceeds lint policy"
            )
            return nil
          end
          @command_count += 1
          command
        end

        def command_like?(value)
          self.class.command_start?(value) ||
            value.to_s.match?(/\|\s*(?:sh|bash|zsh|pwsh|powershell)\b/i)
        end

        def workflow_permission_field?(path, yaml_path)
          return false unless path == "workflow.yml" && yaml_path.first == "stages"

          yaml_path.each_cons(2).any? do |parent, field|
            parent == "permissions" && %w[tools dirs].include?(field)
          end
        end

        def append_callback
          @append_callback ||= method(:append_command)
        end

        def command_like_callback
          @command_like_callback ||= method(:command_like?)
        end

        def permission_field_callback
          @permission_field_callback ||= method(:workflow_permission_field?)
        end

        def ruby_extractor
          @ruby_extractor ||= RubyExtractor.new(append: append_callback)
        end

        def markdown_extractor
          @markdown_extractor ||= MarkdownExtractor.new(
            append: append_callback, command_like: command_like_callback
          )
        end

        def json_extractor
          @json_extractor ||= JsonExtractor.new(
            append: append_callback, command_like: command_like_callback
          )
        end

        def shell_extractor
          @shell_extractor ||= ShellExtractor.new(
            append: append_callback, command_like: command_like_callback
          )
        end

        def extensionless_extractor
          @extensionless_extractor ||= ExtensionlessExtractor.new(
            append: append_callback, command_like: command_like_callback
          )
        end

        def yaml_extractor
          @yaml_extractor ||= YamlExtractor.new(
            append: append_callback, command_like: command_like_callback,
            permission_field: permission_field_callback
          )
        end

        def event(rule_id, severity, path, line, column, message,
                  review: false, evidence: nil)
          ExtractionEvent.new(
            rule_id: rule_id.freeze, severity: severity, path: path.to_s.freeze,
            line: line, column: column, message: message.freeze,
            review: review, evidence: evidence&.freeze
          ).freeze
        end
      end
    end
  end
end
