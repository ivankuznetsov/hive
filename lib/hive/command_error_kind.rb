# frozen_string_literal: true

module Hive
  module CommandErrorKind
    module_function

    def typed(error)
      return error.reason if error.is_a?(Hive::CommandOutcomeError)
      return error.reason if error.is_a?(Hive::CommandCapacityError)

      nil
    end
  end
end
