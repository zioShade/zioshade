
@vertex
fn main() -> @builtin(position) vec4f {
  foo();
  return vec4f();
}
fn bar(f : f32) -> f32 { return f; }

fn foo() {
  _ = bar(1.0);
}
