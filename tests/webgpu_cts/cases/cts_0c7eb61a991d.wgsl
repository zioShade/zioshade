

      @compute @workgroup_size(1)
      fn main() {
      }
    
@group(0) @binding(0) var s: sampler;
@group(0) @binding(1) var t: texture_cube_array<f32>;

fn foo() {
  _ = textureSampleBias(t, s, vec3(0.0f, 0.0f, 0.0f), 0, 0);
}
