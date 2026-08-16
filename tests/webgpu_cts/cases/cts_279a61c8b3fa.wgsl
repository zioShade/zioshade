
struct S {
      @location(2) x : f32,
      @location(1) y : f32,
      @location(0) z : f32,
    }

@fragment
fn main() -> S {
  return S();
}
