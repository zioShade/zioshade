
@fragment
fn main() {
  foo();
}
fn bar(f : f32) -> f32 { return f; }

fn foo() {
  _ = dpdxCoarse(1.0);
}
