
enable subgroups;
fn foo() {
  _ = subgroupAny(true);
}


@fragment
fn main() {
  foo();
}
