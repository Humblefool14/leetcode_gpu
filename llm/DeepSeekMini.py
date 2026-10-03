"""
Minimal, readable DeepSeek-V3-style model in PyTorch:
  - Multi-head Latent Attention (MLA) with decoupled RoPE
  - DeepSeekMoE: shared expert + fine-grained routed experts,
    sigmoid gating, auxiliary-loss-free load balancing (per-expert bias)
  - First few layers use a dense FFN, the rest use MoE

Clarity over speed: experts are dispatched with a Python loop, there is no
KV cache, no multi-token prediction head, no FP8, no expert parallelism.

V3 full config (for reference):
  d_model=7168, n_layers=61, n_dense_layers=3, n_heads=128,
  q_lora_rank=1536, kv_lora_rank=512, qk_nope_dim=128, qk_rope_dim=64,
  v_head_dim=128, n_routed=256, n_shared=1, top_k=8, d_expert=2048,
  d_dense_ffn=18432, vocab=129280, routed_scaling=2.5
"""

from dataclasses import dataclass

import torch
import torch.nn as nn
import torch.nn.functional as F


@dataclass
class Config:
    vocab_size: int = 1000
    d_model: int = 256
    n_layers: int = 4
    n_dense_layers: int = 1
    n_heads: int = 4
    q_lora_rank: int = 128
    kv_lora_rank: int = 64     # this (+ rope dim) is all MLA needs to cache
    qk_nope_dim: int = 32      # per-head dims that don't get RoPE
    qk_rope_dim: int = 16      # per-head dims that do get RoPE
    v_head_dim: int = 32
    d_dense_ffn: int = 512
    n_routed: int = 8
    n_shared: int = 1
    top_k: int = 2
    d_expert: int = 128
    routed_scaling: float = 2.5
    bias_update_rate: float = 1e-3
    max_seq_len: int = 512
    rope_theta: float = 10000.0


# ---------------------------------------------------------------- helpers
class RMSNorm(nn.Module):
    def __init__(self, dim, eps=1e-6):
        super().__init__()
        self.eps = eps
        self.weight = nn.Parameter(torch.ones(dim))

    def forward(self, x):
        return self.weight * x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + self.eps)


def rope_tables(dim, max_len, theta):
    inv_freq = 1.0 / (theta ** (torch.arange(0, dim, 2).float() / dim))
    freqs = torch.outer(torch.arange(max_len).float(), inv_freq)   # (T, dim/2)
    emb = torch.cat([freqs, freqs], dim=-1)                          # (T, dim)
    return emb.cos(), emb.sin()


def apply_rope(x, cos, sin):
    # x: (B, T, H, D); cos/sin: (T, D)
    half = x.shape[-1] // 2
    rotated = torch.cat([-x[..., half:], x[..., :half]], dim=-1)
    return x * cos[None, :, None, :] + rotated * sin[None, :, None, :]


# ---------------------------------------------------------------- MLA
class MLA(nn.Module):
    """
    Queries and keys/values are both projected through low-rank bottlenecks.
    Only c_kv (kv_lora_rank) and k_pe (qk_rope_dim) need caching per token,
    versus 2 * n_heads * head_dim for standard MHA. In V3: 576 vs 32768 values.

    RoPE is "decoupled": position info lives in a small separate key/query
    slice, so the up-projection W_UK can be absorbed into W_Q at inference
    (RoPE in between would block that matrix merge).
    """

    def __init__(self, c: Config):
        super().__init__()
        self.c = c
        H = c.n_heads
        self.qk_head_dim = c.qk_nope_dim + c.qk_rope_dim

        # query path: d -> q_lora -> H * (nope + rope)
        self.wq_a = nn.Linear(c.d_model, c.q_lora_rank, bias=False)
        self.q_norm = RMSNorm(c.q_lora_rank)
        self.wq_b = nn.Linear(c.q_lora_rank, H * self.qk_head_dim, bias=False)

        # kv path: d -> [c_kv (latent) | k_pe (shared across heads)]
        self.wkv_a = nn.Linear(c.d_model, c.kv_lora_rank + c.qk_rope_dim, bias=False)
        self.kv_norm = RMSNorm(c.kv_lora_rank)
        # latent -> per-head [k_nope | v]
        self.wkv_b = nn.Linear(c.kv_lora_rank, H * (c.qk_nope_dim + c.v_head_dim), bias=False)

        self.wo = nn.Linear(H * c.v_head_dim, c.d_model, bias=False)

    def forward(self, x, cos, sin):
        c = self.c
        B, T, _ = x.shape
        H = c.n_heads

        q = self.wq_b(self.q_norm(self.wq_a(x))).view(B, T, H, self.qk_head_dim)
        q_nope, q_pe = q.split([c.qk_nope_dim, c.qk_rope_dim], dim=-1)
        q_pe = apply_rope(q_pe, cos, sin)

        kv_a = self.wkv_a(x)
        c_kv, k_pe = kv_a.split([c.kv_lora_rank, c.qk_rope_dim], dim=-1)
        # >>> c_kv and k_pe are what a KV cache would store <<<
        k_pe = apply_rope(k_pe.unsqueeze(2), cos, sin)             # (B,T,1,rope)

        kv = self.wkv_b(self.kv_norm(c_kv)).view(B, T, H, c.qk_nope_dim + c.v_head_dim)
        k_nope, v = kv.split([c.qk_nope_dim, c.v_head_dim], dim=-1)

        q = torch.cat([q_nope, q_pe], dim=-1)
        k = torch.cat([k_nope, k_pe.expand(-1, -1, H, -1)], dim=-1)

        q, k, v = (t.transpose(1, 2) for t in (q, k, v))          # (B,H,T,D)
        out = F.scaled_dot_product_attention(q, k, v, is_causal=True)
        out = out.transpose(1, 2).reshape(B, T, H * c.v_head_dim)
        return self.wo(out)


