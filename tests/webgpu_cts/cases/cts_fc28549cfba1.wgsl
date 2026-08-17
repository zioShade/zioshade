
      

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat3x3(0f, 1f, 2f, 3f, 4f, 5f, 6f, 7f, 8f));
      }
