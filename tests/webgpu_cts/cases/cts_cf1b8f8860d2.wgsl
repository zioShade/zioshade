
enable subgroups;
fn foo() {
  _ = subgroupAll(true);
}


@fragment
fn main() {
  foo();
}
