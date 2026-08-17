
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupBroadcast(vec4(0.0f, 0.0f, 0.0f, 0.0f), 0);
}
