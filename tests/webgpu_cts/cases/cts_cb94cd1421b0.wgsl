@group(0) @binding(0) var<storage,read_write> x: i32;
@compute @workgroup_size(1)
fn main() {
  let p: ptr<storage,i32,read_write> = &x; let read = *p;
}
