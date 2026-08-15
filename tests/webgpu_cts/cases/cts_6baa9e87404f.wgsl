
enable subgroups;
fn foo() {
  _ = subgroupAll(true);
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
