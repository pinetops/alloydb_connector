defmodule AlloydbConnectorTest do
  use ExUnit.Case
  doctest AlloydbConnector

  test "greets the world" do
    assert AlloydbConnector.hello() == :world
  end
end
