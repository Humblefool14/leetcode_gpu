// k-means (Lloyd's algorithm) in CUDA
// Build: nvcc -O3 -arch=native kmeans.cu -o kmeans
// Run:   ./kmeans [N] [D] [K] [max_iter]
//
// Layout: points stored column-major (D x N, X[d*N + i]) so consecutive threads
// read consecutive addresses -> coalesced loads. Centroids are row-major (K x D).

#include <cstdio>
#include <cstdlib>
#include <cfloat>
#include <vector>
#include <random>
#include <numeric>
#include <algorithm>
#include <cuda_runtime.h>

#define CUDA_CHECK(x) do { cudaError_t e = (x); if (e != cudaSuccess) {            \
    fprintf(stderr, "CUDA error: %s at %s:%d\n", cudaGetErrorString(e),             \
            __FILE__, __LINE__); exit(1); } } while (0)

static constexpr int    BLOCK      = 256;
static constexpr size_t SMEM_LIMIT = 48 * 1024;  // default dynamic smem limit

// ---------------------------------------------------------------------------
// 1) Assignment: each thread takes one point, finds its nearest centroid.
//    Centroids are staged in shared memory when they fit.
// ---------------------------------------------------------------------------
template <bool USE_SMEM>
__global__ void assign_kernel(const float* __restrict__ X,
                              const float* __restrict__ C,
                              int* __restrict__ labels,
                              int* __restrict__ changed,
                              int N, int D, int K)
{
    extern __shared__ float sC[];
    const float* cent = C;
    if (USE_SMEM) {
        for (int j = threadIdx.x; j < K * D; j += blockDim.x) sC[j] = C[j];
        __syncthreads();
        cent = sC;
    }

    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= N) return;

    float best  = FLT_MAX;
    int   bestk = 0;
    for (int k = 0; k < K; ++k) {
        float dist = 0.f;
        for (int d = 0; d < D; ++d) {
            float diff = X[(size_t)d * N + i] - cent[k * D + d];
            dist = fmaf(diff, diff, dist);
        }
        if (dist < best) { best = dist; bestk = k; }
    }

    int flag = (labels[i] != bestk);
    if (flag) labels[i] = bestk;

    // Warp-aggregated count of changed labels: one atomic per warp, not per thread
    unsigned active = __activemask();
    unsigned votes  = __ballot_sync(active, flag);
    int lane   = threadIdx.x & 31;
    int leader = __ffs(active) - 1;
    if (lane == leader && votes) atomicAdd(changed, __popc(votes));
}

// ---------------------------------------------------------------------------
// 2) Accumulate per-cluster sums and counts.
//    Privatized into shared memory per block (when it fits) to cut global
//    atomic contention, then flushed once per block. Grid-stride loop so each
//    block covers many points before flushing.
// ---------------------------------------------------------------------------
template <bool USE_SMEM>
__global__ void accumulate_kernel(const float* __restrict__ X,
                                  const int* __restrict__ labels,
                                  float* __restrict__ sums,
                                  int* __restrict__ counts,
                                  int N, int D, int K)
{
    extern __shared__ float smem[];
    float* sSum = smem;
    int*   sCnt = reinterpret_cast<int*>(smem + K * D);

    if (USE_SMEM) {
        for (int j = threadIdx.x; j < K * D; j += blockDim.x) sSum[j] = 0.f;
        for (int j = threadIdx.x; j < K;     j += blockDim.x) sCnt[j] = 0;
        __syncthreads();
    }

    float* dstS = USE_SMEM ? sSum : sums;
    int*   dstC = USE_SMEM ? sCnt : counts;

    for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < N;
         i += gridDim.x * blockDim.x) {
        int k = labels[i];
        atomicAdd(&dstC[k], 1);
        for (int d = 0; d < D; ++d)
            atomicAdd(&dstS[k * D + d], X[(size_t)d * N + i]);
    }

    if (USE_SMEM) {
        __syncthreads();
        for (int j = threadIdx.x; j < K * D; j += blockDim.x)
            if (sSum[j] != 0.f) atomicAdd(&sums[j], sSum[j]);
        for (int j = threadIdx.x; j < K; j += blockDim.x)
            if (sCnt[j]) atomicAdd(&counts[j], sCnt[j]);
    }
}

// ---------------------------------------------------------------------------
// 3) Update: centroid = sum / count. Empty clusters keep their old centroid.
// ---------------------------------------------------------------------------
__global__ void update_kernel(float* __restrict__ C,
                              const float* __restrict__ sums,
                              const int* __restrict__ counts,
                              int K, int D)
{
    int j = blockIdx.x * blockDim.x + threadIdx.x;
    if (j >= K * D) return;
    int c = counts[j / D];
    if (c > 0) C[j] = sums[j] / (float)c;
}

