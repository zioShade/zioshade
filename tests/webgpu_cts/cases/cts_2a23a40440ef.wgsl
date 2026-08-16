
@group(0) @binding(0) var<storage> x: array<u32,1>;
@compute @workgroup_size(1)
fn f() {
  
  _ = x;
}
