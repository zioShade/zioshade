
override over: i32 = 4;
const z: i32 = 4;

struct S {
  @size(z) a: f32,
};
@group(0) @binding(0)
var<storage> a: S;

@workgroup_size(1)
@compute fn main() {
  _ = a;
}
