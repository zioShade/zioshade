
fn callee() -> i32 { return 0; }
@compute @workgroup_size(1)
fn f() {
  
  _ = callee();
}
