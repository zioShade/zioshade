
struct pos_struct {
  @builtin(position) pos : vec4f
}

struct no_pos_struct {
  @location(0) x : vec4f
}

@vertex
fn main() -> @builtin(position) vec4f {
  return vec4f();
}
