
enable subgroups;
fn foo() {
  _ = subgroupBallot(true);
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
