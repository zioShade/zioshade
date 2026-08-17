
struct S {
      @location(11) x : f32,
      @builtin(frag_depth) d : f32,
      @location(10) y : f32,
    }

@fragment
fn main() -> S {
  return S();
}
