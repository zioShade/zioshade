
@group(1u) @binding(1)
var<storage> a: i32;

@workgroup_size(1, 1, 1)
@compute fn main() {
  _ = a;
}
