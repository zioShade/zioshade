

      @compute @workgroup_size(1)
      fn main() {
      }
    
@group(0) @binding(0) var s: sampler;
@group(0) @binding(1) var t: texture_3d<f32>;

fn foo() {
  _ = textureSampleBias(t, s, vec3(0.0f, 0.0f, 0.0f), 0, vec3(i32(0), i32(0), i32(0)));
}
