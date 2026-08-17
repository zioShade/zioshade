
@vertex
fn main() -> @builtin(position) vec4f {
  foo();
  return vec4f();
}
fn bar() {}

fn foo() {
  bar();
}
