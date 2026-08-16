
struct pos_struct {
  @builtin(position) pos : vec4f
}

struct no_pos_struct {
  @location(0) x : vec4f
}

@vertex
fn main() -> pos_struct {
  return pos_struct();
}
