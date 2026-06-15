module Hive
  module Pr
    module_function

    def number(url)
      match = url.to_s.strip.match(%r{(?:\A|/)pull/(\d+)/?(?:[?#].*)?\z})
      match ? "##{match[1]}" : nil
    end
  end
end
