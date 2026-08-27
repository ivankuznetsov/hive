require "json"

module AgentCliRuntime
  module OpenCode
    # Compiles provider-neutral permission modes into OpenCode's
    # per-run permission document. The document can be written into an
    # isolated overlay or supplied through OPENCODE_PERMISSION while the CLI
    # continues to use its native configuration and login.
    module Permissions
      module_function

      def compile(permission_mode:, permission_policy: nil,
                  working_directory:, additional_read_roots: [],
                  additional_write_roots: [], edit_patterns: [],
                  bash_patterns: [], plugins: [], runtime_write_roots: [])
        mode = permission_mode
        if mode.nil?
          return nil unless permission_policy
          unless permission_policy.is_a?(OpenCodePermissionPolicy)
            raise ArgumentError,
                  "permission_policy must be an OpenCodePermissionPolicy"
          end

          return deep_copy(permission_policy.rules)
        end

        unless %w[read-only workspace-write].include?(mode)
          raise ConfigurationError, "unsupported OpenCode permission mode"
        end

        roots = {
          working: File.expand_path(working_directory),
          read: expanded_roots(additional_read_roots),
          write: expanded_roots(additional_write_roots)
        }
        runtime_roots = expanded_roots(runtime_write_roots)
        external = { "*" => "deny" }
        [ *roots.fetch(:read), *roots.fetch(:write), *runtime_roots ].uniq.each do |root|
          external[root] = "allow"
          external["#{root}/**"] = "allow"
        end
        common = {
          "*" => "deny",
          "read" => {
            "*" => "allow",
            "*.env" => "deny",
            "*.env.*" => "deny",
            "*.env.example" => "allow"
          },
          "glob" => "allow",
          "grep" => "allow",
          "list" => "allow",
          "lsp" => "allow",
          "skill" => Array(plugins).empty? ? "deny" : "allow",
          "external_directory" => external
        }
        if mode == "read-only"
          return common.merge(
            "edit" => "deny", "bash" => "deny", "task" => "deny",
            "webfetch" => "deny", "websearch" => "deny",
            "question" => "deny"
          )
        end

        writable_roots = [
          roots.fetch(:working), *roots.fetch(:write), *runtime_roots
        ].uniq
        edit = { "*" => "deny" }
        allows = if Array(edit_patterns).empty?
          writable_roots.flat_map do |root|
            root_edit_patterns(root, working: roots.fetch(:working))
          end
        else
          normalize_declared_edit_patterns(
            edit_patterns, writable_roots, working: roots.fetch(:working)
          )
        end
        allows.each { |pattern| edit[pattern] = "allow" }
        (roots.fetch(:read) - roots.fetch(:write)).each do |root|
          root_edit_patterns(root, working: roots.fetch(:working)).each do |pattern|
            edit[pattern] = "deny"
          end
        end
        bash = { "*" => "deny" }
        Array(bash_patterns).each { |pattern| bash[pattern.to_s] = "allow" }
        common.merge(
          "edit" => edit,
          "bash" => Array(bash_patterns).empty? ? "deny" : bash,
          "task" => "deny",
          "webfetch" => "deny", "websearch" => "deny",
          "question" => "deny"
        )
      end

      def expanded_roots(values)
        Array(values).map { |value| File.expand_path(value) }.uniq.freeze
      end
      private_class_method :expanded_roots

      def root_edit_patterns(root, working:)
        if root == working
          [ "**" ]
        elsif root.start_with?(working + File::SEPARATOR)
          relative = root.delete_prefix(working + File::SEPARATOR)
          [ relative, "#{relative}/**" ]
        else
          [ root, "#{root}/**" ]
        end
      end
      private_class_method :root_edit_patterns

      def normalize_declared_edit_patterns(patterns, writable_roots, working:)
        Array(patterns).map do |value|
          pattern = value.to_s.sub(%r{\A//}, "/")
          unless File.absolute_path?(pattern) && !pattern.include?("\0")
            raise ConfigurationError,
                  "OpenCode edit patterns must be absolute path patterns"
          end
          literal_prefix = pattern.split(/[*?]/, 2).first.sub(%r{/+\z}, "")
          unless writable_roots.any? do |root|
            literal_prefix == root ||
              literal_prefix.start_with?(root + File::SEPARATOR)
          end
            raise ConfigurationError,
                  "OpenCode edit pattern is outside the declared write roots"
          end
          if pattern == working
            "**"
          elsif pattern.start_with?(working + File::SEPARATOR)
            pattern.delete_prefix(working + File::SEPARATOR)
          else
            pattern
          end
        end.uniq.freeze
      end
      private_class_method :normalize_declared_edit_patterns

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
      private_class_method :deep_copy
    end
  end
end
