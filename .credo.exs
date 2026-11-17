# Factory-owned file: agents must not edit it. Credo (the lint gate) in strict mode: every default check plus the
# ones below, at every priority; any issue fails. Inline `# credo:disable` comments are refused by scripts/check.exs.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true,
      color: false,
      checks: %{
        extra: [
          {Credo.Check.Readability.MaxLineLength, [max_length: 120]},
          # Every public function states its types; Dialyzer (the types gate) checks them.
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Consistency.UnusedVariableNames, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.NegatedIsNil, []}
        ]
      }
    }
  ]
}
