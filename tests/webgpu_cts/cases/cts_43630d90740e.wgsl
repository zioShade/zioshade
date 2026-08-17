
enable subgroups;
fn foo() {
  _ = subgroupShuffleXor(0, 0);
}


@fragment
fn main() {
  foo();
}
