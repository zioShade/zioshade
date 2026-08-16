
struct S {
  ary: array<i32>,
}

@group(0) @binding(0) var<storage, read_write> items: S;

@compute @workgroup_size(1)
fn main() {
  _ = arrayLength(&items.ary);
}
