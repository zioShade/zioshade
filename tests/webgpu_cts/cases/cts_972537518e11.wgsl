
@compute @workgroup_size(1)
fn main() {
}

fn bar(f : f32) -> f32 { return f; }

fn foo() {
  _ = dpdxFine(1.0);
}
