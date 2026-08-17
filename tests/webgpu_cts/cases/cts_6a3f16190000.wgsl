

      @fragment
      fn main() {
        foo();
      }
    
@group(0) @binding(0) var s: sampler;
@group(0) @binding(1) var t: texture_depth_2d;

fn foo() {
  _ = textureSample(t, s, vec2(0.0f, 0.0f));
}
