
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffle(vec2(0.0, 0.0), 0);
}
