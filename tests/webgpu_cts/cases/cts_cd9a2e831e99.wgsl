
struct S {
  @size(64) a: array<f32, 4>,
};
@group(0) @binding(0)
var<storage> a: S;

@workgroup_size(1)
@compute fn main() {
  _ = a.a[0];
}
