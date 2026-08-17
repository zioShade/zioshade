
struct S {
      @location(12) x : f32,
      @builtin(position) pos : vec4f,
      @location(0) y : f32,
    }

@fragment
fn main(p : S)  {
  
}