# ---------------------------------------------------------------- FFN / MoE
class SwiGLU(nn.Module):
    def __init__(self, d_model, d_hidden):
        super().__init__()
        self.w1 = nn.Linear(d_model, d_hidden, bias=False)  # gate
        self.w3 = nn.Linear(d_model, d_hidden, bias=False)  # up
        self.w2 = nn.Linear(d_hidden, d_model, bias=False)  # down

    def forward(self, x):
        return self.w2(F.silu(self.w1(x)) * self.w3(x))


class DeepSeekMoE(nn.Module):
    """
    Routing in V3:
      scores   = sigmoid(x @ W_gate^T)              (not softmax)
      selected = top_k(scores + bias)               (bias only affects WHICH experts)
      weights  = scores[selected], renormalised     (bias does NOT affect weights)
    The bias is nudged after each step: overloaded experts down, idle ones up.
    That replaces the usual auxiliary load-balancing loss.
    (V3 also limits each token to experts on <=4 nodes; omitted here.)
    """

    def __init__(self, c: Config):
        super().__init__()
        self.c = c
        self.gate = nn.Linear(c.d_model, c.n_routed, bias=False)
        self.register_buffer("expert_bias", torch.zeros(c.n_routed))
        self.experts = nn.ModuleList(SwiGLU(c.d_model, c.d_expert) for _ in range(c.n_routed))
        self.shared = SwiGLU(c.d_model, c.d_expert * c.n_shared)
        self.last_load = None

    def forward(self, x):
        c = self.c
        B, T, D = x.shape
        flat = x.reshape(-1, D)                                   # (N, D)

        scores = torch.sigmoid(self.gate(flat))                   # (N, E)
        _, idx = torch.topk(scores + self.expert_bias, c.top_k, dim=-1)
        w = scores.gather(-1, idx)
        w = w / w.sum(-1, keepdim=True) * c.routed_scaling        # (N, k)

        out = torch.zeros_like(flat)
        for e in range(c.n_routed):
            token_pos, slot = (idx == e).nonzero(as_tuple=True)
            if token_pos.numel():
                out.index_add_(0, token_pos,
                               self.experts[e](flat[token_pos]) * w[token_pos, slot, None])

        self.last_load = torch.bincount(idx.flatten(), minlength=c.n_routed).float()
        return (out + self.shared(flat)).view(B, T, D)

    @torch.no_grad()
    def update_bias(self):
        """Call once per optimizer step (aux-loss-free balancing)."""
        if self.last_load is None:
            return
        load = self.last_load
        self.expert_bias += self.c.bias_update_rate * torch.sign(load.mean() - load)


# ---------------------------------------------------------------- model
class Block(nn.Module):
    def __init__(self, c: Config, layer_id: int):
        super().__init__()
        self.attn_norm = RMSNorm(c.d_model)
        self.attn = MLA(c)
        self.ffn_norm = RMSNorm(c.d_model)
        self.ffn = (SwiGLU(c.d_model, c.d_dense_ffn) if layer_id < c.n_dense_layers
                    else DeepSeekMoE(c))

    def forward(self, x, cos, sin):
        x = x + self.attn(self.attn_norm(x), cos, sin)
        return x + self.ffn(self.ffn_norm(x))


class DeepSeekMini(nn.Module):
    def __init__(self, c: Config):
        super().__init__()
        self.c = c
        self.embed = nn.Embedding(c.vocab_size, c.d_model)
        self.layers = nn.ModuleList(Block(c, i) for i in range(c.n_layers))
        self.norm = RMSNorm(c.d_model)
        self.head = nn.Linear(c.d_model, c.vocab_size, bias=False)
        cos, sin = rope_tables(c.qk_rope_dim, c.max_seq_len, c.rope_theta)
        self.register_buffer("cos", cos, persistent=False)
        self.register_buffer("sin", sin, persistent=False)

    def forward(self, tokens, targets=None):
        T = tokens.shape[1]
        x = self.embed(tokens)
        for layer in self.layers:
            x = layer(x, self.cos[:T], self.sin[:T])
        logits = self.head(self.norm(x))
        loss = None
        if targets is not None:
            loss = F.cross_entropy(logits.reshape(-1, logits.size(-1)), targets.reshape(-1))
        return logits, loss

    def update_router_biases(self):
        for layer in self.layers:
            if isinstance(layer.ffn, DeepSeekMoE):
                layer.ffn.update_bias()


# ---------------------------------------------------------------- smoke test
if __name__ == "__main__":
    torch.manual_seed(0)
    cfg = Config()
    model = DeepSeekMini(cfg)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"params: {n_params/1e6:.2f}M")

    opt = torch.optim.AdamW(model.parameters(), lr=3e-4)
    # toy task: learn to copy a repeating pattern
    data = torch.randint(0, cfg.vocab_size, (8, 65))
    for step in range(30):
        _, loss = model(data[:, :-1], data[:, 1:])
        opt.zero_grad()
        loss.backward()
        opt.step()
        model.update_router_biases()
        if step % 10 == 0 or step == 29:
            print(f"step {step:2d}  loss {loss.item():.3f}")

    moe = model.layers[-1].ffn
    print("expert load (last layer):", moe.last_load.int().tolist())

    # KV cache comparison at V3 scale
    mha = 2 * 128 * 128
    mla = 512 + 64
    print(f"V3 KV cache per token per layer: MHA {mha} vs MLA {mla} ({mha/mla:.0f}x smaller)")
