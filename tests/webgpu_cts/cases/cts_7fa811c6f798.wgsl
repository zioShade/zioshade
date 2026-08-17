var<workgroup> x: i32;
@compute @workgroup_size(1)
fn main() {
  let p = &x; *p = 42;
}
