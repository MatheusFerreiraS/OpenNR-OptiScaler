// Native RDNA2 body of the head-split fused Swin layer (fswin64/128/256): NR_NATIVE=1 in pipelines.json.
//
// Same bindings, push block, window grid, weights and output as the emulated body (fswin_body.glsl through
// coopmm.glsl), and the same arithmetic: every product is an FP16 pair summed into FP32 by NR_DOT2 (v_dot2_f32_f16)
// over the same k pairs in the same order, every rounding is the same function on the same value, and the two
// reductions that are not dot products (the Q/K norms and the softmax sum) are done in the emulated body's order.
// What changes is where the data lives:
//
//   * one lane per token: lane l owns tokens l and l + 32 of the 8x8 window (its two "slots"), so a weight is the
//     same for every lane and is read as an aligned uvec4 at a uniform address (s_buffer_load_dwordx4), going
//     straight into v_dot2 as a scalar operand. No cross-lane traffic in any projection.
//   * activations in LDS as [k fragment][8-channel half][token] uvec4, so a lane's 8 channels are one ds_read_b128
//     and a wave's 32 reads are consecutive (no bank conflict).
//   * attention per head (one wave): K and V of the head in LDS, read by all lanes at one address (broadcast), the
//     softmax in two passes over the keys (sum, then normalise and multiply by V) so nothing is indexed dynamically.
//
// Wave w (gl_SubgroupID, uniform) owns: hidden group w (stage 1), output channels 32w..32w+31 (stages 2 and 6),
// head w (stages 3-5). LDS: two buffers of 64 x C FP16, as the emulated body (C=256: 64 KB, one workgroup a CU).
#extension GL_EXT_shared_memory_block : require
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_shuffle : require
#extension GL_KHR_shader_subgroup_ballot : require

#if !NR_HWAVES || NR_PERSIST || NR_TCHAIN || NR_HEADS != NR_C / 32 || defined(NR_FUSED_UPS_BLEND) || \
    defined(NR_DS_PROJECT) || defined(NR_FUSED_UPS_PROJECT) || defined(NR_WIDE_UPS_PROJECT) || \
    defined(NR_POOL_F16) || defined(NR_INPUT_F16) || NR_EDGE_BODIES || !NR_BAKED_EXP_BIAS || NR_ACC_F16 != 0 || \
    !NR_RESIDUAL_F32 || NR_QK_SCALE_FAST != 5 || NR_SWIN_BIAS_F16
#error "NR_NATIVE: the plain head-split fused Swin body (fswin64/128/256) only"
#endif

#define NV_CF (NR_C / 16)        // 16-channel fragments across C
#define NV_NX (NR_C * 8)         // uvec4 entries of one window buffer: 64 tokens x C halves / 8

// LDS. Index of token T's channels 16kf + 8hx .. +7: (2kf + hx) * 64 + T. Blocks alias at offset 0.
shared NvLds4 { uvec4 nv_x4[NV_NX]; uvec4 nv_y4[NV_NX]; };
shared NvLds1 { uint nv_x1[4 * NV_NX]; uint nv_y1[4 * NV_NX]; };

// The same buffers as uvec4 / vec4. Weights (binding 2, the FP16 twin) and activations are 256-element aligned.
layout(set = 0, binding = 0, std430) NR_COH buffer NvAct4 { uvec4 nv_a4[]; };
layout(set = 0, binding = 2, std430) readonly buffer NvWgt4 { uvec4 nv_w4[]; };
layout(set = 0, binding = 3, std430) readonly buffer NvF32x4 { vec4 nv_f4[]; };

f16vec2 nv_h(uint u) { return unpackFloat2x16(u); }
uint nv_p(float16_t a, float16_t b) { return packFloat2x16(f16vec2(a, b)); }

// s + sum over the 8 k pairs of (w0, w1) . (x0, x1), pair by pair in k order. NR_DOT2 is the emulated
// body's inner product (coopmm.glsl); `_sw` swaps both pairs (an odd row against a k-pair-swapped operand).
float nv_dot8(float s, uvec4 w0, uvec4 w1, uvec4 x0, uvec4 x1) {
    s = NR_DOT2(s, nv_h(w0.x), nv_h(x0.x)); s = NR_DOT2(s, nv_h(w0.y), nv_h(x0.y));
    s = NR_DOT2(s, nv_h(w0.z), nv_h(x0.z)); s = NR_DOT2(s, nv_h(w0.w), nv_h(x0.w));
    s = NR_DOT2(s, nv_h(w1.x), nv_h(x1.x)); s = NR_DOT2(s, nv_h(w1.y), nv_h(x1.y));
    s = NR_DOT2(s, nv_h(w1.z), nv_h(x1.z)); s = NR_DOT2(s, nv_h(w1.w), nv_h(x1.w));
    return s;
}

