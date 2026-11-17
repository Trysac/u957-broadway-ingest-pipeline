# Factory-owned file: agents must not edit it. `mix format` (the format gate) reads it; StreamData's `check all`
# and `gen all` keep their own layout.
[
  import_deps: [:stream_data],
  inputs: ["{mix,.formatter,.credo}.exs", "{lib,test,scripts}/**/*.{ex,exs}"],
  line_length: 120
]
