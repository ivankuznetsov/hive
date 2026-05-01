require "test_helper"

class SampleTest < Minitest::Test
  def test_calculator_arithmetic
    calculator = Sample::Calculator.new

    assert_equal 5, calculator.add(2, 3)
    assert_equal(-1, calculator.subtract(2, 3))
    assert_equal 6, calculator.multiply(2, 3)
  end
end
