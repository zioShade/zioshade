
enable subgroups;
fn foo() {
  _ = subgroupMax(0);
}


@fragment
fn main() {
  foo();
}
