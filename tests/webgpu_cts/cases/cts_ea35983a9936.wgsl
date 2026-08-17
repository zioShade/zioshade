
var<workgroup> x: u32;
@compute @workgroup_size(1)
fn f() {
  
  _ = x;
}
