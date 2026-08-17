
enable subgroups;
fn foo() {
  _ = subgroupMax(0);
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
