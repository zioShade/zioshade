
@fragment
fn main() {
  foo();
}
fn bar(f : f32) -> f32 { return f; }

fn foo() {
  _ = dpdx(1.0);
}
