
@compute @workgroup_size(1)
fn main1() {
  foo();
}

@fragment
fn main2() {
  foo();
}


var<workgroup> wgvar : u32;

fn bar() -> u32 {
  return 0;
}

fn foo() {
  _ = bar();
}
