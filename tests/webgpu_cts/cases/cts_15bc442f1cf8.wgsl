

      @fragment
      fn main() {
        foo();
      }
    
@group(0) @binding(0) var s: sampler;
@group(0) @binding(1) var t: texture_2d<f32>;

fn foo() {
  _ = textureSample(t, s, vec2(0.0f, 0.0f), vec2(i32(0), i32(0)));
}
