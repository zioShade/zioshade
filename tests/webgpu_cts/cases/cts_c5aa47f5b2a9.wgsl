
enable subgroups;
fn foo() {
  _ = subgroupAny(true);
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
