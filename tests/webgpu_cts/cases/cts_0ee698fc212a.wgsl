
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffleDown(vec2(0.0, 0.0), 0);
}
