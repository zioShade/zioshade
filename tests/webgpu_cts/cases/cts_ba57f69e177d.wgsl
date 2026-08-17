
enable subgroups;
fn foo() {
  _ = subgroupXor(0);
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
