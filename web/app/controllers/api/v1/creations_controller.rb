# frozen_string_literal: true

module Api
  module V1
    class CreationsController < MutationsController
      def create
        project = authorized_project!("create")
        input = mutation_input!(allowed: %w[text slug body workflow depends_on base], required: [ "text" ], string_list_fields: [ "depends_on" ])
        # Dependency resolution is a domain read; authorize its explicit project
        # before New can look up the target or its dependency graph.
        Array(input["depends_on"]).each do |reference|
          authority.project!(reference.strip.split(":", 2).first) if reference.include?(":")
        end
        existing = existing_operation(project)
        result = command_service.create(project: project, **command_authority,
          **input.slice("text", "slug", "body", "workflow", "depends_on", "base").transform_keys(&:to_sym))
        render_acknowledgement(result, status: existing ? 200 : 201)
      end
    end
  end
end
