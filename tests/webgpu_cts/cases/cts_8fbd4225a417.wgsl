
enable subgroups;
fn foo() {
  _ = subgroupOr(0);
}


@fragment
fn main() {
  foo();
}
