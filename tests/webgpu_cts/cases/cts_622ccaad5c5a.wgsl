

      @compute @workgroup_size(1)
      fn main() {
      }
    
@group(0) @binding(0) var s: sampler_comparison;
@group(0) @binding(1) var t: texture_depth_2d_array;

fn foo() {
  _ = textureSampleCompare(t, s, vec2(0.0f, 0.0f), 0, 0);
}
