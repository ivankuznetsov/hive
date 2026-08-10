require "digest"
require "pathname"
require "psych"
require "uri"
require "hive/cron_schedule"
require "hive/module_package/command_target"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/diagnostic"
require "hive/workflow_package/manifest"
require "hive/workflow_package/registry_manifest"

module Hive
  module ModulePackage
    class Manifest
      FILE_NAME = "module.yml".freeze
      ALTERNATE_FILE_NAME = "manifest.yml".freeze
      SCHEMA = "hive-module/v1".freeze
      NAME = /\A[a-z0-9][a-z0-9-]{0,62}\z/
      SEMVER = Hive::WorkflowPackage::RegistryManifest::SEMVER
      REVISION = Hive::WorkflowPackage::RegistryManifest::REVISION
      SHA256 = Hive::WorkflowPackage::Manifest::SHA256
      EVENT_NAMES = %w[project.registered pull_request.merged task.completed].freeze
      TYPES = %w[workflow patrol architecture-patrol].freeze
      CONCURRENCY = %w[allow drop replace].freeze
      TARGET_KINDS = %w[workflow entrypoint command].freeze
      SETTING_TYPES = %w[boolean enum integer number secret string].freeze
      TOP_LEVEL_KEYS = %w[
        schema name version description type author license hive_min_version source
        workflows hooks settings permissions templates docs files release_sha256
      ].freeze
      AUTHOR_KEYS = %w[name url].freeze
      SOURCE_KEYS = %w[url revision].freeze
      WORKFLOW_KEYS = %w[id descriptor].freeze
      HOOK_KEYS = %w[id target default_enabled schedules events concurrency].freeze
      TARGET_KEYS = %w[kind id].freeze
      SETTING_KEYS = %w[name type required default values secret description].freeze
      PERMISSION_KEYS = %w[
        repository_write github_mutations external_commands network_hosts
        filesystem_read filesystem_write secrets
      ].freeze

      attr_reader :data, :bytes, :digest, :file_name

      def self.load(path)
        bytes = File.binread(path)
        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        fail!("manifest.invalid_yaml", File.basename(path), "module manifest is not valid UTF-8 YAML") unless utf8.valid_encoding?
        data = Psych.safe_load(utf8, permitted_classes: [], permitted_symbols: [], aliases: false)
        validate_shape!(data, file_name: File.basename(path))
        canonical = Hive::WorkflowPackage::CanonicalYAML.dump(data)
        fail!("manifest.non_canonical", File.basename(path), "module manifest must use canonical YAML") unless bytes == canonical
        expected = ::Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalYAML.dump(data.reject { |key, _value| key == "release_sha256" })
        )
        unless secure_equal?(data.fetch("release_sha256"), expected)
          fail!("manifest.release_digest_mismatch", File.basename(path), "release_sha256 does not match canonical module content")
        end
        new(data, bytes, File.basename(path))
      rescue Psych::Exception, EncodingError
        fail!("manifest.invalid_yaml", File.basename(path), "module manifest is not safe canonical UTF-8 YAML")
      rescue Errno::ENOENT, Errno::EACCES, IOError
        fail!("manifest.unreadable", File.basename(path), "module manifest is missing or unreadable")
      end

      def self.validate_shape!(data, file_name: FILE_NAME)
        fail!("manifest.invalid_type", file_name, "module manifest root must be a map") unless data.is_a?(Hash)
        unless data.keys.all? { |key| key.is_a?(String) } && data.keys.sort == TOP_LEVEL_KEYS.sort
          fail!("manifest.invalid_shape", file_name, "module manifest has missing or unsupported keys")
        end
        fail!("manifest.unsupported_version", file_name, "unsupported module manifest schema; upgrade Hive") unless data["schema"] == SCHEMA
        fail!("manifest.invalid_name", file_name, "module name is malformed") unless data["name"].is_a?(String) && NAME.match?(data["name"])
        fail!("manifest.invalid_version", file_name, "module version is malformed") unless data["version"].is_a?(String) && SEMVER.match?(data["version"])
        required_string!(data["description"], "description", file_name)
        fail!("manifest.invalid_type", file_name, "module type is unsupported") unless TYPES.include?(data["type"])
        validate_author!(data["author"], file_name)
        required_string!(data["license"], "license", file_name)
        fail!("manifest.invalid_version", file_name, "hive_min_version is malformed") unless data["hive_min_version"].is_a?(String) && SEMVER.match?(data["hive_min_version"])
        validate_source!(data["source"], file_name)
        validate_workflows!(data["workflows"], file_name)
        validate_hooks!(data["hooks"], file_name)
        validate_settings!(data["settings"], file_name)
        validate_permissions!(data["permissions"], file_name)
        validate_target_contracts!(data, file_name)
        validate_path_set!(data["templates"], "templates", file_name)
        validate_path_set!(data["docs"], "docs", file_name)
        validate_files!(data["files"], file_name)
        fail!("manifest.invalid_hash", file_name, "release_sha256 is malformed") unless SHA256.match?(data["release_sha256"].to_s)
        referenced = data["templates"] + data["docs"] + data["workflows"].map { |item| item.fetch("descriptor") }
        missing = referenced.uniq - data["files"].keys
        fail!("manifest.missing_file", missing.first, "manifest reference is absent from the file inventory") if missing.any?
        data
      end

      def self.validate_author!(author, file_name)
        unless author.is_a?(Hash) && author.keys.sort == AUTHOR_KEYS.sort
          fail!("manifest.invalid_author", file_name, "author must contain only name and url")
        end
        required_string!(author["name"], "author.name", file_name)
        validate_url!(author["url"], "author.url", file_name)
      end

      def self.validate_source!(source, file_name)
        unless source.is_a?(Hash) && source.keys.sort == SOURCE_KEYS.sort
          fail!("manifest.invalid_source", file_name, "source must contain only url and revision")
        end
        validate_url!(source["url"], "source.url", file_name)
        unless source["revision"].is_a?(String) && REVISION.match?(source["revision"])
          fail!("manifest.invalid_source", file_name, "source revision must be a full immutable SHA")
        end
      end

      def self.validate_workflows!(workflows, file_name)
        fail!("manifest.invalid_workflows", file_name, "workflows must be an array") unless workflows.is_a?(Array)
        ids = workflows.map do |workflow|
          unless workflow.is_a?(Hash) && workflow.keys.sort == WORKFLOW_KEYS.sort
            fail!("manifest.invalid_workflow", file_name, "workflow entries must contain only id and descriptor")
          end
          validate_slug!(workflow["id"], "workflow id", file_name)
          validate_relative_path!(workflow["descriptor"], file_name)
          workflow["id"]
        end
        fail!("manifest.duplicate_workflow", file_name, "workflow ids must be unique") unless ids.uniq == ids
      end

      def self.validate_hooks!(hooks, file_name)
        fail!("manifest.invalid_hooks", file_name, "hooks must be an array") unless hooks.is_a?(Array)
        ids = hooks.map do |hook|
          unless hook.is_a?(Hash) && hook.keys.sort == HOOK_KEYS.sort
            fail!("manifest.invalid_hook", file_name, "hook entries have missing or unsupported keys")
          end
          validate_slug!(hook["id"], "hook id", file_name)
          validate_target!(hook["target"], file_name)
          fail!("manifest.invalid_hook", file_name, "default_enabled must be boolean") unless [ true, false ].include?(hook["default_enabled"])
          unless hook["schedules"].is_a?(Array) && hook["schedules"].all? { |value| valid_schedule?(value) } && hook["schedules"].uniq == hook["schedules"]
            fail!("manifest.invalid_schedule", file_name, "hook schedules must be unique five-field cron expressions")
          end
          unless hook["events"].is_a?(Array) && (hook["events"] - EVENT_NAMES).empty? && hook["events"].uniq == hook["events"]
            fail!("manifest.invalid_event", file_name, "hook events must use the supported named vocabulary")
          end
          fail!("manifest.invalid_hook", file_name, "hook concurrency is unsupported") unless CONCURRENCY.include?(hook["concurrency"])
          hook["id"]
        end
        fail!("manifest.duplicate_hook", file_name, "hook ids must be unique") unless ids.uniq == ids
      end

      def self.validate_target!(target, file_name)
        unless target.is_a?(Hash) && target.keys.sort == TARGET_KEYS.sort && TARGET_KINDS.include?(target["kind"])
          fail!("manifest.invalid_target", file_name, "hook target is malformed")
        end
        required_string!(target["id"], "hook target id", file_name)
        if target["kind"] != "command" && !/\A[a-z0-9][a-z0-9.-]*\z/.match?(target["id"])
          fail!("manifest.invalid_target", file_name, "registered hook target id is malformed")
        end
      end

      def self.validate_target_contracts!(data, file_name)
        workflow_ids = data.fetch("workflows").map { |workflow| workflow.fetch("id") }
        commands = data.dig("permissions", "external_commands")
        data.fetch("hooks").each do |hook|
          target = hook.fetch("target")
          case target.fetch("kind")
          when "workflow"
            unless workflow_ids.include?(target.fetch("id"))
              fail!("manifest.invalid_target", file_name, "workflow hook target is not declared by this module")
            end
          when "command"
            argv = begin
              CommandTarget.argv(target.fetch("id"))
            rescue Hive::ConfigError
              fail!("manifest.invalid_target", file_name, "command hook target is malformed")
            end
            unless commands.include?(argv.first)
              fail!(
                "manifest.permission_mismatch", file_name,
                "command hook executable is absent from reviewed external command permissions"
              )
            end
          end
        end
      end

      def self.validate_settings!(settings, file_name)
        fail!("manifest.invalid_settings", file_name, "settings must be an array") unless settings.is_a?(Array)
        names = settings.map do |setting|
          unless setting.is_a?(Hash) && (setting.keys - SETTING_KEYS).empty? && %w[name type required].all? { |key| setting.key?(key) }
            fail!("manifest.invalid_setting", file_name, "setting entries have missing or unsupported keys")
          end
          validate_slug!(setting["name"], "setting name", file_name, dots: true)
          fail!("manifest.invalid_setting", file_name, "setting type is unsupported") unless SETTING_TYPES.include?(setting["type"])
          fail!("manifest.invalid_setting", file_name, "setting required must be boolean") unless [ true, false ].include?(setting["required"])
          if setting.key?("secret") && ![ true, false ].include?(setting["secret"])
            fail!("manifest.invalid_setting", file_name, "setting secret must be boolean")
          end
          if setting["type"] == "enum"
            values = setting["values"]
            unless values.is_a?(Array) && !values.empty? && values.all? { |value| value.is_a?(String) && !value.empty? } && values.uniq == values
              fail!("manifest.invalid_setting", file_name, "enum settings require unique values")
            end
            if setting.key?("default") && !values.include?(setting["default"])
              fail!("manifest.invalid_setting", file_name, "enum default must be one of its values")
            end
          elsif setting.key?("values")
            fail!("manifest.invalid_setting", file_name, "only enum settings may declare values")
          end
          setting["name"]
        end
        fail!("manifest.duplicate_setting", file_name, "setting names must be unique") unless names.uniq == names
      end

      def self.validate_permissions!(permissions, file_name)
        unless permissions.is_a?(Hash) && permissions.keys.sort == PERMISSION_KEYS.sort
          fail!("manifest.invalid_permissions", file_name, "permissions disclosure is malformed")
        end
        unless [ true, false ].include?(permissions["repository_write"])
          fail!("manifest.invalid_permissions", file_name, "repository_write must be boolean")
        end
        PERMISSION_KEYS.grep_v("repository_write").each do |key|
          validate_string_set!(permissions[key], "permissions.#{key}", file_name)
        end
      end

      def self.validate_files!(files, file_name)
        unless files.is_a?(Hash) && files.keys.all? { |path| path.is_a?(String) } && files.keys == files.keys.sort
          fail!("manifest.invalid_files", file_name, "files must be a sorted map")
        end
        files.each do |path, digest|
          validate_relative_path!(path, file_name)
          if [ FILE_NAME, ALTERNATE_FILE_NAME ].include?(path)
            fail!("manifest.self_hash", path, "module manifest must not appear in its own inventory")
          end
          fail!("package.executable_ruby", path, "module packages may not contain executable Ruby") if File.extname(path) == ".rb"
          fail!("manifest.invalid_hash", path, "file sha256 is malformed") unless SHA256.match?(digest.to_s)
        end
        fail!("manifest.path_case_collision", file_name, "file paths collide by case") unless files.keys.map(&:downcase).uniq.length == files.length
      end

      def self.validate_path_set!(value, label, file_name)
        unless value.is_a?(Array) && value.uniq == value
          fail!("manifest.invalid_value", file_name, "#{label} must be a unique path array")
        end
        value.each { |path| validate_relative_path!(path, file_name) }
      end

      def self.validate_string_set!(value, label, file_name)
        unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) && !entry.empty? } && value.uniq == value
          fail!("manifest.invalid_permissions", file_name, "#{label} must be a set of non-empty strings")
        end
        if value.include?("*") && value.length > 1
          fail!("manifest.invalid_permissions", file_name, "#{label} wildcard must be the only value")
        end
      end

      def self.validate_relative_path!(value, file_name)
        invalid = !value.is_a?(String) || value.empty? || value.include?("\\") || value.include?("\0") ||
          Pathname.new(value.to_s).absolute? || value.to_s.split("/").any? { |part| part.empty? || %w[. ..].include?(part) }
        fail!("package.path_escape", value.to_s, "package path must remain inside the module") if invalid
      end

      def self.validate_url!(value, label, file_name)
        uri = URI.parse(value.to_s)
        valid = %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? && uri.userinfo.nil? && uri.fragment.nil?
        fail!("manifest.invalid_url", file_name, "#{label} must be an absolute HTTP(S) URL") unless valid
      rescue URI::InvalidURIError
        fail!("manifest.invalid_url", file_name, "#{label} must be an absolute HTTP(S) URL")
      end

      def self.validate_slug!(value, label, file_name, dots: false)
        pattern = dots ? /\A[a-z0-9][a-z0-9._-]*\z/ : NAME
        fail!("manifest.invalid_value", file_name, "#{label} is malformed") unless value.is_a?(String) && pattern.match?(value)
      end

      def self.valid_schedule?(value)
        value.is_a?(String) && value.bytesize <= 128 && !value.include?("\0") &&
          Hive::CronSchedule.valid?(value)
      end

      def self.required_string!(value, label, file_name)
        fail!("manifest.invalid_value", file_name, "#{label} must be a non-empty string") unless value.is_a?(String) && !value.strip.empty? && value.valid_encoding?
      end

      def self.secure_equal?(left, right)
        left.is_a?(String) && left.bytesize == right.bytesize &&
          left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end

      def self.fail!(rule, path, message)
        raise Hive::WorkflowPackage::PackageError,
              Hive::WorkflowPackage::Diagnostic.new(rule_id: rule, severity: :error, path: path, message: message)
      end

      def initialize(data, bytes, file_name)
        @data = deep_freeze(data)
        @bytes = bytes.freeze
        @digest = data.fetch("release_sha256").freeze
        @file_name = file_name.freeze
        freeze
      end

      def name = data.fetch("name")
      def version = data.fetch("version")
      def type = data.fetch("type")
      def summary = data.fetch("description")
      def workflows = data.fetch("workflows")
      def hooks = data.fetch("hooks")
      def settings = data.fetch("settings")
      def permissions = data.fetch("permissions")
      def event_names = hooks.flat_map { |hook| hook.fetch("events") }.uniq.sort.freeze
      def file_entries = data.fetch("files").map { |path, sha256| { "path" => path, "sha256" => sha256 } }

      private

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, child| key.freeze; deep_freeze(child) }.freeze
        when Array then value.each { |child| deep_freeze(child) }.freeze
        else value.freeze
        end
      end
    end
  end
end
