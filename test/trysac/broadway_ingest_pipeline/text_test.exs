defmodule Trysac.BroadwayIngestPipeline.TextTest do
  use ExUnit.Case, async: true

  alias Trysac.BroadwayIngestPipeline.BlankInputError
  alias Trysac.BroadwayIngestPipeline.Text

  doctest Text

  describe "normalize/1" do
    test "trims surrounding whitespace and lower-cases the text" do
      assert Text.normalize("  Hello World ") == "hello world"
    end

    test "keeps inner whitespace" do
      assert Text.normalize("\tA  B\n") == "a  b"
    end

    test "lower-cases only ASCII letters" do
      assert Text.normalize("ÉCOLE") == "École"
    end

    test "raises BlankInputError on blank input" do
      assert_raise BlankInputError, "input is blank", fn -> Text.normalize("   ") end
    end

    test "raises BlankInputError on empty input" do
      assert_raise BlankInputError, "input is blank", fn -> Text.normalize("") end
    end
  end

  test "exposes a semantic version" do
    assert Trysac.BroadwayIngestPipeline.version() =~ ~r/\A\d+\.\d+\.\d+\z/
  end
end