// acc[8s + j] += sum_k W[row0 + j][k] X[k][T_s] over KF fragments of k, rows row0..row0+7 (8-aligned, uniform).
// W: tile-blocked [row/16][k/16] 16x16 FP16 tiles at `woff` (halves); X: an LDS window buffer.
// The fragment loop is kept rolled on purpose: one iteration is 128 v_dot2 on 64 scalar weight dwords, and the
// loops unrolled (by unroll_glsl.py, or by the driver, which unrolls every constant loop here) make a 300 KB
// shader that needs every VGPR. Its header is not one unroll_glsl.py unrolls, and `nv_opaque` (the workgroup's z,
// always 0) hides the trip count from the driver; the same for the other long loops below.
#define NV_GEMM8(acc, XB, woff, KF, row0) { \
    const uint nv_wr = (woff) / 8u + ((uint(row0) >> 4u) * uint(KF)) * 32u + (uint(row0) & 15u) * 2u; \
    for (int kf = 0; kf < (KF) + nv_opaque; kf = kf + 1) { \
        const uint xi = uint(kf) * 128u + lane; \
        const uvec4 xa0 = XB[xi], xa1 = XB[xi + 64u], xb0 = XB[xi + 32u], xb1 = XB[xi + 96u]; \
        const uint wb = nv_wr + uint(kf) * 32u; \
        for (int j = 0; j < 8; ++j) { \
            const uvec4 w0 = nv_w4[wb + 2u * uint(j)], w1 = nv_w4[wb + 2u * uint(j) + 1u]; \
            acc[j] = nv_dot8(acc[j], w0, w1, xa0, xa1); \
            acc[8 + j] = nv_dot8(acc[8 + j], w0, w1, xb0, xb1); \
        } \
    } }

// e4m3 rounding of an FP32 value through FP16 (the emulated body's `nr_quant_pair(f16vec2(float16_t(a), ..))`).
float16_t nv_q16(float a) { return nr_quant_pair(f16vec2(float16_t(a), float16_t(0.0))).x; }

// Eight FP32 values of one token as the FP16 uvec4 of channels 8hx .. 8hx+7, each rounded by nv_q16.
uvec4 nv_pack_q16(const float a[16], int base) {
    return uvec4(nv_p(nv_q16(a[base]), nv_q16(a[base + 1])), nv_p(nv_q16(a[base + 2]), nv_q16(a[base + 3])),
                 nv_p(nv_q16(a[base + 4]), nv_q16(a[base + 5])), nv_p(nv_q16(a[base + 6]), nv_q16(a[base + 7])));
}

// The softmax probability before normalisation, one key: the emulated body's nr_swin_exp_baked (per component).
float16_t nv_prob(float lg, float bias) { return nr_swin_exp_baked(vec2(lg, 0.0), vec2(bias, 1.30078125)).x; }

