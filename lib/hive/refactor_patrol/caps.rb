require "ripper"

module Hive
  module RefactorPatrol
    class Caps
      NON_PRODUCTION_SURFACE_PATTERN = %r{(?:\A|/)(?:fixtures?|node_modules|specs?|tests?|vendor)(?:/|\z)}i
      JAVASCRIPT_ENTRYPOINT_EXTENSIONS = %w[cjs js jsx mjs ts tsx].join("|").freeze
      PUBLIC_API_PATTERNS = [
        %r{(?:\A|/)(?:bin|exe)/},
        %r{(?:\A|/)(?:schemas?|api|proto|include)/},
        %r{(?:\A|/)cmd/[^/]+/main\.[^/]+\z},
        %r{(?:\A|/)src/(?:main\.[^/]+|bin/)},
        %r{(?:\A|/)(?:main|cli|routes?|router|openapi|asyncapi)\.[^/]+\z},
        %r{(?:\A|/)src/index\.(?:#{JAVASCRIPT_ENTRYPOINT_EXTENSIONS})\z}i,
        %r{\Aindex\.(?:#{JAVASCRIPT_ENTRYPOINT_EXTENSIONS})\z}i,
        %r{\A(?:modules|packages)/(?:@[^/]+/)?[^/]+/(?:src/)?index\.(?:#{JAVASCRIPT_ENTRYPOINT_EXTENSIONS})\z}i,
        %r{(?:\A|/)src/lib\.rs\z},
        %r{(?:\A|/)__init__\.pyi?\z},
        %r{(?:\A|/)module-info\.java\z}i,
        %r{(?:\A|/)META-INF/(?:MANIFEST\.MF|services/)},
        %r{(?:\A|/)PublicAPI\.(?:Shipped|Unshipped)\.txt\z}i,
        %r{(?:\A|/)Properties/AssemblyInfo\.(?:cs|fs|vb)\z}i,
        %r{(?:\A|/)(?:package\.json|py\.typed)\z}i,
        /\.(?:d\.(?:cts|mts|ts)|fsi|gql|graphql|proto|pyi)\z/i
      ].freeze
      DEPENDENCY_MANIFESTS = %w[
        Gemfile Gemfile.lock gems.rb gems.locked
        package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb
        pyproject.toml setup.py setup.cfg requirements.txt Pipfile Pipfile.lock poetry.lock uv.lock
        Cargo.toml Cargo.lock go.mod go.sum go.work go.work.sum composer.json composer.lock mix.exs mix.lock
        Package.swift Package.resolved pom.xml build.gradle build.gradle.kts gradle.lockfile
        settings.gradle settings.gradle.kts gradle.properties ivy.xml project.clj deps.edn build.sbt
        Directory.Build.props Directory.Build.targets Directory.Packages.props
        packages.config packages.lock.json nuget.config global.json
        vcpkg.json vcpkg-configuration.json conanfile.py conanfile.txt
        Podfile Podfile.lock Cartfile Cartfile.resolved
        pubspec.yaml pubspec.lock deno.json deno.jsonc deno.lock
        MODULE.bazel WORKSPACE WORKSPACE.bazel BUILD BUILD.bazel CMakeLists.txt
        flake.nix flake.lock default.nix shell.nix build.zig build.zig.zon
        stack.yaml cabal.project cpanfile Makefile.PL Build.PL rebar.config
      ].freeze
      DEPENDENCY_MANIFEST_PATTERNS = [
        %r{(?:\A|/)requirements(?:[-_.][^/]*)?\.txt\z}i,
        %r{(?:\A|/)gradle/libs\.versions\.toml\z}i,
        /\.(?:bzl|cabal|gemspec)\z/i,
        /\.(?:csproj|fsproj|nuspec|sln|vbproj|vcxproj)\z/i
      ].freeze
      TYPESCRIPT_MEMBER_PATTERN = %r{
        ^\s+(?!(?:if|for|while|switch|catch|return|throw|new|private|protected)\b)
        (?:(?:public|static|readonly|abstract|async|declare|get|set)\s+)*
        (?:constructor|[A-Za-z_$][A-Za-z0-9_$]*)\s*[!?]?\s*(?:\(|:)
      }x
      JAVASCRIPT_MEMBER_PATTERN = %r{
        ^\s+(?!(?:if|for|while|switch|catch|return|throw|new|private|protected)\b)
        (?:(?:static|async|get|set)\s+)*(?:constructor|[A-Za-z_$][A-Za-z0-9_$]*)\s*\(
      }x
      PUBLIC_DECLARATION_PATTERNS = {
        ".cljs" => [ /^\s*\(defn?\s+(?!-)[A-Za-z*!?+_.-]/ ],
        ".clj" => [ /^\s*\(defn?\s+(?!-)[A-Za-z*!?+_.-]/ ],
        ".cs" => [
          /^\s*public\s+(?:(?:abstract|new|partial|readonly|ref|sealed|static|unsafe)\s+)*
            (?:class|delegate|enum|interface|record(?:\s+struct)?|struct)\b/x,
          /^\s*public\s+(?:(?:abstract|async|extern|new|override|sealed|static|unsafe|virtual)\s+)*
            [A-Za-z_][A-Za-z0-9_<>,.?\[\]\s]*\s+[A-Za-z_][A-Za-z0-9_]*\s*\(/x,
          /^\s*public\s+(?:(?:extern|new|static|unsafe)\s+)*[A-Za-z_][A-Za-z0-9_]*\s*\(/,
          /^\s*public\s+(?:(?:const|new|readonly|static|volatile)\s+)*
            [A-Za-z_][A-Za-z0-9_<>,.?\[\]\s]*\s+[A-Za-z_][A-Za-z0-9_]*\s*(?:[;={])/x
        ],
        ".go" => [
          /^\s*func\s+(?:\([^\n)]*\)\s*)?[A-Z][A-Za-z0-9_]*\s*\(/,
          /^\s*type\s+[A-Z][A-Za-z0-9_]*\b/,
          /^\s*(?:const|var)\s+[A-Z][A-Za-z0-9_]*\b/
        ],
        ".ex" => [ /^\s*def(?:delegate|guard|macro)?\s+(?!p\b)[a-zA-Z_][A-Za-z0-9_!?]*/ ],
        ".exs" => [ /^\s*def(?:delegate|guard|macro)?\s+(?!p\b)[a-zA-Z_][A-Za-z0-9_!?]*/ ],
        ".java" => [
          /^\s*public\s+(?:(?:abstract|final|non-sealed|sealed|static|strictfp)\s+)*
            (?:@interface|class|enum|interface|record)\b/x,
          /^\s*public\s+(?:(?:abstract|default|final|native|static|strictfp|synchronized)\s+)*
            [A-Za-z_$][A-Za-z0-9_$<>,.?\[\]\s]*\s+[A-Za-z_$][A-Za-z0-9_$]*\s*\(/x,
          /^\s*public\s+(?:(?:final|strictfp)\s+)*[A-Za-z_$][A-Za-z0-9_$]*\s*\(/,
          /^\s*public\s+(?:(?:final|static|transient|volatile)\s+)*
            [A-Za-z_$][A-Za-z0-9_$<>,.?\[\]\s]*\s+[A-Za-z_$][A-Za-z0-9_$]*\s*(?:[;=])/x
        ],
        ".kt" => [
          /^\s*(?!private\b|internal\b|protected\b)(?:public\s+)?(?:(?:abstract|data|enum|open|sealed|value)\s+)*
            (?:class|fun|interface|object|typealias|val|var)\b/x
        ],
        ".php" => [
          /^\s*(?:public\s+)?(?:abstract\s+|final\s+|readonly\s+)?(?:class|enum|interface|trait)\b/i,
          /^\s*public\s+(?:static\s+)?function\s+[A-Za-z_][A-Za-z0-9_]*/i
        ],
        ".py" => [
          /^\s*__all__\s*=/,
          /^\s*(?:async\s+)?def\s+(?:__init__|[A-Za-z][A-Za-z0-9_]*)\s*\(/,
          /^\s*class\s+(?!_)[A-Za-z][A-Za-z0-9_]*\b/
        ],
        ".rb" => [
          /^\s*def\s+(?:self\.)?[A-Za-z_][A-Za-z0-9_!?=]*/,
          /^\s*(?:class|module)\s+[A-Z][A-Za-z0-9_:]*/
        ],
        ".rs" => [
          /^\s*pub\s+(?!(?:crate|super|self|in)\b)(?:(?:async|const|extern|unsafe)\s+)*
            (?:const|enum|fn|macro|mod|static|struct|trait|type|union|use)\b/x
        ],
        ".scala" => [
          /^\s*(?!private\b|protected\b)(?:(?:abstract|case|final|implicit|lazy|sealed)\s+)*
            (?:class|def|enum|given|object|trait|type|val|var)\b/x
        ],
        ".swift" => [
          /^\s*(?:open|public)\s+(?:(?:actor|class|enum|func|protocol|struct|typealias|var)\b)/
        ],
        ".ts" => [
          /^\s*export\s+(?:default\s+)?(?:(?:abstract|async|declare)\s+)*(?:class|const|enum|function|interface|let|namespace|type|var)\b/,
          TYPESCRIPT_MEMBER_PATTERN
        ],
        ".tsx" => [
          /^\s*export\s+(?:default\s+)?(?:(?:abstract|async|declare)\s+)*(?:class|const|enum|function|interface|let|namespace|type|var)\b/,
          TYPESCRIPT_MEMBER_PATTERN
        ],
        ".js" => [
          /^\s*export\s+(?:default\s+)?(?:async\s+)?(?:class|const|function|let|var)\b/,
          /^\s*(?:module\.exports|exports\.[A-Za-z_$][\w$]*)\s*=/,
          JAVASCRIPT_MEMBER_PATTERN
        ],
        ".jsx" => [
          /^\s*export\s+(?:default\s+)?(?:async\s+)?(?:class|const|function|let|var)\b/,
          JAVASCRIPT_MEMBER_PATTERN
        ],
        ".mjs" => [
          /^\s*export\s+(?:default\s+)?(?:async\s+)?(?:class|const|function|let|var)\b/,
          JAVASCRIPT_MEMBER_PATTERN
        ],
        ".vb" => [ /^\s*Public\s+(?:Class|Delegate|Enum|Interface|Module|Structure)\b/i ]
      }.freeze
      PublicContractGuard = Struct.new(
        :language, :canonical_extension, :patterns,
        keyword_init: true
      )
      # This registry certifies mutation guards, not project/language support.
      # Architecture discovery remains broader and reports missing guards.
      PUBLIC_CONTRACT_GUARD_LANGUAGES = {
        ".clj" => :clojure,
        ".cljs" => :clojure,
        ".cs" => :dotnet,
        ".ex" => :elixir,
        ".exs" => :elixir,
        ".go" => :go,
        ".java" => :java,
        ".js" => :javascript,
        ".jsx" => :javascript,
        ".kt" => :kotlin,
        ".mjs" => :javascript,
        ".php" => :php,
        ".py" => :python,
        ".rb" => :ruby,
        ".rs" => :rust,
        ".scala" => :scala,
        ".swift" => :swift,
        ".ts" => :typescript,
        ".tsx" => :typescript,
        ".vb" => :visual_basic
      }.freeze
      PUBLIC_CONTRACT_GUARD_ALIASES = {
        ".cjs" => ".js",
        ".cts" => ".ts",
        ".kts" => ".kt",
        ".mts" => ".ts",
        ".pyi" => ".py",
        ".rake" => ".rb"
      }.freeze
      PUBLIC_CONTRACT_GUARDS = begin
        guards = PUBLIC_DECLARATION_PATTERNS.to_h do |extension, patterns|
          [
            extension,
            PublicContractGuard.new(
              language: PUBLIC_CONTRACT_GUARD_LANGUAGES.fetch(extension),
              canonical_extension: extension,
              patterns: patterns.freeze
            ).freeze
          ]
        end
        PUBLIC_CONTRACT_GUARD_ALIASES.each do |extension, canonical|
          source = guards.fetch(canonical)
          guards[extension] = PublicContractGuard.new(
            language: source.language,
            canonical_extension: canonical,
            patterns: source.patterns
          ).freeze
        end
        guards.freeze
      end

      def self.public_api_path?(path)
        normalized = normalize_path(path)
        return false if normalized.match?(NON_PRODUCTION_SURFACE_PATTERN)

        PUBLIC_API_PATTERNS.any? { |pattern| normalized.match?(pattern) }
      end

      def self.public_api_declaration?(path, snippet)
        normalized = normalize_path(path)
        return false if normalized.match?(NON_PRODUCTION_SURFACE_PATTERN)
        return false if go_private_package?(normalized, snippet)

        guard = public_contract_guard_for(normalized)
        return false unless guard

        guard.patterns.any? { |pattern| snippet.to_s.match?(pattern) }
      end

      def self.public_declaration_signatures(path, content)
        guard = public_contract_guard_for(path)
        return [] unless guard
        return ruby_public_declaration_signatures(path, content, guard) if guard.canonical_extension == ".rb"

        content.to_s.each_line.filter_map do |line|
          next unless public_api_declaration?(path, line)

          normalize_declaration_signature(guard, line)
        end.sort
      end

      def self.ruby_public_declaration_signatures(path, content, guard)
        non_public_lines = ruby_non_public_definition_lines(content)
        content.to_s.each_line.with_index(1).filter_map do |line, line_number|
          stripped = line.strip
          declaration = public_api_declaration?(path, line)
          next unless declaration
          next if stripped.start_with?("def ") && non_public_lines.include?(line_number)

          normalize_declaration_signature(guard, line)
        end.sort
      end
      private_class_method :ruby_public_declaration_signatures

      # Ruby visibility is scoped to the surrounding class/module. A linear
      # text flag leaks `private` from one class into the next and can omit a
      # real public method from the compatibility snapshot. Ripper gives us
      # just enough structure to mark direct non-public definitions while
      # keeping each nested scope independent. If parsing fails, the empty set
      # is deliberately conservative: all declarations participate in the
      # guard, which may block a fix but cannot let a contract change through.
      def self.ruby_non_public_definition_lines(content)
        tree = Ripper.sexp(content.to_s)
        return {} unless tree

        lines = {}
        ruby_collect_non_public_definitions(tree[1], lines)
        lines
      end
      private_class_method :ruby_non_public_definition_lines

      def self.ruby_collect_non_public_definitions(statements, lines)
        visibility = :public
        Array(statements).each do |statement|
          next unless statement.is_a?(Array)

          case statement[0]
          when :vcall
            candidate = statement.dig(1, 1).to_s
            visibility = candidate.to_sym if %w[private protected public].include?(candidate)
          when :def, :defs
            line = ruby_definition_line(statement)
            lines[line] = true if line && visibility != :public
          when :class
            ruby_collect_non_public_definitions(statement.dig(3, 1), lines)
          when :module, :sclass
            ruby_collect_non_public_definitions(statement.dig(2, 1), lines)
          when :command
            visibility_name = statement.dig(1, 1).to_s
            next unless %w[private protected].include?(visibility_name)

            ruby_definition_nodes(statement).each do |definition|
              line = ruby_definition_line(definition)
              lines[line] = true if line
            end
          end
        end
      end
      private_class_method :ruby_collect_non_public_definitions

      def self.ruby_definition_nodes(node, result = [])
        return result unless node.is_a?(Array)
        return result << node if %i[def defs].include?(node[0])

        node.each { |child| ruby_definition_nodes(child, result) if child.is_a?(Array) }
        result
      end
      private_class_method :ruby_definition_nodes

      def self.ruby_definition_line(definition)
        token = definition[0] == :def ? definition[1] : definition[3]
        token.dig(2, 0) if token.is_a?(Array)
      end
      private_class_method :ruby_definition_line

      def self.public_contract_guard_for(path)
        normalized = normalize_path(path)
        PUBLIC_CONTRACT_GUARDS[File.extname(normalized).downcase]
      end

      def self.public_contract_guard_available?(path)
        !public_contract_guard_for(path).nil?
      end

      def self.normalize_declaration_signature(guard, line)
        signature = line.to_s.strip
        case guard.canonical_extension
        when ".rb"
          signature = signature.sub(/\s+=\s+.*\z/, "") if signature.start_with?("def ")
        when ".ex", ".exs"
          signature = signature.sub(/\s+do\b.*\z/, "")
        when ".py"
          signature = signature.sub(/:\s*\z/, "")
        else
          signature = signature.sub(/\s*(?:\{|=>).*\z/, "")
        end
        signature.gsub(/\s+/, " ").strip
      end
      private_class_method :normalize_declaration_signature

      def self.dependency_manifest?(path)
        normalized = normalize_path(path)
        basename = File.basename(normalized)
        DEPENDENCY_MANIFESTS.any? { |manifest| manifest.casecmp?(basename) } ||
          DEPENDENCY_MANIFEST_PATTERNS.any? { |pattern| normalized.match?(pattern) }
      end

      def self.normalize_path(path)
        path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      end

      def self.go_private_package?(path, snippet)
        File.extname(path).casecmp?(".go") &&
          (path.match?(%r{(?:\A|/)(?:cmd|internal)(?:/|\z)}) || path.end_with?("_test.go") ||
            snippet.to_s.match?(/^\s*package\s+main\b/))
      end
      private_class_method :go_private_package?, :normalize_path

      Result = Struct.new(:thesis, :blocked, :flags, keyword_init: true)

      def initialize(cfg)
        @cfg = cfg
      end

      def apply(thesis)
        risk = thesis.risk ||= {}
        risk["flags"] = Array(risk["flags"]).map(&:to_s)
        risk["advisories"] = Array(risk["advisories"]).map(&:to_s)
        risk["public_api_details"] = Array(risk["public_api_details"])
        risk["cross_feature_details"] = Array(risk["cross_feature_details"])

        flags = []
        flags.concat(check_caps(thesis))
        flags.concat(detect_public_api(thesis))
        flags.concat(detect_cross_feature(thesis))
        flags.concat(detect_dependency_bumps(thesis))
        risk["flags"] |= flags
        Result.new(thesis: thesis, blocked: false, flags: flags)
      end

      private

      def check_caps(thesis)
        flags = []
        declared = thesis.risk.fetch("caps", {})
        caps_cfg = caps

        flags << "exceeds_max_files" if declared["est_files"].to_i > caps_cfg.fetch("max_files", 8).to_i
        flags << "exceeds_max_diff_lines" if declared["est_diff_lines"].to_i > caps_cfg.fetch("max_diff_lines", 400).to_i
        if caps_cfg.fetch("single_feature_only", true) && declared.key?("single_feature") && declared["single_feature"] != true
          flags << "not_single_feature"
        end
        flags
      end

      def detect_public_api(thesis)
        return [] if caps.fetch("allow_public_api_changes", false)

        paths = candidate_paths(thesis)
        details = paths.select { |path| self.class.public_api_path?(path) }.uniq
        details |= evidence_public_api_paths(thesis)
        thesis.risk["public_api_details"] |= details

        # R9/R10 never-silently-clean: an agent-declared contract change is
        # always flagged, even when no heuristic path matches.
        if thesis.risk["public_api_impact"] == true
          return [ "public_api_impact" ]
        end

        # A thesis is behavior-preserving by contract, so merely working
        # inside files that host public surface (bin/, cli.rb, schemas/…) is
        # not an API change. Surface it as an advisory — visible in the
        # report, weighed by the human — without disqualifying the thesis.
        thesis.risk["advisories"] |= [ "touches_public_api_surface" ] unless details.empty?
        []
      end

      def detect_cross_feature(thesis)
        return [] if caps.fetch("allow_cross_feature", false)

        boundary = thesis.feature_boundary || {}
        # A feature's own entrypoints are part of its boundary; only paths
        # outside both owned_files and entrypoints count as cross-feature.
        own = (Array(boundary["owned_files"]) + Array(boundary["entrypoints"])).map { |path| path.to_s.tr("\\", "/") }
        out_of_boundary = candidate_paths(thesis).reject { |path| own.include?(path) }.uniq
        # R9/R10 never-silently-clean: honor an agent-declared risk even when no
        # out-of-boundary path is detected, so a disallowed cap is always flagged.
        declared = thesis.risk["cross_feature_impact"] == true
        return [] if out_of_boundary.empty? && !declared

        thesis.risk["cross_feature_impact"] = true
        thesis.risk["cross_feature_details"] |= out_of_boundary
        [ "cross_feature_impact" ]
      end

      def detect_dependency_bumps(thesis)
        return [] if caps.fetch("allow_dependency_bumps", false)

        manifests = candidate_paths(thesis).select { |path| self.class.dependency_manifest?(path) }
        mentions = dependency_manifest_mentions("#{thesis.proposed_refactor} #{thesis.problem}")
        details = (manifests + mentions).uniq
        return [] if details.empty?

        # A dependency bump crosses the feature boundary, so flag the impact
        # too — otherwise populated cross_feature_details with
        # cross_feature_impact: false reads as inconsistent.
        thesis.risk["cross_feature_impact"] = true
        thesis.risk["cross_feature_details"] |= details
        [ "dependency_bump" ]
      end

      def candidate_paths(thesis)
        boundary = thesis.feature_boundary || {}
        paths = Array(boundary["owned_files"]) + Array(boundary["entrypoints"])
        paths.concat(Array(thesis.evidence).filter_map { |item| item["file"] if item.is_a?(Hash) })
        paths.map { |path| path.to_s.tr("\\", "/") }.reject(&:empty?)
      end

      def evidence_public_api_paths(thesis)
        Array(thesis.evidence).filter_map do |item|
          next unless item.is_a?(Hash)

          path = item["file"].to_s.tr("\\", "/")
          next if path.empty? || !self.class.public_api_declaration?(path, item["snippet"])

          path
        end.uniq
      end

      def dependency_manifest_mentions(text)
        known = DEPENDENCY_MANIFESTS.select { |manifest| text.to_s.include?(manifest) }
        paths = text.to_s.scan(/[A-Za-z0-9_@.+\\\/-]+/).filter_map do |token|
          candidate = token.sub(/[.]+\z/, "")
          candidate if self.class.dependency_manifest?(candidate)
        end
        (known + paths).uniq
      end

      def caps
        @cfg.dig("refactor_patrol", "caps") || {}
      end
    end
  end
end
