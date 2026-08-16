
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec4<u32> = subgroupBallot(true);
}
