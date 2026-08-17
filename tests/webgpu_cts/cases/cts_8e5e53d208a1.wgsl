
enable subgroups;
fn foo() {
  _ = quadBroadcast(0, 0);
}


@fragment
fn main() {
  foo();
}
