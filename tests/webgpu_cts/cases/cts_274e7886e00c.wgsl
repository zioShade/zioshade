
enable subgroups;
fn foo() {
  _ = subgroupBroadcastFirst(0);
}


@fragment
fn main() {
  foo();
}