void main() {
    // The wave index through readfirstlane: gl_SubgroupID alone stays a VGPR on gfx103x, and so would every weight
    // address derived from it (vector loads of one address instead of scalar loads).
    const int nv_opaque = int(gl_WorkGroupID.z);
    const uint tid = gl_LocalInvocationID.x, lane = gl_SubgroupInvocationID, w = subgroupBroadcastFirst(gl_SubgroupID);
    // ---- stage 0: the window's x into nv_x4; tiles outside the image are zero -------------------------
    for (uint i = tid; i < uint(NV_CF * 128); i += uint(NR_THREADS)) {
        const uint hx = i & 1u, T = (i >> 1u) & 63u, kf = i >> 7u, m = T >> 4u;
        uvec4 v = uvec4(0u);
        if (!nr_tile_oob(m)) v = nv_a4[(pc.x_off + nr_tile_base(m) + kf * 256u + (T & 15u) * 16u + hx * 8u) / 8u];
        nv_x4[kf * 128u + hx * 64u + T] = v;
    }
    barrier();

    // ---- stage 1: e = q(act(E . x)) for hidden group w (128 rows), streamed into the group's middle
    //      projection m = Wmid . e (32 rows, channels 32w..32w+31), which goes to nv_y4 ------------------
    {
        float mid[64];                                    // [32 s + o]
        for (int o = 0; o < 64; ++o) mid[o] = 0.0;
        for (int hf = 0; hf < 8 + nv_opaque; hf = hf + 1) {   // 16 hidden rows a step, rolled
            uint ep[16];                                  // [8 s + p]: (e[2p], e[2p+1]) of rows 16 hf + ..
            for (int hb = 0; hb < 2; ++hb) {
                float acc[16];
                for (int j = 0; j < 16; ++j) acc[j] = 0.0;
                NV_GEMM8(acc, nv_x4, pc.e_off, NV_CF, w * 128u + uint(hf) * 16u + uint(hb) * 8u)
                for (int s = 0; s < 2; ++s)
                    for (int p = 0; p < 4; ++p)
                        ep[8 * s + 4 * hb + p] = packFloat2x16(nr_quant_pair32(vec2(
                            nr_act_horner(acc[8 * s + 2 * p]), nr_act_horner_b(acc[8 * s + 2 * p + 1]))));
            }
            // Wmid tile row (32w + o) / 16, k fragment hf; its odd rows are stored k-pair swapped (host `kswap`),
            // which the emulated body pairs with its swapped operand: the same products, the same pair order.
            const uint mb = pc.mid_off / 8u + (w * 2u * 8u + uint(hf)) * 32u;
            for (int o = 0; o < 32; ++o) {
                const uint wb = mb + uint(o >> 4) * 256u + uint(o & 15) * 2u;
                const uvec4 w0 = nv_w4[wb], w1 = nv_w4[wb + 1u];
                for (int s = 0; s < 2; ++s) {
                    float t = mid[32 * s + o];
                    for (int p = 0; p < 8; ++p) {
                        const f16vec2 wp = nv_h((p < 4 ? w0 : w1)[p & 3]), ex = nv_h(ep[8 * s + p]);
                        t = (o & 1) != 0 ? NR_DOT2(t, wp, ex.yx) : NR_DOT2(t, wp, ex);
                    }
                    mid[32 * s + o] = t;
                }
            }
        }
        for (int s = 0; s < 2; ++s)
            for (int b = 0; b < 4; ++b) {
                float t[16];
                for (int j = 0; j < 8; ++j) t[j] = mid[32 * s + 8 * b + j];
                nv_y4[(2u * w + uint(b >> 1)) * 128u + uint(b & 1) * 64u + lane + 32u * uint(s)] = nv_pack_q16(t, 0);
            }
    }
    barrier();

    // ---- stage 2: y = q(Ct . m + rs * x), channels 32w..32w+31, in place over x ------------------------
    for (int b = 0; b < 4; ++b) {
        const uint xi = (2u * w + uint(b >> 1)) * 128u + uint(b & 1) * 64u + lane, ch = 32u * w + 8u * uint(b);
        float acc[16];
        for (int s = 0; s < 2; ++s) {
            const uvec4 x = nv_x4[xi + 32u * uint(s)];
            for (int j = 0; j < 8; ++j)
                acc[8 * s + j] = float(nv_h(x[j >> 1])[j & 1]) * wgt_f32[pc.rs_off + ch + uint(j)];
        }
        NV_GEMM8(acc, nv_y4, pc.ct_off, NV_CF, ch)
        nv_x4[xi] = nv_pack_q16(acc, 0);
        nv_x4[xi + 32u] = nv_pack_q16(acc, 8);
    }
    barrier();

    // ---- stages 3 to 5: head w. Q, K, V = Wqkv . y; cosine-normalised Q and K ---------------------------
    uint qe[32], yres[32];                        // [16 s + p]: Q pairs; the residual y of channels 32w..
    float16_t hscale = float16_t(wgt_f32[pc.s_off + w]);
    {
        uint ke[32], ve[32];
        for (int part = 0; part < 3; ++part) {    // Q, K, V: rows 96w + 32 part ..
            float a[64];                          // [32 s + channel]
            for (int b = 0; b < 4; ++b) {
                float acc[16];
                for (int j = 0; j < 16; ++j) acc[j] = 0.0;
                NV_GEMM8(acc, nv_x4, pc.qkv_off, NV_CF, 96u * w + 32u * uint(part) + 8u * uint(b))
                for (int s = 0; s < 2; ++s)
                    for (int j = 0; j < 8; ++j) a[32 * s + 8 * b + j] = acc[8 * s + j];
            }
            for (int s = 0; s < 2; ++s) {
                if (part == 2) {
                    for (int p = 0; p < 16; ++p)
                        ve[16 * s + p] = nv_p(nv_q16(a[32 * s + 2 * p]), nv_q16(a[32 * s + 2 * p + 1]));
                    continue;
                }
                // The norm in the emulated body's order: lane half hi holds the channels of parity hi, summed
                // into four partials (channel 16d + 2c + hi into partial c & 3, c outer, d inner), the halves'
                // sums rounded to FP16 and added in FP16.
                float16_t sh[2];
                for (int hi = 0; hi < 2; ++hi) {
                    float sp[4];
                    for (int i = 0; i < 4; ++i) sp[i] = 0.0;
                    for (int c = 0; c < 8; ++c)
                        for (int d = 0; d < 2; ++d) {
                            const float v = a[32 * s + 16 * d + 2 * c + hi];
                            sp[c & 3] = fma(v, v, sp[c & 3]);
                        }
                    sh[hi] = f16vec2(vec2((sp[0] + sp[1]) + (sp[2] + sp[3]), 0.0)).x;
                }
                const float16_t n2 = sh[0] + sh[1];
                const float16_t nq = float16_t(inversesqrt(float(max(n2, float16_t(0.000062)))));
                const float f = part == 0 ? float(nq) * float(hscale) : float(nq);
                for (int p = 0; p < 16; ++p) {
                    const uint u = packFloat2x16(nr_quant_pair32(vec2(a[32 * s + 2 * p], a[32 * s + 2 * p + 1]) * f));
                    if (part == 0) qe[16 * s + p] = u; else ke[16 * s + p] = u;
                }
            }
        }
        for (int s = 0; s < 2; ++s)
            for (int q = 0; q < 4; ++q) {
                const uvec4 y = nv_x4[(2u * w + uint(q >> 1)) * 128u + uint(q & 1) * 64u + lane + 32u * uint(s)];
                for (int i = 0; i < 4; ++i) yres[16 * s + 4 * q + i] = y[i];
            }
        barrier();                                // every wave is done with y and m: reuse their LDS per head
        // K of head w into nv_y4[256 w + 4 T + q] (the head's own context slots, written last).
        // V into nv_x1[1024 w + 32 kp + v] = (V[2kp][v], V[2kp+1][v]): even tokens write v < 16, odd v >= 16.
        const bool odd = (lane & 1u) != 0u;
        for (int s = 0; s < 2; ++s) {
            const uint T = lane + 32u * uint(s);
            for (int q = 0; q < 4; ++q)
                nv_y4[256u * w + 4u * T + uint(q)] = uvec4(ke[16 * s + 4 * q], ke[16 * s + 4 * q + 1],
                                                           ke[16 * s + 4 * q + 2], ke[16 * s + 4 * q + 3]);
            uint dw[16];
            for (int p = 0; p < 16; ++p) {
                const uint mine = ve[16 * s + p], other = subgroupShuffleXor(mine, 1u);
                const f16vec2 lo = nv_h(odd ? other : mine), hi = nv_h(odd ? mine : other);
                // dword of channel 2p and 2p+1; this lane keeps the 8 pairs of its half of the channels.
                if ((p < 8) != odd) { dw[2 * (p & 7)] = nv_p(lo.x, hi.x); dw[2 * (p & 7) + 1] = nv_p(lo.y, hi.y); }
            }
            const uint vb = 256u * w + (T >> 1u) * 8u + (odd ? 4u : 0u);
            for (int q = 0; q < 4; ++q) nv_x4[vb + uint(q)] = uvec4(dw[4 * q], dw[4 * q + 1], dw[4 * q + 2], dw[4 * q + 3]);
        }
        subgroupMemoryBarrierShared();
    }
    {
        uint cq[32];                              // [16 s + p]: the quantised context pairs
        const uint kb = 256u * w, bb = (pc.b_off + w * 4096u) / 4u;
        for (int s = 0; s < 2; ++s) {
            const uint T = lane + 32u * uint(s);
            // pass 1: the probability sum in the emulated body's order: key 16j + 4c + 2e + hi goes to partial
            // [hi][c].e, j outer; then ((p0 + p1) + p2) + p3 a half, the halves added, then .x + .y, all FP16.
            f16vec2 part[2][4];
            for (int hi = 0; hi < 2; ++hi) for (int c = 0; c < 4; ++c) part[hi][c] = f16vec2(0.0hf);
            for (int j = 0; j < 4 + nv_opaque; j = j + 1) {
                for (int i = 0; i < 16; ++i) {
                    const uint key = 16u * uint(j) + uint(i);
                    float lg = 0.0;
                    for (int q = 0; q < 4; ++q) {
                        const uvec4 k4 = nv_y4[kb + 4u * key + uint(q)];
                        for (int e = 0; e < 4; ++e) {
                            const f16vec2 kp = nv_h(k4[e]), qp = nv_h(qe[16 * s + 4 * q + e]);
                            lg = (i & 1) != 0 ? NR_DOT2(lg, kp.yx, qp.yx) : NR_DOT2(lg, kp, qp);
                        }
                    }
                    const float16_t pr = nv_prob(lg, nv_f4[bb + T * 16u + key / 4u][i & 3]);
                    if (((i >> 1) & 1) == 0) part[i & 1][i >> 2].x += pr; else part[i & 1][i >> 2].y += pr;
                }
            }
            f16vec2 tot[2];
            for (int hi = 0; hi < 2; ++hi) tot[hi] = ((part[hi][0] + part[hi][1]) + part[hi][2]) + part[hi][3];
            const f16vec2 t2 = tot[0] + tot[1];
            const float16_t sum = t2.x + t2.y;
            const float inv = float(float16_t(1.0 / float(max(sum, float16_t(6.103515625e-05)))));
            // pass 2: the same probabilities, normalised and rounded, times V.
            float ctx[32];
            for (int v = 0; v < 32; ++v) ctx[v] = 0.0;
            for (int j = 0; j < 4 + nv_opaque; j = j + 1) {
                uint pp[8];
                for (int i = 0; i < 16; i += 2) {
                    float16_t pq[2];
                    for (int e = 0; e < 2; ++e) {
                        const uint key = 16u * uint(j) + uint(i + e);
                        float lg = 0.0;
                        for (int q = 0; q < 4; ++q) {
                            const uvec4 k4 = nv_y4[kb + 4u * key + uint(q)];
                            for (int r = 0; r < 4; ++r) {
                                const f16vec2 kp = nv_h(k4[r]), qp = nv_h(qe[16 * s + 4 * q + r]);
                                lg = e != 0 ? NR_DOT2(lg, kp.yx, qp.yx) : NR_DOT2(lg, kp, qp);
                            }
                        }
                        const float16_t pr = nv_prob(lg, nv_f4[bb + T * 16u + key / 4u][(i + e) & 3]);
                        pq[e] = float16_t(float(pr) * inv);
                    }
                    pp[i >> 1] = packFloat2x16(nr_quant_pair(f16vec2(pq[0], pq[1])));
                }
                for (int k = 0; k < 8; ++k) {
                    const uint vrow = 256u * w + (8u * uint(j) + uint(k)) * 8u;
                    const f16vec2 pk = nv_h(pp[k]);
                    for (int q = 0; q < 8; ++q) {
                        const uvec4 v4 = nv_x4[vrow + uint(q)];
                        for (int e = 0; e < 4; ++e) {
                            const int v = 4 * q + e;
                            const f16vec2 vp = nv_h(v4[e]);
                            ctx[v] = (v & 1) != 0 ? NR_DOT2(ctx[v], vp.yx, pk.yx) : NR_DOT2(ctx[v], vp, pk);
                        }
                    }
                }
            }
            for (int p = 0; p < 16; ++p) cq[16 * s + p] = nv_p(nv_q16(ctx[2 * p]), nv_q16(ctx[2 * p + 1]));
        }
        subgroupMemoryBarrierShared();            // every lane's last K read before the context replaces it
        for (int s = 0; s < 2; ++s)
            for (int q = 0; q < 4; ++q)
                nv_y4[256u * w + uint(q >> 1) * 128u + uint(q & 1) * 64u + lane + 32u * uint(s)] =
                    uvec4(cq[16 * s + 4 * q], cq[16 * s + 4 * q + 1], cq[16 * s + 4 * q + 2], cq[16 * s + 4 * q + 3]);
    }
    barrier();

    // ---- stage 6: out = q(Wo . context + ars * y), channels 32w..32w+31, to the arena ------------------
    for (int b = 0; b < 4; ++b) {
        const uint ch = 32u * w + 8u * uint(b);
        float acc[16];
        for (int s = 0; s < 2; ++s)
            for (int j = 0; j < 8; ++j)
                acc[8 * s + j] = float(nv_h(yres[16 * s + 4 * b + (j >> 1)])[j & 1]) * wgt_f32[pc.ars_off + ch + uint(j)];
        NV_GEMM8(acc, nv_y4, pc.op_off, NV_CF, ch)
        for (int s = 0; s < 2; ++s) {
            const uint m = (lane >> 4u) + 2u * uint(s);
            if (!nr_tile_oob(m))
                nv_a4[(pc.o_off + nr_tile_base(m) + (ch >> 4u) * 256u + (lane & 15u) * 16u + (ch & 15u)) / 8u] =
                    nv_pack_q16(acc, 8 * s);
        }
    }
}
