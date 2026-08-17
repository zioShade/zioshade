var<private> x: i32;
@compute @workgroup_size(1)
fn main() {
  let p: ptr<private,i32> = &x; *p = 42;
}
