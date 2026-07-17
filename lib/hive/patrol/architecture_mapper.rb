require "digest"
require "json"
require "pathname"
require "set"
require "hive/patrol/feature"
require "hive/patrol/source_reader"

module Hive
  module Patrol
    # Maps language and package conventions onto bounded, non-overlapping
    # architecture components. Parsers are deliberately lightweight: package
    # manifests establish roots and per-language import scanners add context.
    class ArchitectureMapper
      MAX_COMPONENT_FILES = 64
      MAX_ID_SLUG = 96
      SOURCE_EXTENSIONS = %w[
        .rb .rake .erb .haml .slim .js .jsx .mjs .cjs .ts .tsx .mts .cts
        .py .pyi .go .rs .swift .java .kt .kts .cs .fs .fsx .php .ex .exs
        .eex .erl .hrl .clj .cljs .scala .c .h .cc .cpp .cxx .hpp .m .mm
        .zig .nim .lua .pl .pm .sh .bash .zsh .fish .sol .dart .vue .svelte
        .r .jl .hs .lhs .ml .mli .vb .v .vhd .vhdl .asm .s .cob .cbl .sql
        .graphql .gql .proto .tf .tfvars .hcl .cue .rego .bicep .nix .cmake
        .mk .groovy .gradle .pas .pp .rkt .scm .ss .lisp .cl .el .tcl .sv
        .svh .d .cr .ps1 .bat .cmd .f .f90 .f95 .f03 .f08 .adb .ads
        .html .htm .css .scss .sass .less
      ].freeze
      NON_SOURCE_EXTENSIONS = %w[
        .md .mdx .rst .adoc .asciidoc .txt .json .jsonl .yml .yaml .toml
        .lock .csv .tsv .xml .svg .png .jpg
        .jpeg .gif .webp .ico .pdf .zip .gz .tar .tgz .woff .woff2 .ttf
        .mp4 .mov .webm .avi .ignore
      ].freeze
      SOURCE_ROOTS = %w[
        app apps api ansible charts cmd components crates css database db deploy
        deployments helm infra infrastructure internal kubernetes k8s lib modules
        packages pkg playbooks proto R roles schemas scripts services Sources sql src
        styles templates terraform tools
      ].freeze
      SOURCE_FILENAMES = %w[
        BUILD BUILD.bazel BUCK WORKSPACE WORKSPACE.bazel Dockerfile Containerfile
        Jenkinsfile Makefile CMakeLists.txt Justfile Rakefile Tiltfile Vagrantfile
        Procfile meson.build
      ].freeze
      TEST_SEGMENTS = %w[test tests spec specs __tests__].freeze
      MANIFEST_NAMES = %w[
        package.json pyproject.toml setup.py setup.cfg go.mod Cargo.toml
        Package.swift Gemfile composer.json mix.exs pom.xml build.gradle
        build.gradle.kts DESCRIPTION Project.toml Manifest.toml stack.yaml
        cabal.project pubspec.yaml rebar.config project.clj deps.edn build.sbt
        build.zig build.zig.zon CMakeLists.txt Makefile meson.build flake.nix
        deno.json deno.jsonc go.work
      ].freeze
      MANIFEST_EXTENSIONS = %w[
        .gemspec .cabal .csproj .fsproj .vbproj .sln .vcxproj
      ].freeze
      COMMAND_PATTERNS = [
        %r{\A(?:bin|exe)/[^/]+\z}, %r{\Acmd/[^/]+/main\.go\z},
        %r{\Asrc/main\.rs\z}, %r{\Asrc/bin/[^/]+\.rs\z}
      ].freeze

      def self.source_candidate_path?(path)
        normalized = path.to_s.tr("\\", "/")
        basename = File.basename(normalized)
        extension = File.extname(normalized).downcase
        return true if SOURCE_FILENAMES.any? { |name| name.casecmp?(basename) }
        return true if SOURCE_EXTENSIONS.include?(extension)
        return true if architecture_config_path?(normalized, extension)
        return false if extension.empty? || NON_SOURCE_EXTENSIONS.include?(extension)

        true
      end

      def self.architecture_config_path?(path, extension = File.extname(path).downcase)
        normalized = path.to_s.tr("\\", "/")
        segments = normalized.split("/").map(&:downcase)
        basename = segments.last.to_s
        return true if %w[docker-compose.yml docker-compose.yaml compose.yml compose.yaml].include?(basename)

        if %w[.yml .yaml].include?(extension)
          roots = %w[
            ansible charts deploy deployments helm infra infrastructure kubernetes
            k8s playbooks roles terraform
          ]
          return true unless (segments & roots).empty?
        end
        if %w[.json .yaml .yml].include?(extension)
          roots = %w[api openapi proto schemas]
          return true unless (segments & roots).empty?
        end

        false
      end

      attr_reader :component_roots, :dependency_edges, :reserved_command_files, :source_files

      def initialize(project_root, cfg:, review_scope: :refactor_patrol)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @review_scope = review_scope.to_sym
        @source_reader = Hive::Patrol::SourceReader.new(@project_root)
      end

      def call(files)
        reset_scan(files)
        groups = component_groups
        @component_roots = groups.each_with_object({}) do |(root, paths), result|
          paths.each { |path| result[path] = root }
        end
        @reserved_command_files.each { |path| @component_roots[path] = component_root(path) }
        @component_roots.freeze
        prepare_collision_safe_slugs(groups.keys)

        groups.flat_map do |root, owned|
          chunks = owned.sort.each_slice(max_component_files).to_a
          chunks.each_with_index.map { |chunk, index| build_feature(root, chunk, index, chunks) }
        end.sort_by(&:id)
      end

      private

      def reset_scan(files)
        @files = Array(files).map { |path| normalize(path) }.uniq.sort
                             .select { |path| @source_reader.regular_file?(path) }
        @content_cache = {}
        @dependency_cache = {}
        @manifests = @files.select { |path| production_manifest_path?(path) }
        @manifests_by_directory = @manifests.group_by { |path| directory(path) }
        @reserved_command_files = (
          @files.select { |path| command_path?(path) } + package_bin_entrypoints
        ).uniq.sort.freeze
        @reserved_command_set = @reserved_command_files.to_set
        @source_files = @files.select { |path| source_file?(path) }
        @source_set = @source_files.to_set
        @resolvable_files = (@source_files + @reserved_command_files).uniq.sort
        @resolvable_set = @resolvable_files.to_set
        @resolvable_by_directory = @resolvable_files.group_by { |path| File.dirname(path) }
        @resolvable_extensions = (
          @resolvable_files.map { |path| File.extname(path).downcase } + SOURCE_EXTENSIONS
        ).reject(&:empty?).uniq.freeze
        @tests = @files.select { |path| test_path?(path) && code_path?(path) }
        build_ecosystem_indexes
        @commands_by_root = @reserved_command_files.group_by { |path| component_root(path) }
        build_inbound_index
        build_test_index
        @dependency_edges = @resolvable_files.to_h do |path|
          [ path, dependency_paths(path).dup.freeze ]
        end.freeze
        @source_files = @source_files.dup.freeze
      end

      def component_groups
        groups = @source_files.group_by { |path| component_root(path) }
        @manifests.each do |path|
          root = directory(path)
          key = "manifest:#{root == '.' ? 'project' : root}"
          (groups[key] ||= []) << path
        end
        groups.sort.to_h
      end

      def source_file?(path)
        return false if test_path?(path) || @reserved_command_set.include?(path) || manifest_path?(path)

        code_path?(path)
      end

      def code_path?(path)
        extension = File.extname(path).downcase
        return shebang_script?(path) if extension.empty? && !self.class.source_candidate_path?(path)

        return false unless self.class.source_candidate_path?(path)
        return true if SOURCE_EXTENSIONS.include?(extension)

        text_file?(path)
      end

      def shebang_script?(path)
        @source_reader.read_bytes(path, limit: 2) == "#!"
      end

      def text_file?(path)
        return false unless @source_reader.regular_file?(path)

        sample = @source_reader.read_bytes(path, limit: 4096)
        !sample.include?("\0")
      end

      def test_path?(path)
        parts = path.split("/").map(&:downcase)
        TEST_SEGMENTS.any? { |segment| parts.include?(segment) } ||
          File.basename(path).match?(/(?:_test|_spec|\.test|\.spec)\.[^.]+\z/i)
      end

      def command_path?(path)
        COMMAND_PATTERNS.any? { |pattern| path.match?(pattern) }
      end

      def package_bin_entrypoints
        return [] unless @files.include?("package.json")

        value = JSON.parse(read("package.json"))["bin"]
        entries = value.is_a?(Hash) ? value.values : Array(value)
        entries.map { |path| normalize(path) }.select { |path| @files.include?(path) }
      rescue JSON::ParserError
        []
      end

      def manifest_path?(path)
        basename = File.basename(path)
        MANIFEST_NAMES.include?(basename) || MANIFEST_EXTENSIONS.include?(File.extname(basename).downcase)
      end

      def production_manifest_path?(path)
        return false unless manifest_path?(path)

        segments = path.split("/").map(&:downcase)
        !test_path?(path) && (segments & %w[fixture fixtures]).empty?
      end

      def component_root(path)
        parts = path.split("/")
        manifest = nearest_manifest(path)
        manifest_root = directory(manifest) if manifest
        return manifest_root if manifest_root && manifest_root != "."

        case parts.first
        when "apps", "packages", "services", "crates", "Sources", "cmd", "internal", "pkg"
          return parts.first(2).join("/") if parts.size >= 3
        when "lib"
          return parts.first(2).join("/") if parts.size <= 3
          return parts.first(3).join("/")
        when "src", "app"
          return parts.first(2).join("/") if parts.size >= 3
          return parts.first
        end
        if SOURCE_ROOTS.map(&:downcase).include?(parts.first.to_s.downcase)
          return parts.first(2).join("/") if parts.size >= 3
          return parts.first
        end
        File.dirname(path) == "." ? path : File.dirname(path)
      end

      def build_feature(root, owned, index, chunks)
        entrypoint = entrypoint_for(owned)
        manifests = manifests_for(owned)
        commands = commands_for(root)
        entrypoints = [ entrypoint, *commands ].compact.uniq
        dependencies = (owned.flat_map { |path| dependency_paths(path) }.uniq - owned).sort
        inbound = (owned.flat_map { |path| @inbound_by_path[path] }.uniq - owned).sort
        peer_entrypoints = chunks.reject { |chunk| chunk.equal?(owned) }.filter_map do |chunk|
          entrypoint_for(chunk)
        end.sort
        context = ordered_cap(dependencies + inbound + manifests + peer_entrypoints, max_context_files)

        Feature.new(
          id: component_id(root, index),
          kind: "architecture",
          entrypoints: entrypoints,
          owned_files: owned,
          context_files: context - owned - entrypoints,
          tests: ordered_cap(tests_for(root, owned), max_context_files)
        )
      end

      def entrypoint_for(paths)
        priorities = %w[main index lib __init__ application app]
        paths.min_by do |path|
          stem = File.basename(path, File.extname(path))
          [ priorities.index(stem) || priorities.size, path.count("/"), path ]
        end
      end

      def manifests_for(paths)
        paths.filter_map { |path| nearest_manifest(path) }.uniq.sort
      end

      def commands_for(root)
        Array(@commands_by_root[root]).sort
      end

      def tests_for(root, owned)
        direct = owned.flat_map { |path| @tests_by_source[path] }
        (direct + @tests_by_root[root]).uniq.sort
      end

      def swift_test_target_root(path)
        parts = path.split("/")
        return unless parts.first&.casecmp?("tests") && parts[1]

        target = parts[1].sub(/Tests?\z/i, "")
        "Sources/#{target}"
      end

      def mirrored_source_candidates(test)
        path = test.sub(%r{\A(?:test|tests|spec|specs)/}i, "")
        extension = File.extname(path)
        stem = path.delete_suffix(extension).sub(/(?:_test|_spec|\.test|\.spec)\z/i, "")
        SOURCE_ROOTS.flat_map do |root|
          SOURCE_EXTENSIONS.map { |source_extension| "#{root}/#{stem}#{source_extension}" }
        end.select { |candidate| @source_set.include?(candidate) }
      end

      def dependency_paths(path)
        @dependency_cache[path] ||= import_references(path).flat_map do |kind, token|
          resolve_import(path, kind, token)
        end.uniq.sort
      end

      def import_references(path)
        content = read(path)
        case File.extname(path).downcase
        when ".rb", ".rake"
          ruby_imports(content)
        when ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"
          javascript_imports(content)
        when ".py", ".pyi"
          python_imports(content)
        when ".go"
          go_imports(content)
        when ".rs"
          rust_imports(content)
        when ".swift"
          content.scan(/^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)/).flatten.map { |token| [ :swift, token ] }
        when ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".m", ".mm"
          c_imports(content)
        else
          generic_relative_imports(content)
        end.uniq
      end

      def generic_relative_imports(content)
        tokens = content.scan(
          /(?:\b(?:import|include|load|require|source)\b|@import)\s*(?:\(\s*)?["']([^"']+)["']/
        ).flatten
        tokens.concat(content.scan(/\bsource\s*=\s*["']([^"']+)["']/).flatten)
        paths = tokens.filter_map do |token|
          next if token.match?(%r{\A(?:https?:)?//})

          [ token.start_with?(".") ? :generic_relative : :generic_root, token ]
        end
        modules = content.scan(
          %r{^\s*(?:import|using|use|alias|require)\s+(?:(?:static|qualified)\s+)?([A-Za-z_][A-Za-z0-9_.:/\\-]*)}
        ).flatten.map { |token| [ :generic_module, token ] }
        paths + modules
      end

      def ruby_imports(content)
        relative = content.scan(/\brequire_relative\s*\(?\s*["']([^"']+)["']/).flatten.map do |token|
          [ :ruby_relative, token ]
        end
        required = content.scan(/\brequire\s*\(?\s*["']([^"']+)["']/).flatten.map do |token|
          [ :ruby_require, token ]
        end
        relative + required
      end

      def javascript_imports(content)
        tokens = []
        tokens.concat(content.scan(/\b(?:import|export)\b[^"']*\bfrom\s*["']([^"']+)["']/).flatten)
        tokens.concat(content.scan(/\bimport\s*["']([^"']+)["']/).flatten)
        tokens.concat(content.scan(/\brequire\s*\(\s*["']([^"']+)["']\s*\)/).flatten)
        tokens.concat(content.scan(/\bimport\s*\(\s*["']([^"']+)["']\s*\)/).flatten)
        tokens.map { |token| [ token.start_with?(".") ? :js_relative : :js_package, token ] }
      end

      def python_imports(content)
        references = content.scan(/^\s*from\s+([.A-Za-z_][.A-Za-z0-9_]*)\s+import\b/).flatten.map do |token|
          [ token.start_with?(".") ? :python_relative : :python_absolute, token ]
        end
        content.scan(/^\s*import\s+([^#\n]+)/).flatten.each do |list|
          list.split(",").each do |item|
            token = item.strip.split(/\s+as\s+/, 2).first
            references << [ :python_absolute, token ] unless token.to_s.empty?
          end
        end
        references
      end

      def go_imports(content)
        tokens = content.scan(/^\s*import\s+"([^"]+)"/).flatten
        content.scan(/\bimport\s*\((.*?)\)/m).each do |body|
          tokens.concat(body.first.scan(/"([^"]+)"/).flatten)
        end
        tokens.map { |token| [ :go, token ] }
      end

      def rust_imports(content)
        modules = content.scan(/^\s*(?:pub\s+)?mod\s+([A-Za-z_][A-Za-z0-9_]*)\s*;/).flatten.map do |token|
          [ :rust_mod, token ]
        end
        uses = content.scan(/^\s*(?:pub\s+)?use\s+([^;]+);/).flatten.map do |token|
          [ :rust_use, token.strip ]
        end
        modules + uses
      end

      def c_imports(content)
        quoted = content.scan(/^\s*#include\s*"([^"]+)"/).flatten.map { |token| [ :c_quote, token ] }
        angled = content.scan(/^\s*#include\s*<([^>]+)>/).flatten.map { |token| [ :c_angle, token ] }
        quoted + angled
      end

      def resolve_import(source, kind, token)
        case kind
        when :ruby_relative
          resolve_path(File.join(File.dirname(source), token))
        when :ruby_require
          resolve_from_roots(token, source, preferred_roots: %w[lib])
        when :js_relative
          resolve_path(File.join(File.dirname(source), token))
        when :js_package
          resolve_javascript_package(token)
        when :python_relative
          resolve_python_relative(source, token)
        when :python_absolute
          Array(@python_modules[token])
        when :go
          resolve_go_import(token)
        when :rust_mod
          resolve_path(File.join(File.dirname(source), token))
        when :rust_use
          resolve_rust_use(source, token)
        when :swift
          @swift_targets.fetch(token, [])
        when :c_quote
          resolve_path(File.join(File.dirname(source), token))
        when :c_angle
          resolve_from_roots(token, source, preferred_roots: %w[include src/include])
        when :generic_relative
          resolve_path(File.join(File.dirname(source), token))
        when :generic_root
          (resolve_from_roots(token, source, preferred_roots: SOURCE_ROOTS) +
            resolve_generic_module(token)).uniq
        when :generic_module
          resolve_generic_module(token)
        else
          []
        end
      end

      def resolve_javascript_package(token)
        name = @javascript_packages.keys.select do |candidate|
          token == candidate || token.start_with?("#{candidate}/")
        end.max_by(&:length)
        return [] unless name

        package = @javascript_packages.fetch(name)
        suffix = token.delete_prefix(name).sub(%r{\A/}, "")
        return resolve_path(File.join(package.fetch(:root), suffix)) unless suffix.empty?

        data = package.fetch(:data)
        declared = %w[types typings module main].filter_map { |key| data[key] }
        candidates = declared.map { |value| File.join(package.fetch(:root), value.to_s) }
        candidates += %w[src/index index].map { |value| File.join(package.fetch(:root), value) }
        candidates.flat_map { |candidate| resolve_path(candidate) }.uniq
      end

      def resolve_python_relative(source, token)
        dots = token[/\A\.+/].to_s.length
        base = File.dirname(source)
        [ dots - 1, 0 ].max.times { base = File.dirname(base) }
        suffix = token.sub(/\A\.+/, "").tr(".", "/")
        resolve_path(suffix.empty? ? base : File.join(base, suffix))
      end

      def resolve_go_import(token)
        name = @go_modules.keys.select { |candidate| token == candidate || token.start_with?("#{candidate}/") }.max_by(&:length)
        return [] unless name

        root = @go_modules.fetch(name)
        suffix = token.delete_prefix(name).sub(%r{\A/}, "")
        resolve_path(suffix.empty? ? root : File.join(root, suffix))
      end

      def resolve_rust_use(source, token)
        normalized = token.gsub(/[{}\s]/, "").sub(/\A::/, "")
        segments = normalized.split("::").reject(&:empty?)
        cargo_root = nearest_manifest_directory(source, :rust) || "."
        base = File.join(cargo_root == "." ? "" : cargo_root, "src")

        case segments.first
        when "crate"
          segments.shift
        when "self"
          segments.shift
          base = File.dirname(source)
        when "super"
          segments.shift
          base = File.dirname(File.dirname(source))
        else
          crate = @rust_packages[segments.first.to_s.tr("-", "_")]
          if crate
            segments.shift
            base = File.join(crate, "src")
          end
        end

        resolve_progressively(base, segments)
      end

      def resolve_progressively(base, segments)
        values = segments.dup
        until values.empty?
          resolved = resolve_path(File.join(base, *values))
          return resolved unless resolved.empty?

          values.pop
        end
        []
      end

      def resolve_from_roots(token, source, preferred_roots:)
        roots = [ File.dirname(source) ]
        manifest_root = nearest_manifest_directory(source)
        roots << manifest_root if manifest_root
        roots.concat(preferred_roots)
        roots.uniq.flat_map { |root| resolve_path(File.join(root == "." ? "" : root, token)) }.uniq
      end

      def resolve_path(candidate)
        clean = normalize(candidate)
        paths = import_candidates(clean).select { |path| @resolvable_set.include?(path) }
        paths + Array(@resolvable_by_directory[clean])
      end

      def import_candidates(candidate)
        [ candidate ] + @resolvable_extensions.map { |extension| "#{candidate}#{extension}" } +
          %w[index __init__ lib main].flat_map do |stem|
            @resolvable_extensions.map { |extension| File.join(candidate, "#{stem}#{extension}") }
          end
      end

      def build_ecosystem_indexes
        @javascript_packages = {}
        @python_modules = Hash.new { |hash, key| hash[key] = [] }
        @go_modules = {}
        @rust_packages = {}
        @swift_targets = Hash.new { |hash, key| hash[key] = [] }
        build_generic_module_index

        @manifests.each do |manifest|
          case manifest_kind(manifest)
          when :javascript then index_javascript_package(manifest)
          when :go then index_go_module(manifest)
          when :rust then index_rust_package(manifest)
          end
        end
        @source_files.each do |path|
          index_python_module(path) if %w[.py .pyi].include?(File.extname(path).downcase)
          index_swift_target(path) if File.extname(path).casecmp?(".swift")
        end
        @python_modules.each_value { |paths| paths.replace(paths.uniq.sort) }
        @swift_targets.each_value { |paths| paths.replace(paths.uniq.sort) }
      end

      def build_generic_module_index
        @generic_modules = Hash.new { |hash, key| hash[key] = [] }
        @resolvable_files.each do |path|
          stem = path.sub(/\.[^.]+\z/, "")
          segments = stem.split("/")
          candidates = [ stem ]
          segments.each_index do |index|
            suffix = segments.drop(index)
            candidates << suffix.join("/")
          end
          candidates.map { |candidate| normalize_module_token(candidate) }
                    .reject(&:empty?).uniq.each do |candidate|
            @generic_modules[candidate] << path
          end
        end
        @generic_modules.each_value { |paths| paths.replace(paths.uniq.sort) }
      end

      def resolve_generic_module(token)
        key = normalize_module_token(token)
        keys = [ key ]
        keys << key.split("/").drop(1).join("/") if token.to_s.start_with?("package:")
        segments = key.split("/")
        while segments.size > 2
          segments = segments.first(segments.size - 1)
          keys << segments.join("/")
        end
        keys.flat_map do |candidate|
          paths = Array(@generic_modules[candidate])
          candidate.include?("/") || paths.one? ? paths : []
        end.uniq.sort
      end

      def normalize_module_token(token)
        value = token.to_s.strip.sub(/\Apackage:/, "").sub(/[;,*{].*\z/, "")
        value = value.sub(/\.(?:dart|proto|css|scss|sass|less)\z/i, "") if token.to_s.start_with?("package:")
        value.gsub("::", "/")
             .gsub("\\", "/").tr(".", "/")
             .gsub(%r{/+}, "/").sub(%r{\A/+|/+\z}, "")
             .downcase
      end

      def build_inbound_index
        @inbound_by_path = Hash.new { |hash, key| hash[key] = [] }
        @source_files.each do |source|
          dependency_paths(source).each { |dependency| @inbound_by_path[dependency] << source }
        end
        @inbound_by_path.each_value { |paths| paths.replace(paths.uniq.sort) }
      end

      def build_test_index
        @tests_by_source = Hash.new { |hash, key| hash[key] = [] }
        @tests_by_root = Hash.new { |hash, key| hash[key] = [] }
        @tests.each do |test|
          dependency_paths(test).each { |dependency| @tests_by_source[dependency] << test }
          roots = [ swift_test_target_root(test) ]
          manifest = nearest_manifest(test)
          roots << directory(manifest) if manifest
          roots.concat(mirrored_source_candidates(test).map { |source| component_root(source) })
          roots.compact.uniq.each { |root| @tests_by_root[root] << test }
        end
        [ @tests_by_source, @tests_by_root ].each do |index|
          index.each_value { |paths| paths.replace(paths.uniq.sort) }
        end
      end

      def index_javascript_package(manifest)
        data = JSON.parse(read(manifest))
        name = data["name"].to_s
        @javascript_packages[name] = { root: directory(manifest), data: data } unless name.empty?
      rescue JSON::ParserError
        nil
      end

      def index_python_module(path)
        root = nearest_manifest_directory(path, :python) || "."
        relative = relative_to(root, path).sub(%r{\Asrc/}, "")
        module_path = relative.sub(/\.(?:py|pyi)\z/, "").sub(%r{/__init__\z}, "")
        key = module_path.tr("/", ".")
        @python_modules[key] << path unless key.empty?
      end

      def index_go_module(manifest)
        name = read(manifest)[/^\s*module\s+(\S+)/, 1]
        @go_modules[name] = directory(manifest) if name
      end

      def index_rust_package(manifest)
        name = toml_section_value(read(manifest), "package", "name")
        @rust_packages[name.tr("-", "_")] = directory(manifest) if name
      end

      def index_swift_target(path)
        parts = path.split("/")
        return unless parts.first == "Sources" && parts[1]

        @swift_targets[parts[1]] << path
      end

      def toml_section_value(content, section, key)
        active = false
        content.each_line do |line|
          stripped = line.strip
          if stripped.start_with?("[")
            active = stripped == "[#{section}]"
            next
          end
          next unless active

          match = stripped.match(/\A#{Regexp.escape(key)}\s*=\s*["']([^"']+)["']/)
          return match[1] if match
        end
        nil
      end

      def nearest_manifest(path, kind = language_kind(path))
        directory_path = File.dirname(path)
        loop do
          candidates = Array(@manifests_by_directory[directory_path]).select do |manifest|
            kind.nil? || manifest_kind(manifest) == kind
          end
          return candidates.sort.first unless candidates.empty?
          break if directory_path == "."

          directory_path = File.dirname(directory_path)
        end
        nil
      end

      def nearest_manifest_directory(path, kind = language_kind(path))
        manifest = nearest_manifest(path, kind)
        directory(manifest) if manifest
      end

      def manifest_kind(path)
        kind = case File.basename(path)
        when "package.json" then :javascript
        when "pyproject.toml", "setup.py", "setup.cfg" then :python
        when "go.mod" then :go
        when "Cargo.toml" then :rust
        when "Package.swift" then :swift
        when "Gemfile" then :ruby
        when /\.gemspec\z/ then :ruby
        when "composer.json" then :php
        when "mix.exs" then :elixir
        when "pom.xml", "build.gradle", "build.gradle.kts" then :jvm
        when "DESCRIPTION" then :r
        when "Project.toml", "Manifest.toml" then :julia
        when "stack.yaml", "cabal.project" then :haskell
        when "pubspec.yaml" then :dart
        when "build.zig", "build.zig.zon" then :zig
        when "CMakeLists.txt", "Makefile", "meson.build" then :native
        when "rebar.config" then :erlang
        when "project.clj", "deps.edn" then :clojure
        when "build.sbt" then :scala
        when "flake.nix" then :nix
        end
        return kind if kind
        return :haskell if File.extname(path).casecmp?(".cabal")
        :dotnet if %w[.csproj .fsproj .vbproj .sln].include?(File.extname(path).downcase)
      end

      def language_kind(path)
        case File.extname(path).downcase
        when ".rb", ".rake" then :ruby
        when ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts" then :javascript
        when ".py", ".pyi" then :python
        when ".go" then :go
        when ".rs" then :rust
        when ".swift" then :swift
        when ".php" then :php
        when ".ex", ".exs", ".eex" then :elixir
        when ".java", ".kt", ".kts" then :jvm
        when ".r" then :r
        when ".jl" then :julia
        when ".hs", ".lhs" then :haskell
        when ".dart" then :dart
        when ".zig" then :zig
        when ".erl", ".hrl" then :erlang
        when ".clj", ".cljs" then :clojure
        when ".scala" then :scala
        when ".cs", ".fs", ".fsx", ".vb" then :dotnet
        when ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".m", ".mm" then :native
        when ".nix" then :nix
        end
      end

      def prepare_collision_safe_slugs(roots)
        raw = roots.to_h { |root| [ root, normalized_slug(root) ] }
        collisions = raw.group_by { |_root, value| value }.transform_values(&:size)
        @root_slugs = raw.to_h do |root, value|
          needs_digest = collisions.fetch(value) > 1 || unsliced_slug(root).length > MAX_ID_SLUG
          suffix = needs_digest ? "-#{::Digest::SHA256.hexdigest(root)[0, 8]}" : ""
          stem = value[0, MAX_ID_SLUG - suffix.length]
          [ root, "#{stem}#{suffix}" ]
        end
      end

      def component_id(root, index)
        id = "architecture-#{@root_slugs.fetch(root)}"
        index.zero? ? id : "#{id}-part-#{index + 1}"
      end

      def normalized_slug(value)
        slug = unsliced_slug(value)
        (slug.empty? ? "root" : slug)[0, MAX_ID_SLUG]
      end

      def unsliced_slug(value)
        value.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      end

      def max_component_files
        configured = review_limit("max_owned_files")
        configured ||= MAX_COMPONENT_FILES
        [ [ configured.to_i, 1 ].max, MAX_COMPONENT_FILES ].min
      end

      def max_context_files
        configured = review_limit("max_context_files")
        [ configured || 6, 0 ].max
      end

      def review_limit(key)
        if @review_scope == :patrol
          @cfg.dig("patrol", "review", key)
        else
          @cfg.dig("refactor_patrol", "review", key) ||
            @cfg.dig("patrol", "review", key)
        end
      end

      def ordered_cap(paths, limit)
        paths.compact.uniq.first(limit)
      end

      def relative_to(root, path)
        return path if root == "."

        path.delete_prefix("#{root}/")
      end

      def directory(path)
        return unless path

        value = File.dirname(path)
        value == "." ? "." : value
      end

      def read(path)
        @content_cache[path] ||= @source_reader.read_utf8(path)
      end

      # File lists may still carry raw non-UTF-8 filename bytes (git output);
      # scrub at this boundary so tr/downcase/regex never raise downstream.
      def normalize(path)
        utf8 = path.to_s.b.force_encoding(Encoding::UTF_8).scrub
        Pathname.new(utf8.tr("\\", "/")).cleanpath.to_s.sub(%r{\A\./}, "")
      end
    end
  end
end
