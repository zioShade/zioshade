
enable subgroups;
fn foo() {
  _ = subgroupElect();
}


@fragment
fn main() {
  foo();
}
