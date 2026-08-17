
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffle(vec4(0, 0, 0, 0), 0);
}