int main(int argc, char** argv)
{
    int N        = argc > 1 ? atoi(argv[1]) : (1 << 20);
    int D        = argc > 2 ? atoi(argv[2]) : 16;
    int K        = argc > 3 ? atoi(argv[3]) : 16;
    int max_iter = argc > 4 ? atoi(argv[4]) : 100;
    if (K > N) { fprintf(stderr, "K must be <= N\n"); return 1; }

    // ---- Synthetic data: K Gaussian blobs, stored column-major ----
    std::mt19937 rng(42);
    std::normal_distribution<float>       noise(0.f, 1.f);
    std::uniform_real_distribution<float> ctr(-50.f, 50.f);

    std::vector<float> trueC((size_t)K * D);
    for (auto& v : trueC) v = ctr(rng);

    std::vector<float> hX((size_t)D * N);
    for (int i = 0; i < N; ++i) {
        int k = i % K;
        for (int d = 0; d < D; ++d)
            hX[(size_t)d * N + i] = trueC[(size_t)k * D + d] + noise(rng);
    }

    // ---- Forgy init: K distinct random points as starting centroids ----
    std::vector<int> perm(N);
    std::iota(perm.begin(), perm.end(), 0);
    std::shuffle(perm.begin(), perm.end(), rng);
    std::vector<float> hC((size_t)K * D);
    for (int k = 0; k < K; ++k)
        for (int d = 0; d < D; ++d)
            hC[(size_t)k * D + d] = hX[(size_t)d * N + perm[k]];

    // ---- Device buffers ----
    float *dX, *dC, *dSums;
    int   *dLabels, *dCounts, *dChanged;
    CUDA_CHECK(cudaMalloc(&dX,       sizeof(float) * (size_t)D * N));
    CUDA_CHECK(cudaMalloc(&dC,       sizeof(float) * (size_t)K * D));
    CUDA_CHECK(cudaMalloc(&dSums,    sizeof(float) * (size_t)K * D));
    CUDA_CHECK(cudaMalloc(&dLabels,  sizeof(int)   * (size_t)N));
    CUDA_CHECK(cudaMalloc(&dCounts,  sizeof(int)   * (size_t)K));
    CUDA_CHECK(cudaMalloc(&dChanged, sizeof(int)));

    CUDA_CHECK(cudaMemcpy(dX, hX.data(), sizeof(float) * hX.size(), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(dC, hC.data(), sizeof(float) * hC.size(), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemset(dLabels, 0xFF, sizeof(int) * (size_t)N));  // -1 = unassigned

    int numSMs;
    CUDA_CHECK(cudaDeviceGetAttribute(&numSMs, cudaDevAttrMultiProcessorCount, 0));

    size_t smemAssign = sizeof(float) * (size_t)K * D;
    size_t smemAcc    = sizeof(float) * (size_t)K * D + sizeof(int) * (size_t)K;
    bool   assignSmem = smemAssign <= SMEM_LIMIT;
    bool   accSmem    = smemAcc    <= SMEM_LIMIT;

    int gridAssign = (N + BLOCK - 1) / BLOCK;
    int gridAcc    = std::min(gridAssign, numSMs * 8);
    int gridUpdate = (K * D + BLOCK - 1) / BLOCK;

    cudaEvent_t t0, t1;
    CUDA_CHECK(cudaEventCreate(&t0));
    CUDA_CHECK(cudaEventCreate(&t1));
    CUDA_CHECK(cudaEventRecord(t0));

    int iter = 0, changed = N;
    for (; iter < max_iter; ++iter) {
        CUDA_CHECK(cudaMemset(dChanged, 0, sizeof(int)));
        if (assignSmem)
            assign_kernel<true><<<gridAssign, BLOCK, smemAssign>>>(dX, dC, dLabels, dChanged, N, D, K);
        else
            assign_kernel<false><<<gridAssign, BLOCK>>>(dX, dC, dLabels, dChanged, N, D, K);
        CUDA_CHECK(cudaGetLastError());

        CUDA_CHECK(cudaMemcpy(&changed, dChanged, sizeof(int), cudaMemcpyDeviceToHost));
        if (changed == 0) break;  // converged: no point switched cluster

        CUDA_CHECK(cudaMemset(dSums,   0, sizeof(float) * (size_t)K * D));
        CUDA_CHECK(cudaMemset(dCounts, 0, sizeof(int)   * (size_t)K));
        if (accSmem)
            accumulate_kernel<true><<<gridAcc, BLOCK, smemAcc>>>(dX, dLabels, dSums, dCounts, N, D, K);
        else
            accumulate_kernel<false><<<gridAcc, BLOCK>>>(dX, dLabels, dSums, dCounts, N, D, K);
        CUDA_CHECK(cudaGetLastError());

        update_kernel<<<gridUpdate, BLOCK>>>(dC, dSums, dCounts, K, D);
        CUDA_CHECK(cudaGetLastError());
    }

    CUDA_CHECK(cudaEventRecord(t1));
    CUDA_CHECK(cudaEventSynchronize(t1));
    float ms;
    CUDA_CHECK(cudaEventElapsedTime(&ms, t0, t1));

    CUDA_CHECK(cudaMemcpy(hC.data(), dC, sizeof(float) * hC.size(), cudaMemcpyDeviceToHost));

    printf("N=%d D=%d K=%d | %s after %d iterations | %.2f ms (%.3f ms/iter)\n",
           N, D, K, changed == 0 ? "converged" : "hit max_iter",
           iter, ms, ms / std::max(iter, 1));
    printf("smem: assign=%s accumulate=%s\n",
           assignSmem ? "yes" : "no", accSmem ? "yes" : "no");
    for (int k = 0; k < std::min(K, 4); ++k) {
        printf("centroid %d:", k);
        for (int d = 0; d < std::min(D, 4); ++d) printf(" %8.3f", hC[(size_t)k * D + d]);
        printf("%s\n", D > 4 ? " ..." : "");
    }

    cudaFree(dX); cudaFree(dC); cudaFree(dSums);
    cudaFree(dLabels); cudaFree(dCounts); cudaFree(dChanged);
    return 0;
}
