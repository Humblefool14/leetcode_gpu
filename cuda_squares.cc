#include <stdio.h>
#include <cuda_runtime.h>
#define N 100

__global__ void squares(int *a, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;  // global thread index
    if (i < n)                                      // guard against extra threads
        a[i] = i * i;
}

int main() {
    int h_a[N];                 // host (CPU) array
    int *d_a;                   // device (GPU) pointer

    cudaMalloc(&d_a, N * sizeof(int));              // 1. allocate on device

    int threads = 32;
    int blocks  = (N + threads - 1) / threads;      // 4 blocks → 128 threads
    squares<<<blocks, threads>>>(d_a, N);           // 2. launch, pass pointer

    cudaMemcpy(h_a, d_a, N * sizeof(int),
               cudaMemcpyDeviceToHost);             // 3. copy results back
                                                    //    (this also waits for the kernel)
    cudaError_t e = cudaGetLastError();
    if (e != cudaSuccess) printf("CUDA error: %s\n", cudaGetErrorString(e));

    for (int i = 0; i < N; i++)
        printf("a[%d] = %d\n", i, h_a[i]);          // printed in order, on the host

    cudaFree(d_a);                                  // 4. free device memory
    return 0;
}
