module Hive
  # Pass numbering is a filename presentation detail, not a fix budget.
  # Callers retain their own artifact-prefix and pass-admission checks.
  module ReviewPass
    SUFFIX = /-(\d{2,})\.md\z/
    BUDGET_RECEIPT = /\Areview-(?:grant-[a-f0-9]{64}|completion-[a-f0-9]{64}-\d{2,})\.json\z/

    module_function

    def number(path)
      File.basename(path.to_s).match(SUFFIX)&.[](1)&.to_i
    end

    def prefix(path)
      File.basename(path.to_s).match(SUFFIX)&.pre_match
    end

    def sort_key(path)
      [ number(path) || 0, File.basename(path.to_s) ]
    end

    def budget_receipt?(path)
      File.basename(path.to_s).match?(BUDGET_RECEIPT)
    end
  end
end
