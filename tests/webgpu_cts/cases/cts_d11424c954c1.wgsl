
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupMin(vec2(0.0f, 0.0f));
}
