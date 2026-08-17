
@group(0) @binding(0) var x: sampler_comparison;
@compute @workgroup_size(1)
fn f() {
  
  _ = x;
}
