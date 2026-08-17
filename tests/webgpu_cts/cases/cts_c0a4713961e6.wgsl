

@compute @workgroup_size(1)
fn f() {
  let v = 1;
  _ = v;
}
