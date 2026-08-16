
const c = 1;
@compute @workgroup_size(1)
fn f() {
  
  _ = c;
}
