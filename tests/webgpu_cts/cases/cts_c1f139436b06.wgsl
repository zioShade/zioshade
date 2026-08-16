
@fragment
fn main() {
  foo();
}

var<workgroup> wgvar : u32;

fn bar() -> u32 {
  return 0;
}

fn foo() {
  _ = bar();
}
