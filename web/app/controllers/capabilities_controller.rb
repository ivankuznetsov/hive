class CapabilitiesController < ApplicationController
  include CapabilityInputs

  def show
    project = find_project!(params.require(:project))
    render partial: "status/composer_capabilities", locals: capability_form(project)
  end
end
