struct A {
  @invariant @builtin(position)  a : vec4f,
}
@group(0) @binding(0) var<storage> a: A;
@compute @workgroup_size(1) fn main() { let b = a; }
