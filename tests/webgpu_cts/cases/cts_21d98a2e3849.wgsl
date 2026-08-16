
      

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat4x4(0f, 1f, 2f, 3f, 4f, 5f, 6f, 7f, 8f, 9f, 10f, 11f, 12f, 13f, 14f, 15f));
      }
