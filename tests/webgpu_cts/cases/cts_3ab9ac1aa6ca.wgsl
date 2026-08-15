

      @compute @workgroup_size(1)
      fn main() {
      }
    
@group(0) @binding(0) var s: sampler;
@group(0) @binding(1) var t: texture_2d<f32>;

fn foo() {
  _ = textureSampleBias(t, s, vec2(0.0f, 0.0f), 0);
}
