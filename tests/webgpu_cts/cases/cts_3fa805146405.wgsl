
enable subgroups;
fn foo() {
  _ = subgroupElect();
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
