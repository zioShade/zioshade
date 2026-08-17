
enable subgroups;
fn foo() {
  _ = subgroupShuffleUp(0, 0);
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
