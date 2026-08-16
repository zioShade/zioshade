

      @fragment
      fn main() {
        foo();
      }
    
@group(0) @binding(0) var s: sampler_comparison;
@group(0) @binding(1) var t: texture_depth_cube_array;

fn foo() {
  _ = textureSampleCompare(t, s, vec3(0.0f, 0.0f, 0.0f), 0, 0);
}
