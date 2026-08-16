
struct S {
      @location(13) x : f32,
      @location(7) y : f32,
      @location(2) z : f32,
    }

@fragment
fn main() -> S {
  return S();
}
