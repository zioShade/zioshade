
@group(0) @binding(0) var x: texture_2d<f32>;
@compute @workgroup_size(1)
fn f() {
  
  _ = x;
}
