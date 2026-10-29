"""
Skinny GEMM (x @ W.T) for Muse Spark Open dense projections on one H200.

Design
- Every scored shape is memory-bound or close to it (m <= 256), so the goal is
  streaming W from HBM at full bandwidth with enough CTAs in flight.
- One Triton kernel covers every layer:
    * m == 1      : CUDA-core GEMV path (2D fp32 accumulator, reduced once at the end)
    * m >= 8      : tensor-core path (tl.dot), BLOCK_M padded to >= 16
    * split-K     : partial sums go to an fp32 workspace; the last CTA to finish
                    a tile (atomic ticket counter) reduces them and writes the output,
                    so split-K costs ONE launch, not kernel + reduce + cast.
    * router FP32 : W fp32 is split in-register into three bf16 terms
                    (hi + mid + lo == W to ~24 mantissa bits). x is bf16 and therefore
                    exact, so three bf16 MMAs with fp32 accumulate reproduce a true
                    fp32 GEMM without reading anything beyond the fp32 weights once.
- prepare() (untimed) autotunes per scored (layer, m): for each candidate config it
  checks correctness against torch, then times the real dispatch path (incl. Python
  launch overhead), and also times plain torch/cuBLAS. The fastest correct choice wins,
  so a bad Triton config can never be selected over cuBLAS.
- The unpooler with n=1024 (m <= 8) uses rows W[:n] of the given [8192, 4096] weight.
"""
import os
import torch
import triton
import triton.language as tl

SCORED_M = (1, 8, 16, 32, 128, 256)
_INTERPRET = os.environ.get("TRITON_INTERPRET", "0") == "1"
LAYERS = ("qkv_gate", "o", "pooler", "unpooler", "router")


@triton.jit
def _skinny_gemm(
    x_ptr, w_ptr, out_ptr, ws_ptr, cnt_ptr,
    M, N, K, SPLIT_K,
    stride_xm, stride_wn, stride_om,
    BLOCK_M: tl.constexpr, BLOCK_N: tl.constexpr, BLOCK_K: tl.constexpr,
    W_FP32: tl.constexpr, OUT_FP32: tl.constexpr, DOT_F32: tl.constexpr,
):
    pid_n = tl.program_id(0)
    pid_k = tl.program_id(1)
    pid_m = tl.program_id(2)

    k_len = K // SPLIT_K
    k_begin = pid_k * k_len
    offs_n = pid_n * BLOCK_N + tl.arange(0, BLOCK_N)
    offs_k = tl.arange(0, BLOCK_K)
    w_ptrs = w_ptr + offs_n[:, None] * stride_wn + (k_begin + offs_k)[None, :]

    if BLOCK_M == 1:
        # GEMV: elementwise FMA into a 2D accumulator, one reduction at the end.
        offs_m = pid_m + tl.arange(0, 1)
        x_ptrs = x_ptr + pid_m * stride_xm + k_begin + offs_k
        acc2 = tl.zeros((BLOCK_N, BLOCK_K), dtype=tl.float32)
        for _ in range(0, k_len, BLOCK_K):
            w = tl.load(w_ptrs).to(tl.float32)
            xv = tl.load(x_ptrs).to(tl.float32)
            acc2 += w * xv[None, :]
            w_ptrs += BLOCK_K
            x_ptrs += BLOCK_K
        acc = tl.reshape(tl.sum(acc2, axis=1), (1, BLOCK_N))
    else:
        offs_m = pid_m * BLOCK_M + tl.arange(0, BLOCK_M)
        m_mask_ld = offs_m < M
        x_ptrs = x_ptr + offs_m[:, None] * stride_xm + (k_begin + offs_k)[None, :]
        acc = tl.zeros((BLOCK_M, BLOCK_N), dtype=tl.float32)
        for _ in range(0, k_len, BLOCK_K):
            a = tl.load(x_ptrs, mask=m_mask_ld[:, None], other=0.0)
            b = tl.load(w_ptrs)
            if W_FP32:
                hi = b.to(tl.bfloat16)
                r1 = b - hi.to(tl.float32)
                mid = r1.to(tl.bfloat16)
                lo = (r1 - mid.to(tl.float32)).to(tl.bfloat16)
                if DOT_F32:  # CPU-interpreter testing only (its bf16 dot is broken)
                    a = a.to(tl.float32)
                    hi = hi.to(tl.float32)
                    mid = mid.to(tl.float32)
                    lo = lo.to(tl.float32)
                acc = tl.dot(a, tl.trans(hi), acc)
                acc = tl.dot(a, tl.trans(mid), acc)
                acc = tl.dot(a, tl.trans(lo), acc)
            else:
                if DOT_F32:
                    a = a.to(tl.float32)
                    b = b.to(tl.float32)
                acc = tl.dot(a, tl.trans(b), acc)
            w_ptrs += BLOCK_K
            x_ptrs += BLOCK_K

    m_mask = offs_m < M
    o_ptrs = out_ptr + offs_m[:, None] * stride_om + offs_n[None, :]
    if SPLIT_K == 1:
        if OUT_FP32:
            tl.store(o_ptrs, acc, mask=m_mask[:, None])
        else:
            tl.store(o_ptrs, acc.to(tl.bfloat16), mask=m_mask[:, None])
    else:
        MN = M * N
        p_off = offs_m[:, None] * N + offs_n[None, :]
        tl.store(ws_ptr + pid_k * MN + p_off, acc, mask=m_mask[:, None])
        tl.debug_barrier()  # all threads' partial stores precede the release below
        tile = pid_m * tl.num_programs(0) + pid_n
        ticket = tl.atomic_add(cnt_ptr + tile, 1, sem="acq_rel", scope="gpu")
        if ticket == SPLIT_K - 1:
            tot = tl.zeros((BLOCK_M, BLOCK_N), dtype=tl.float32)
            for s in range(0, SPLIT_K):
                tot += tl.load(ws_ptr + s * MN + p_off, mask=m_mask[:, None],
                               other=0.0, cache_modifier=".cg")
            if OUT_FP32:
                tl.store(o_ptrs, tot, mask=m_mask[:, None])
            else:
                tl.store(o_ptrs, tot.to(tl.bfloat16), mask=m_mask[:, None])
            tl.atomic_xchg(cnt_ptr + tile, 0)  # re-arm for the next call


