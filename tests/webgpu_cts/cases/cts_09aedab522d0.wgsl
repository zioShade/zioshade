
enable subgroups;
enable f16;
@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffleXor(vec2(0.0h, 0.0h), 0);
}
