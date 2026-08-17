
struct S {
      @location(16) x : f32,
      @location(4) y : f32,
    }
    struct T {
      @location(13) x : f32,
      @location(7) y : f32,
    }

@fragment
fn main(p1 : S, p2 : T)  {
  
}
