
fn a_func() -> i32 {
    return 4;
}

const a_const = -2 + 10;
override a_override: i32 = 2;

@id(2) override my_id: i32 = 4;

struct B {
    a: i32,
}

@binding(0) @group(0)
var<uniform> uniform_buffer_1: B;

@binding(1) @group(1)
var<uniform> uniform_buffer_2: B;

@fragment
fn main() -> @location(0) vec4<f32> {
  return vec4<f32>(.4, .2, .3, .1);
}

@compute
@workgroup_size(32, 32, 32)
fn compute_main() {}
