
enable subgroups;
fn foo() {
  _ = subgroupMin(0);
}


@fragment
fn main() {
  foo();
}
