
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffle(vec2(0u, 0u), 0);
}
