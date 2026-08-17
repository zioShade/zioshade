
@compute @workgroup_size(1)
fn main1() {
  foo();
}

@fragment
fn main2() {
  foo();
}

fn bar() {}

fn foo() {
  bar();
}
