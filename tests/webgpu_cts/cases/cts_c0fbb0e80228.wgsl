
enable subgroups;
fn foo() {
  _ = subgroupBroadcast(0, 0);
}


@fragment
fn main() {
  foo();
}
