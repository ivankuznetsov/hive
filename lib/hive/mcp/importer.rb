require "hive/config"
require "hive/mcp/discovery"

module Hive
  module Mcp
    # Turns discovered servers into import rows against the global catalog
    # and writes the selected ones (plan 2026-10-15-001, U5).
    #
    # Row statuses: `new` (not in the catalog), `imported` (in the catalog
    # and unchanged at its source), `drift` (the source changed: URL, argv
    # or env names), `catalog-only` (imported earlier, now gone from its
    # source), `conflict` (agents disagree on one name; pick one variant by
    # id), `refused` (cannot be represented without a literal secret or an
    # unsupported feature).
    module Importer
      Row = Data.define(
        :id, :name, :status, :sources, :spec, :logins, :exports, :refusal, :logins_changed
      ) do
        def transport = spec && (spec.key?("url") ? "http" : "stdio")

        def auth
          return unless spec
          return "env:#{spec['bearer_token_env']}" if spec["bearer_token_env"]
          return "oauth" if spec.key?("oauth_logins")
          return "env:#{spec['headers_env'].values.join(',')}" if spec["headers_env"]

          "none"
        end

        def importable? = %w[new drift conflict imported].include?(status)

        def to_h
          {
            "id" => id, "name" => name, "status" => status, "sources" => sources,
            "transport" => transport, "auth" => auth, "logins" => logins,
            "exports" => exports.map { |export| export.fetch("var") }, "refusal" => refusal
          }
        end
      end

      IGNORED_FOR_DRIFT = %w[imported_from oauth_logins enabled].freeze

      module_function

      def plan(result, catalog)
        rows = []
        result.candidates.group_by(&:name).each do |name, candidates|
          candidates.select(&:refusal).each do |candidate|
            rows << row("#{name}@#{candidate.agent}", name, "refused", [ candidate.agent ], nil, [],
                        [], candidate.refusal)
          end
          variants = candidates.reject(&:refusal).group_by(&:spec).values
          variants.each do |group|
            sources = group.map(&:agent)
            spec = catalog_spec(group)
            id = variants.one? ? name : "#{name}@#{sources.join('+')}"
            status = if variants.size > 1 then "conflict"
            elsif !catalog.key?(name) then "new"
            elsif comparable(catalog.fetch(name)) == comparable(spec) then "imported"
            else "drift"
            end
            rows << row(id, name, status, sources, spec, Array(spec["oauth_logins"]),
                        group.flat_map(&:exports).uniq, nil,
                        status == "imported" && Array(catalog.dig(name, "oauth_logins")).sort != Array(spec["oauth_logins"]).sort)
          end
        end
        discovered = result.candidates.map(&:name)
        catalog.each do |name, spec|
          next unless spec["imported_from"] && !discovered.include?(name)

          rows << row(name, name, "catalog-only", [ spec["imported_from"] ], nil, [], [], nil)
        end
        rows.sort_by { |item| [ item.name, item.id ] }
      end

      def catalog_spec(group)
        spec = group.first.spec.merge("imported_from" => group.first.agent)
        return spec unless group.any?(&:oauth)

        spec.merge("oauth_logins" => group.select(&:logged_in).map(&:agent).uniq)
      end

      # The rows a non-interactive selection names. `all` takes every new
      # row (and, with `update`, drift); `only` takes rows by id or name.
      def select(rows, all: false, only: nil, update: false)
        return rows.select { |item| item.status == "new" || (update && item.status == "drift") || item.logins_changed } if all

        wanted = Array(only)
        unknown = wanted.reject { |key| rows.any? { |item| item.id == key || item.name == key } }
        raise Hive::UsageError, "hive mcp import: no discovered server named #{unknown.join(', ')}" unless unknown.empty?

        picked = rows.select { |item| wanted.include?(item.id) || wanted.include?(item.name) }
        picked.each { |item| validate_pick!(item, update) }
        picked
      end

      def validate_pick!(item, update)
        message = case item.status
        when "refused" then "#{item.id} cannot be imported: #{item.refusal}"
        when "catalog-only" then "#{item.id} no longer exists at its source; edit or remove it in the global config"
        when "drift" then "#{item.id} changed at its source; pass --update to replace the catalog entry" unless update
        end
        raise Hive::UsageError, "hive mcp import: #{message}" if message
      end

      # Write `rows` into the global catalog under its lock, keeping every
      # other key. Returns the names written.
      def apply!(rows)
        names = rows.map(&:name)
        duplicates = names.select { |name| names.count(name) > 1 }.uniq
        raise Hive::UsageError, "hive mcp import: pick one variant of #{duplicates.join(', ')}" unless duplicates.empty?
        return [] if rows.empty?

        Hive::Config.update_global_config! do |data|
          block = data["mcp"] ||= {}
          raise Hive::ConfigError, "mcp in #{Hive::Config.global_config_path} must be a Hash" unless block.is_a?(Hash)

          servers = block["servers"] ||= {}
          rows.each { |item| servers[item.name] = Hive::Config.deep_dup(item.spec) }
          Hive::Config.validate_global_mcp!(
            { "mcp" => { "inherit_user" => false }.merge(block) }, Hive::Config.global_config_path
          )
        end
        names
      end

      # Record one more agent holding a saved login for `name`.
      def record_login!(name, agent)
        Hive::Config.update_global_config! do |data|
          spec = data.dig("mcp", "servers", name)
          raise Hive::ConfigError, "MCP server #{name} is not in the global catalog" unless spec.is_a?(Hash)

          spec["oauth_logins"] = (Array(spec["oauth_logins"]) + [ agent.to_s ]).uniq
        end
      end

      def mark_offered!
        Hive::Config.update_global_config! do |data|
          block = data["mcp"] ||= {}
          block["import_offered"] = true if block.is_a?(Hash)
        end
      end

      def comparable(spec) = spec.except(*IGNORED_FOR_DRIFT)

      def row(id, name, status, sources, spec, logins, exports, refusal, logins_changed = false)
        Row.new(id: id, name: name, status: status, sources: sources, spec: spec, logins: logins,
                exports: exports, refusal: refusal, logins_changed: logins_changed)
      end
      private_class_method :catalog_spec, :validate_pick!, :comparable, :row
    end
  end
end
