
enable f16;
@group(0) @binding(0) var t : texture_2d<f32>;
@group(0) @binding(1) var s : sampler;
@group(0) @binding(2) var<storage, read_write> a : atomic<i32>;

struct S { u : u32 }

var<private> arr : array<u32, 4>;
var<private> str : S;

@compute @workgroup_size(1)
fn main() {
  let foo = mat2x3h() - mat2x3(0, 0, 0, 0, 0, 0);
}
