import gleam/io
import gleam/list
import gleam/string

/// Printed by the javascript-target check, which runs the built module under
/// node and asserts on this exact line.
pub fn main() {
  ["gleam", "js", "fixture", "ran"]
  |> list.map(string.uppercase)
  |> string.join("-")
  |> io.println
}
