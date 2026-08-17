@group(0) @binding(0) var<storage> x: i32;
@compute @workgroup_size(1)
fn main() {
  let copy = x;
}
