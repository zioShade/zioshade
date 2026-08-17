
enable subgroups;
fn foo() {
  _ = subgroupBallot(true);
}


@fragment
fn main() {
  foo();
}
