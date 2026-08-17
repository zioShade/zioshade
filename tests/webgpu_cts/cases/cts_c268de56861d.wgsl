
enable subgroups;
fn foo() {
  _ = subgroupXor(0);
}


@fragment
fn main() {
  foo();
}
