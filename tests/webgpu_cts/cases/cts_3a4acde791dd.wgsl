
@group(0) @binding(0) var<uniform> x: u32;
@compute @workgroup_size(1)
fn f() {
  
  _ = x;
}
