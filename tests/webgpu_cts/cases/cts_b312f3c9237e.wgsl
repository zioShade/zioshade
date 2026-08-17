
@compute @workgroup_size(1)
fn main() {
  foo();
}
fn bar(f : f32) -> f32 { return f; }

fn foo() {
  _ = bar(1.0);
}
