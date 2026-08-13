require "digest"
require "json"
require "hive/dependencies"
require "hive/dependency_snapshot"
require "hive/secret_patterns"
require "hive/task_workspace"

module Hive
  module TaskWorkspace
    # A bounded connected component derived entirely from an already-built
    # DependencyAdmission::Context. It performs no directory walk, Git fetch,
    # or remote call. Scheduling edges and stacked-Git evidence remain distinct.
    class DependencyComponent
      def initialize(context:, project:, slug:, git_observations: {},
                     git_observation_reader: nil, limits: Limits.new,
                     monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @context = context
        @project = project.to_s
        @slug = slug.to_s
        @git_observations = stringify_keys(git_observations)
        @git_observation_reader = git_observation_reader
        @node_sources = {}
        @limits = limits
        @monotonic_clock = monotonic_clock
        @started_at = @monotonic_clock.call
        @deadline = @started_at + @limits.fetch(:dependency_deadline_seconds)
      end

      def call
        diagnostics = []
        truncated = false
        inventory = inventory(diagnostics)
        truncated ||= inventory.fetch(:truncated)
        nodes_by_id = inventory.fetch(:nodes)
        target_id = qualify(@project, @slug)
        unless nodes_by_id.key?(target_id)
          placeholder = missing_node(target_id, reason: "target_missing")
          return panel(
            state: "partial", nodes: [ placeholder ], edges: [],
            diagnostics: diagnostics + [ diagnostic("target_missing", target_id) ],
            truncated: truncated,
            fingerprint: Hive::DependencySnapshot.semantic_fingerprint(@context),
            root_id: target_id
          )
        end

        edges, placeholders, edge_diagnostics = build_edges(nodes_by_id)
        diagnostics.concat(edge_diagnostics)
        truncated ||= edge_diagnostics.any? do |row|
          row["cap"] == "dependency_deadline_seconds"
        end
        nodes_by_id = nodes_by_id.merge(placeholders)
        selection = connected_selection(target_id, nodes_by_id, edges, diagnostics)
        truncated ||= selection.fetch(:truncated)
        selected_nodes = selection.fetch(:node_ids).filter_map { |id| nodes_by_id[id] }
        selected_edges = selection.fetch(:edges)
        selected_nodes.each do |node|
          break if deadline_exhausted!(diagnostics)

          project_stack!(node, diagnostics)
          if deadline_exhausted!(diagnostics)
            truncated = true
            break
          end
        end
        selected_edges.each do |edge|
          source = selected_nodes.find { |node| node["id"] == edge["from"] }
          edge["stack_divergence"] = source.dig("stack", "divergence") if
            edge["relationship"] == "stacked" && source
        end
        mark_cycles!(selected_edges)
        selected_nodes << truncation_node(diagnostics) if truncated
        selected_nodes.sort_by! { |node| [ node["kind"] == "sentinel" ? 1 : 0, node["id"] ] }
        selected_edges.sort_by! { |edge| [ edge["from"], edge["to"], edge["id"] ] }

        state = diagnostics.empty? && !truncated ? "current" : "partial"
        panel(
          state: state, nodes: selected_nodes, edges: selected_edges,
          diagnostics: diagnostics, truncated: truncated,
          fingerprint: Hive::DependencySnapshot.semantic_fingerprint(@context),
          root_id: target_id
        )
      rescue StandardError => e
        {
          "state" => "unavailable", "records" => [], "edges" => [],
          "forest" => { "roots" => [], "node_order" => [], "tree_edges" => [],
                        "cross_references" => [] },
          "diagnostics" => [
            { "source" => "dependency_snapshot", "reason" => "component_failed",
              "detail" => e.class.name }
          ],
          "truncated" => false
        }
      end

      private

      def inventory(diagnostics)
        snapshots = @context.project_snapshot_layers.each_with_index.flat_map do |projects, layer|
          projects.sort_by { |project| [ project.name.to_s, project.repository_identity.to_s ] }
            .map { |project| [ layer, project ] }
        end
        names = snapshots.map { |_layer, project| project.name }.uniq.sort
        ordered_names = ([ @project ] + names).uniq
        allowed_names = ordered_names.first(@limits.fetch(:dependency_projects))
        truncated = ordered_names.length > allowed_names.length
        if truncated
          diagnostics << cap_diagnostic(
            "dependency_projects", @limits.fetch(:dependency_projects), ordered_names.length
          )
        end

        nodes = {}
        node_layers = {}
        entries = 0
        snapshots.each do |layer, project|
          next unless allowed_names.include?(project.name)
          break if deadline_exhausted!(diagnostics)

          project.tasks.sort_by { |task| [ task.slug.to_s, task.id.to_s ] }.each do |task|
            if deadline_exhausted!(diagnostics)
              truncated = true
              break
            end
            entries += 1
            if entries > @limits.fetch(:dependency_entries)
              diagnostics << cap_diagnostic(
                "dependency_entries", @limits.fetch(:dependency_entries), entries
              )
              truncated = true
              break
            end
            id = qualify(task.project, task.slug)
            if nodes.key?(id)
              diagnostics << diagnostic("duplicate_task", id) if node_layers[id] == layer
              next
            end
            nodes[id] = project_node(task, project)
            @node_sources[id] = [ task, project ]
            node_layers[id] = layer
          end
          break if entries > @limits.fetch(:dependency_entries) ||
                   diagnostics.any? { |row| row["cap"] == "dependency_deadline_seconds" }
        end
        truncated ||= diagnostics.any? { |row| row["cap"] == "dependency_deadline_seconds" }
        { nodes: nodes, truncated: truncated }
      end

      def project_node(task, project)
        id = qualify(task.project, task.slug)
        verdict = @context.verdict(project: task.project, slug: task.slug)
        {
          "id" => id, "kind" => "task", "project" => task.project,
          "slug" => task.slug, "task_id" => task.id, "stage" => task.stage,
          "root" => id == qualify(@project, @slug),
          "depends_on" => task.depends_on,
          "dependency_gate_stage" => project.dependency_gate_stage,
          "admission" => verdict_payload(verdict),
          "evidence_state" => evidence_state(task),
          "stack" => stack_projection(id),
          "reference" => { "project" => task.project, "slug" => task.slug }
        }
      end

      def build_edges(nodes)
        placeholders = {}
        diagnostics = []
        numeric_targets = {}
        nodes.values.each do |node|
          break if deadline_exhausted!(diagnostics)
          next unless node["kind"] == "task" && node["task_id"]

          numeric_targets[[ node["project"], node["task_id"].to_s ]] ||= node
        end
        edges = []
        nodes.values.each do |node|
          break if deadline_exhausted!(diagnostics)

          reference_value = node["depends_on"]
          next if reference_value.nil?

          begin
            reference = Hive::Dependencies.parse_reference(reference_value)
            target_project = reference.explicit_project ? reference.project : node.fetch("project")
            target = resolve_target(nodes, numeric_targets, target_project, reference.task)
            unless target
              target_id = "missing:#{Digest::SHA256.hexdigest("#{target_project}:#{reference.task}")[0, 20]}"
              placeholders[target_id] ||= missing_node(
                target_id, reason: "dependency_task_missing",
                project: target_project, slug: reference.task
              )
              diagnostics << diagnostic("dependency_task_missing", reference.to_s)
              target = placeholders.fetch(target_id)
            end
            edges << edge(node, target, reference)
          rescue Hive::Dependencies::InvalidReference
            target_id = "missing:#{Digest::SHA256.hexdigest(reference_value.to_s)[0, 20]}"
            placeholders[target_id] ||= missing_node(
              target_id, reason: "dependency_reference_invalid", slug: reference_value.to_s
            )
            diagnostics << diagnostic("dependency_reference_invalid", reference_value.to_s)
            edges << edge(
              node, placeholders.fetch(target_id), nil, invalid_reference: reference_value.to_s
            )
          end
        end
        [ edges, placeholders, diagnostics ]
      end

      def resolve_target(nodes, numeric_targets, project, reference)
        if reference.to_s.match?(/\A\d+\z/)
          numeric_targets[[ project, reference.to_s ]]
        else
          nodes[qualify(project, reference)]
        end
      end

      def edge(source, target, reference, invalid_reference: nil)
        relationship = source["project"] == target["project"] ? "stacked" : "scheduling"
        error = source.dig("admission", "error")
        state = if error
          "error"
        elsif source.dig("admission", "state") == "wait"
          "blocking"
        elsif target["kind"] == "missing"
          "missing"
        else
          "clear"
        end
        id = Digest::SHA256.hexdigest(
          [ source["id"], target["id"], reference&.to_s || invalid_reference ].join("\0")
        )[0, 24]
        {
          "id" => id, "from" => source.fetch("id"), "to" => target.fetch("id"),
          "direction" => "depends_on", "relationship" => relationship,
          "reference" => reference&.to_s || invalid_reference,
          "state" => state, "cycle" => false,
          "blocked_by" => source.dig("admission", "blocked_by"),
          "dependency_stage" => source.dig("admission", "dependency_stage"),
          "stack_divergence" => relationship == "stacked" ?
            source.dig("stack", "divergence") : "not_applicable"
        }
      end

      def mark_cycles!(edges)
        outgoing = edges.group_by { |edge| edge["from"] }
        visited = {}
        edges.map { |edge| edge["from"] }.uniq.sort.each do |node_id|
          next if visited[node_id]

          active = {}
          stack = [ [ node_id, false ] ]
          until stack.empty?
            current, exiting = stack.pop
            if exiting
              active.delete(current)
              next
            end
            next if visited[current]

            visited[current] = true
            active[current] = true
            stack << [ current, true ]
            Array(outgoing[current]).sort_by { |edge| edge["id"] }.reverse_each do |edge|
              target = edge["to"]
              if active[target]
                edge["cycle"] = true
                edge["state"] = "cyclic"
              elsif !visited[target]
                stack << [ target, false ]
              end
            end
          end
        end
      end

      def connected_selection(root_id, nodes, edges, diagnostics)
        adjacency = Hash.new { |hash, key| hash[key] = [] }
        edges.each do |edge|
          adjacency[edge["from"]] << edge
          adjacency[edge["to"]] << edge
        end
        selected = {}
        selected_edges = {}
        queue = [ [ root_id, 0 ] ]
        truncated = false
        until queue.empty?
          node_id, depth = queue.shift
          next if selected.key?(node_id)
          if selected.length >= @limits.fetch(:dependency_nodes)
            diagnostics << cap_diagnostic(
              "dependency_nodes", @limits.fetch(:dependency_nodes), selected.length + queue.length + 1
            )
            truncated = true
            break
          end
          selected[node_id] = true
          if depth >= @limits.fetch(:dependency_depth) && adjacency[node_id].any?
            diagnostics << cap_diagnostic(
              "dependency_depth", @limits.fetch(:dependency_depth), depth + 1
            )
            truncated = true
            next
          end
          adjacency[node_id].sort_by { |edge| [ edge["from"], edge["to"], edge["id"] ] }.each do |edge|
            if selected_edges.length >= @limits.fetch(:dependency_edges)
              diagnostics << cap_diagnostic(
                "dependency_edges", @limits.fetch(:dependency_edges), selected_edges.length + 1
              )
              truncated = true
              break
            end
            selected_edges[edge["id"]] = edge
            other = edge["from"] == node_id ? edge["to"] : edge["from"]
            queue << [ other, depth + 1 ] unless selected.key?(other)
          end
          if deadline_exhausted!(diagnostics)
            truncated = true
            break
          end
        end
        {
          node_ids: selected.keys, edges: selected_edges.values,
          truncated: truncated
        }
      end

      def panel(state:, nodes:, edges:, diagnostics:, truncated:, fingerprint: nil,
                root_id: nil)
        nodes, edges, byte_truncated, observed_bytes = enforce_bytes(nodes, edges)
        if byte_truncated
          truncated = true
          state = "partial"
          diagnostics << cap_diagnostic(
            "dependency_bytes", @limits.fetch(:dependency_bytes), observed_bytes
          )
        end
        {
          "state" => state, "records" => nodes, "edges" => edges,
          "forest" => forest(root_id, nodes, edges),
          "root_id" => root_id, "fingerprint" => fingerprint,
          "diagnostics" => diagnostics.uniq,
          "truncated" => truncated, "observed_bytes" => observed_bytes
        }
      end

      def forest(root_id, nodes, edges)
        ids = nodes.reject { |node| node["kind"] == "sentinel" }.map { |node| node["id"] }
        return { "roots" => [], "node_order" => [], "tree_edges" => [],
                 "cross_references" => [] } if ids.empty?

        root_id = ids.first unless ids.include?(root_id)
        adjacency = Hash.new { |hash, key| hash[key] = [] }
        edges.each do |edge|
          adjacency[edge["from"]] << edge
          adjacency[edge["to"]] << edge
        end
        seen = { root_id => true }
        order = [ root_id ]
        tree = []
        cross = []
        queue = [ root_id ]
        until queue.empty?
          current = queue.shift
          adjacency[current].sort_by { |edge| [ edge["from"], edge["to"], edge["id"] ] }.each do |edge|
            other = edge["from"] == current ? edge["to"] : edge["from"]
            next unless ids.include?(other)
            if seen[other]
              cross << edge["id"] unless tree.include?(edge["id"]) || cross.include?(edge["id"])
            else
              seen[other] = true
              order << other
              tree << edge["id"]
              queue << other
            end
          end
        end
        {
          "roots" => [ root_id ], "node_order" => order,
          "tree_edges" => tree,
          "cross_references" => cross.map do |edge_id|
            edge = edges.find { |candidate| candidate["id"] == edge_id }
            { "edge_id" => edge_id, "kind" => edge&.fetch("cycle", false) ? "cycle" : "additional" }
          end
        }
      end

      def enforce_bytes(nodes, edges)
        limit = @limits.fetch(:dependency_bytes)
        accepted_nodes = []
        accepted_edges = []
        bytes = 0
        observed_bytes = 0
        truncated = false
        nodes.each do |node|
          size = JSON.generate(node).bytesize
          observed_bytes += size
          if bytes + size > limit
            truncated = true
            break
          end
          accepted_nodes << node
          bytes += size
        end
        accepted_ids = accepted_nodes.to_h { |node| [ node["id"], true ] }
        edges.each do |edge|
          next unless accepted_ids[edge["from"]] && accepted_ids[edge["to"]]
          size = JSON.generate(edge).bytesize
          observed_bytes += size
          if bytes + size > limit
            truncated = true
            break
          end
          accepted_edges << edge
          bytes += size
        end
        if truncated
          sentinel = nodes.find { |node| node["kind"] == "sentinel" } ||
            truncation_node([ { "cap" => "dependency_bytes" } ])
          sentinel_size = JSON.generate(sentinel).bytesize
          while accepted_nodes.any? && bytes + sentinel_size > limit
            removed = accepted_nodes.pop
            removed_size = JSON.generate(removed).bytesize
            bytes -= removed_size
            accepted_ids.delete(removed["id"])
            accepted_edges.reject! do |edge|
              drop = edge["from"] == removed["id"] || edge["to"] == removed["id"]
              bytes -= JSON.generate(edge).bytesize if drop
              drop
            end
          end
          if bytes + sentinel_size <= limit && !accepted_nodes.any? { |node| node["id"] == sentinel["id"] }
            accepted_nodes << sentinel
            bytes += sentinel_size
          end
        end
        [ accepted_nodes, accepted_edges, truncated, [ observed_bytes, bytes ].max ]
      end

      def stack_projection(id)
        value = stringify_keys(@git_observations[id] || {})
        return {
          "state" => "unavailable", "expected_base_branch" => nil,
          "expected_base_oid" => nil, "observed_base_oid" => nil,
          "observed_branch" => nil, "observed_head_oid" => nil,
          "pr_number" => nil, "divergence" => "unavailable"
        } if value.empty?

        expected = oid_or_nil(value["base_oid"])
        observed = oid_or_nil(value["observed_base_oid"])
        divergence = if expected.nil? || observed.nil?
          "partial"
        elsif expected == observed
          "aligned"
        else
          "divergent"
        end
        {
          "state" => divergence == "partial" ? "partial" : "current",
          "repository" => value["repository"],
          "expected_base_branch" => value["base_branch"],
          "expected_base_oid" => expected,
          "observed_base_oid" => observed,
          "observed_branch" => value["current_branch"],
          "observed_head_oid" => oid_or_nil(value["head_oid"]),
          "pr_number" => value["pr_number"], "divergence" => divergence
        }
      end

      def project_stack!(node, diagnostics)
        return unless node["kind"] == "task"
        return unless @git_observation_reader
        return if @git_observations.key?(node.fetch("id"))

        task, project = @node_sources[node.fetch("id")]
        value = if accepts_deadline?(@git_observation_reader)
          @git_observation_reader.call(task, project, deadline: @deadline)
        else
          @git_observation_reader.call(task, project)
        end
        @git_observations[node.fetch("id")] = stringify_keys(value || {})
        node["stack"] = stack_projection(node.fetch("id"))
      rescue StandardError => e
        diagnostics << diagnostic("git_observation_unavailable", "#{node['id']}:#{e.class}")
        node["stack"] = stack_projection(node.fetch("id"))
      end

      def accepts_deadline?(reader)
        reader.parameters.any? do |kind, name|
          kind == :keyrest || %i[key keyreq].include?(kind) && name == :deadline
        end
      end

      def oid_or_nil(value)
        string = value.to_s.downcase
        string.match?(/\A[0-9a-f]{40,64}\z/) ? string : nil
      end

      def verdict_payload(verdict)
        error = verdict.admission_error
        {
          "state" => verdict.state.to_s,
          "blocked_by" => verdict.blocked_by,
          "dependency_stage" => verdict.dependency_stage,
          "error" => error && {
            "reason_code" => error.reason_code,
            "offending_ref" => safe_offending_ref(error.offending_ref)
          }
        }
      end

      def safe_offending_ref(value)
        string = value.to_s
        absolute = string.start_with?("/", "\\") || string.match?(/\A[A-Za-z]:[\\\/]/)
        return "task_evidence:plan.md" if absolute && File.basename(string) == "plan.md"
        return nil if absolute

        Hive::SecretPatterns.redact(string)[0, 512]
      rescue ArgumentError
        nil
      end

      def evidence_state(task)
        return "unavailable" if task.validation_error
        return "partial" unless task.metadata_status == :ok

        "current"
      end

      def missing_node(id, reason:, project: nil, slug: nil)
        {
          "id" => id, "kind" => "missing", "project" => project,
          "slug" => slug, "task_id" => nil, "stage" => nil,
          "root" => false, "depends_on" => nil,
          "dependency_gate_stage" => nil,
          "admission" => { "state" => "error", "blocked_by" => nil,
                           "dependency_stage" => nil,
                           "error" => { "reason_code" => reason } },
          "evidence_state" => "missing",
          "stack" => { "state" => "unavailable", "divergence" => "unavailable" },
          "reference" => project && slug ? { "project" => project, "slug" => slug } : nil
        }
      end

      def truncation_node(diagnostics)
        {
          "id" => "sentinel:truncated", "kind" => "sentinel",
          "project" => nil, "slug" => nil, "task_id" => nil, "stage" => nil,
          "root" => false, "depends_on" => nil, "dependency_gate_stage" => nil,
          "admission" => { "state" => "partial", "blocked_by" => nil,
                           "dependency_stage" => nil, "error" => nil },
          "evidence_state" => "partial",
          "stack" => { "state" => "unavailable", "divergence" => "unavailable" },
          "reference" => nil,
          "reasons" => diagnostics.filter_map { |row| row["cap"] }.uniq.sort
        }
      end

      def deadline_exhausted!(diagnostics)
        observed_at = @monotonic_clock.call
        elapsed = observed_at - @started_at
        return false if observed_at <= @deadline

        diagnostics << cap_diagnostic(
          "dependency_deadline_seconds",
          @limits.fetch(:dependency_deadline_seconds), elapsed.round(6)
        ) unless diagnostics.any? { |row| row["cap"] == "dependency_deadline_seconds" }
        true
      end

      def qualify(project, slug)
        "#{project}:#{slug}"
      end

      def stringify_keys(value)
        value.to_h.each_with_object({}) do |(key, child), result|
          result[key.to_s] = child.is_a?(Hash) ? stringify_keys(child) : child
        end
      end

      def diagnostic(reason, reference)
        { "source" => "dependency_snapshot", "reason" => reason, "reference" => reference }
      end

      def cap_diagnostic(cap, limit, observed)
        {
          "source" => "dependency_snapshot", "reason" => "limit_exhausted",
          "cap" => cap, "limit" => limit, "observed" => observed
        }
      end
    end
  end
end
