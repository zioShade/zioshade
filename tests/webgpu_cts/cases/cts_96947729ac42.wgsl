
const z = 5;
    const y = 2;
    @group(z + y) @binding(1)
var<storage> a: i32;

@workgroup_size(1, 1, 1)
@compute fn main() {
  _ = a;
}