# --------------------------------------------------------------------------- launch

class _Ctx:
    def __init__(self, device):
        self.device = device
        self.cnt = torch.zeros(1 << 16, dtype=torch.int32, device=device)
        self.ws = torch.empty(0, dtype=torch.float32, device=device)

    def workspace(self, numel):
        if self.ws.numel() < numel:
            self.ws = torch.empty(numel, dtype=torch.float32, device=self.device)
        return self.ws


def _launch(ctx, x, w, out, cfg):
    bm, bn, bk, split, warps, stages = cfg
    m, k = x.shape
    n = out.shape[1]
    ws = ctx.workspace(split * m * n if split > 1 else 1)
    grid = (n // bn, split, triton.cdiv(m, bm))
    _skinny_gemm[grid](
        x, w, out, ws, ctx.cnt, m, n, k, split,
        x.stride(0), w.stride(0), out.stride(0),
        BLOCK_M=bm, BLOCK_N=bn, BLOCK_K=bk,
        W_FP32=(w.dtype == torch.float32), OUT_FP32=(out.dtype == torch.float32),
        DOT_F32=_INTERPRET,
        num_warps=warps, num_stages=stages,
    )
    return out


def _torch_ref(x, w):
    if w.dtype == torch.float32:
        return x.float() @ w.t()
    return x @ w.t()


def _valid(cfg, m, n, k):
    bm, bn, bk, split, _, _ = cfg
    if n % bn or k % split:
        return False
    kl = k // split
    if kl % bk or kl < bk:
        return False
    if triton.cdiv(m, bm) * (n // bn) > (1 << 16):
        return False
    return True


def _splits_for(tiles, k, bk, target=(132, 264, 528)):
    """split-K factors that bring the CTA count to roughly 1, 2 and 4 waves."""
    out = {1}
    for t in target:
        s = 1
        while tiles * s < t and s < 32 and (k // (s * 2)) >= bk and k % (s * 2) == 0:
            s *= 2
        out.add(s)
    return sorted(out)


def _candidates(m, n, k, fp32):
    cands = []
    if m == 1:
        for bn, bk in ((8, 512), (16, 256), (16, 512), (32, 256), (64, 128)):
            for warps in (4, 8):
                for s in _splits_for(n // bn, k, bk):
                    cands.append((1, bn, bk, s, warps, 3))
    elif m <= 32:
        bm = 16 if m <= 16 else 32
        bks = (64, 128) if fp32 else (128, 256)
        for bn in (32, 64, 128):
            for bk in bks:
                tiles = triton.cdiv(m, bm) * (n // bn)
                for s in _splits_for(tiles, k, bk):
                    cands.append((bm, bn, bk, s, 4, 4 if bk <= 128 else 3))
    else:
        for bm, bn in ((64, 64), (64, 128), (128, 64), (128, 128)):
            bk = 32 if fp32 else 64
            tiles = triton.cdiv(m, bm) * (n // bn)
            for s in _splits_for(tiles, k, bk, target=(132, 264)):
                for warps in (4, 8):
                    cands.append((bm, bn, bk, s, warps, 4))
    return [c for c in dict.fromkeys(cands) if _valid(c, m, n, k)]


def _close(out, ref, fp32):
    err = (out.float() - ref.float()).abs().max().item()
    scale = ref.float().abs().max().item() + 1e-6
    return err <= (1e-4 if fp32 else 1.5e-2) * scale


def _time(fn, iters=50, warmup=5):
    for _ in range(warmup):
        fn()
    torch.cuda.synchronize()
    best = float("inf")
    for _ in range(3):
        s, e = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
        s.record()
        for _ in range(iters):
            fn()
        e.record()
        torch.cuda.synchronize()
        best = min(best, s.elapsed_time(e) / iters)
    return best * 1e3  # us


def _out_n(layer, m, w):
    if layer == "unpooler" and m <= 8:
        return 1024
    return w.shape[0]


def prepare(weights):
    dev = weights["qkv_gate"].device
    ctx = _Ctx(dev)
    W = {name: weights[name].contiguous() for name in LAYERS}
    plan = {}
    verbose = os.environ.get("SKINNY_VERBOSE", "0") == "1"
    torch.manual_seed(0)
    for layer in LAYERS:
        for m in SCORED_M:
            w_full = W[layer]
            n = _out_n(layer, m, w_full)
            w = w_full[:n]
            k = w.shape[1]
            fp32 = w.dtype == torch.float32
            x = torch.randn(m, k, device=dev, dtype=torch.bfloat16)
            ref = _torch_ref(x, w)
            out = torch.empty(m, n, device=dev, dtype=torch.float32 if fp32 else torch.bfloat16)

            best_cfg, best_t = None, _time(lambda: _torch_ref(x, w))
            t_torch = best_t
            for cfg in _candidates(m, n, k, fp32):
                try:
                    out.fill_(float("nan"))
                    _launch(ctx, x, w, out, cfg)
                    torch.cuda.synchronize()
                    if not _close(out, ref, fp32):
                        continue
                    t = _time(lambda: _launch(ctx, x, w, out, cfg))
                    # re-check after repeated runs (counter re-arm path)
                    if not _close(out, ref, fp32):
                        continue
                except Exception:
                    continue
                if t < best_t:
                    best_cfg, best_t = cfg, t
            plan[(layer, m)] = best_cfg
            if verbose:
                print(f"{layer:9s} m={m:3d} n={n:5d} k={k:5d}  torch {t_torch:7.2f}us  "
                      f"best {best_t:7.2f}us  cfg={best_cfg}")
    return {"W": W, "plan": plan, "ctx": ctx}


def kernel_fn(data, state):
    x = data["x"]
    cfg_ = data["config"]
    layer, m, n = cfg_["layer"], cfg_["m"], cfg_["n"]
    w = state["W"][layer]
    if n != w.shape[0]:
        w = w[:n]
    cfg = state["plan"].get((layer, m))
    if cfg is None or x.shape[0] != m:
        return _torch_ref(x, w)
    if not x.is_contiguous():
        x = x.contiguous()
    out = torch.empty(m, n, device=x.device,
                      dtype=torch.float32 if w.dtype == torch.float32 else torch.bfloat16)
    return _launch(state["ctx"], x, w, out, cfg)
