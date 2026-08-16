
enable subgroups;
fn foo() {
  _ = subgroupBroadcastFirst(0);
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
