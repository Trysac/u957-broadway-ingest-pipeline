defmodule Trysac.BroadwayIngestPipeline.TextPropertiesTest do
  # Property tests (StreamData): invariants over generated inputs. The seed is ExUnit's, printed by every run, so
  # `mix test --seed <n>` repeats a failing run exactly.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trysac.BroadwayIngestPipeline.Text

  defp input do
    gen all(
          core <- string([?a..?z, ?A..?Z, ?0..?9, ?\s, ?\t, ?-, ?_, ?é, ?Ä], min_length: 1, max_length: 12),
          left <- integer(0..2),
          right <- integer(0..2)
        ) do
      String.duplicate(" ", left) <> "x" <> core <> String.duplicate("\t", right)
    end
  end

  property "is idempotent" do
    check all(value <- input()) do
      once = Text.normalize(value)
      assert Text.normalize(once) == once
    end
  end

  property "leaves no surrounding whitespace" do
    check all(value <- input()) do
      result = Text.normalize(value)
      assert result == String.trim(result)
    end
  end

  property "has no ASCII upper-case letters" do
    check all(value <- input()) do
      refute Text.normalize(value) =~ ~r/[A-Z]/
    end
  end
end
