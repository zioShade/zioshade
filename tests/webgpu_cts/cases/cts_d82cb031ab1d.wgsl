

@compute @workgroup_size(1)
fn f() {
  const c = 1;
  _ = c;
}
