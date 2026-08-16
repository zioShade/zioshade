
@vertex
fn main() -> @builtin(position) vec4f {
  foo();
  return vec4f();
}

var<workgroup> wgvar : u32;

fn bar() -> u32 {
  return 0;
}

fn foo() {
  _ = bar();
}
