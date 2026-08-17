
enable subgroups;
fn foo() {
  _ = subgroupBroadcast(0, 0);
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
