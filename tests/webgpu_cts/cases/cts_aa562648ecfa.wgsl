
enable subgroups;
fn foo() {
  _ = subgroupAnd(0);
}


@fragment
fn main() {
  foo();
}
