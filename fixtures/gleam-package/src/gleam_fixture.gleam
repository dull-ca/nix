import gleam/io
import gleam/list
import gleam/string

/// Printed by the erlang-shipment check, which asserts on this exact line.
/// It goes through stdlib rather than a bare literal so that a shipment which
/// somehow lacks its dependencies fails here rather than passing.
pub fn main() {
  ["gleam", "fixture", "ran"]
  |> list.map(string.uppercase)
  |> string.join("-")
  |> io.println
}
