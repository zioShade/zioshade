
@compute @workgroup_size(1)
fn main() {
  foo();
}
fn bar() {}

fn foo() {
  workgroupBarrier();
}
