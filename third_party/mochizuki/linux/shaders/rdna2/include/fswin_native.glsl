// Native RDNA2 bodies of the fused Swin layer: NR_NATIVE=1 in pipelines.json.
//   NR_HWAVES (C >= 64, fswin64/128/256): one wave a head, 32 x NR_HEADS invocations, one window a workgroup.
//   C = 32 (fswin32/fswin32nh): the one-head body, two waves of 32 tokens.
//
// Same bindings, push block, window grid, weights and output as the emulated body (fswin_body.glsl through
// coopmm.glsl), and the same arithmetic: every product is an FP16 pair summed into FP32 by NR_DOT2 (v_dot2_f32_f16)
// over the same k pairs in the same order, every rounding is the same function on the same value, and the
// reductions that are not dot products (the Q/K norms, the softmax sum) are done in the emulated body's order.
// Measured: byte-identical network output. What changes is where the data lives:
//
//   * one lane per token, so a weight is the same for every lane and is read as an aligned uvec4 at a uniform
//     address (s_buffer_load_dwordx4), going straight into v_dot2 as a scalar operand. No cross-lane traffic in
//     any projection. C >= 64: lane l owns tokens l and l + 32 of the 8x8 window (its two slots), so each scalar
//     weight feeds two v_dot2. C = 32: wave w owns tokens 32w + l, one each.
//   * C >= 64: activations in LDS as [k fragment][8-channel half][token] uvec4, so a lane's 8 channels are one
//     ds_read_b128 and a wave's 32 reads are consecutive (no bank conflict). C = 32: in registers.
//   * attention per head: K and V of the head in LDS, read by all lanes at one address (broadcast), the softmax in
//     two passes over the keys (sum, then normalise and multiply by V) so nothing is indexed dynamically.
//
// The k-pair swap of the FP16 host (`kswap`, nr_graph.cpp): the emulated body multiplies the odd rows of some
// weight tiles, stored with every k pair swapped, by operands it built in registers with the same swap, and the
// odd rows of its register-built activation x activation products have both operands swapped. NR_DOT2 is then
// given the pair in the other order; here the same pairs are given in the same order (`.yx`), so the products and
// their order are the emulated body's exactly.
#extension GL_EXT_shared_memory_block : require
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_shuffle : require
#extension GL_KHR_shader_subgroup_ballot : require

#if NR_PERSIST || NR_HEADS != NR_C / 32 || defined(NR_FUSED_UPS_BLEND) || \
    defined(NR_DS_PROJECT) || defined(NR_FUSED_UPS_PROJECT) || defined(NR_WIDE_UPS_PROJECT) || \
    defined(NR_POOL_F16) || defined(NR_INPUT_F16) || NR_EDGE_BODIES || !NR_BAKED_EXP_BIAS || NR_ACC_F16 != 0 || \
    !NR_RESIDUAL_F32 || NR_QK_SCALE_FAST != 5 || NR_SWIN_BIAS_F16 || NR_WIN != 64 || \
    (NR_HWAVES && NR_TCHAIN) || (!NR_HWAVES && (NR_C != 32 || NR_FWAVES != 2))
#error "NR_NATIVE: the plain fused Swin bodies (fswin32/32nh/64/128/256) only"
#endif

#define NV_CF (NR_C / 16)        // 16-channel fragments across C
#if NR_HWAVES
#define NV_NX (NR_C * 8)         // uvec4 entries of one window buffer: 64 tokens x C halves / 8
#else
#define NV_NX 256                // C = 32: K (64 keys x 4 uvec4) and V (32 key pairs x 8 uvec4)
#endif

// LDS. C >= 64: token T's channels 16kf + 8hx .. +7 at (2kf + hx) * 64 + T. Head h's K at nv_y4[256h + 4T + q]
// (channels 8q ..), its V at nv_x1[1024h + 32kp + v] = (V[2kp][v], V[2kp+1][v]). Blocks alias at offset 0.
shared NvLds4 { uvec4 nv_x4[NV_NX]; uvec4 nv_y4[NV_NX]; };
shared NvLds1 { uint nv_x1[4 * NV_NX]; uint nv_y1[4 * NV_NX]; };

// The same buffers as uvec4 / vec4. Weights (binding 2, the FP16 twin) and activations are 256-element aligned.
layout(set = 0, binding = 0, std430) NR_COH buffer NvAct4 { uvec4 nv_a4[]; };
layout(set = 0, binding = 2, std430) readonly buffer NvWgt4 { uvec4 nv_w4[]; };
layout(set = 0, binding = 3, std430) readonly buffer NvF32x4 { vec4 nv_f4[]; };

f16vec2 nv_h(uint u) { return unpackFloat2x16(u); }
uint nv_p(float16_t a, float16_t b) { return packFloat2x16(f16vec2(a, b)); }

// s + sum over the 8 k pairs of (w0, w1) . (x0, x1), pair by pair in k order (NR_DOT2: coopmm.glsl).
float nv_dot8(float s, uvec4 w0, uvec4 w1, uvec4 x0, uvec4 x1) {
    s = NR_DOT2(s, nv_h(w0.x), nv_h(x0.x)); s = NR_DOT2(s, nv_h(w0.y), nv_h(x0.y));
    s = NR_DOT2(s, nv_h(w0.z), nv_h(x0.z)); s = NR_DOT2(s, nv_h(w0.w), nv_h(x0.w));
    s = NR_DOT2(s, nv_h(w1.x), nv_h(x1.x)); s = NR_DOT2(s, nv_h(w1.y), nv_h(x1.y));
    s = NR_DOT2(s, nv_h(w1.z), nv_h(x1.z)); s = NR_DOT2(s, nv_h(w1.w), nv_h(x1.w));
    return s;
}
// The same with each pair given as (high, low): an odd row against k-pair-swapped storage and operand.
float nv_dot8s(float s, uvec4 w0, uvec4 w1, uvec4 x0, uvec4 x1) {
    s = NR_DOT2(s, nv_h(w0.x), nv_h(x0.x).yx); s = NR_DOT2(s, nv_h(w0.y), nv_h(x0.y).yx);
    s = NR_DOT2(s, nv_h(w0.z), nv_h(x0.z).yx); s = NR_DOT2(s, nv_h(w0.w), nv_h(x0.w).yx);
    s = NR_DOT2(s, nv_h(w1.x), nv_h(x1.x).yx); s = NR_DOT2(s, nv_h(w1.y), nv_h(x1.y).yx);
    s = NR_DOT2(s, nv_h(w1.z), nv_h(x1.z).yx); s = NR_DOT2(s, nv_h(w1.w), nv_h(x1.w).yx);
    return s;
}

// Weight row `row`, k fragment kf of a tile-blocked [row/16][k/16] matrix of 16x16 FP16 tiles at `woff` (halves),
// KF fragments across k: the two uvec4 of its 16 k values (uniform address: scalar loads).
#define NV_WROW(woff, KF, row, kf) ((woff) / 8u + ((uint(row) >> 4u) * uint(KF) + uint(kf)) * 32u + (uint(row) & 15u) * 2u)

// e4m3 rounding of an FP32 value through FP16 (the emulated body's `nr_quant_pair(f16vec2(float16_t(a), ..))`).
float16_t nv_q16(float a) { return nr_quant_pair(f16vec2(float16_t(a), float16_t(0.0))).x; }

// Eight FP32 values as the FP16 uvec4 of 8 channels, each rounded by nv_q16.
uvec4 nv_pack_q16(const float a[16], int base) {
    return uvec4(nv_p(nv_q16(a[base]), nv_q16(a[base + 1])), nv_p(nv_q16(a[base + 2]), nv_q16(a[base + 3])),
                 nv_p(nv_q16(a[base + 4]), nv_q16(a[base + 5])), nv_p(nv_q16(a[base + 6]), nv_q16(a[base + 7])));
}

// The cosine norm of one token's 32 Q (or K) channels, in the emulated body's order: lane half hi holds the
// channels of parity hi, summed into four partials (channel 16d + 2c + hi into partial c & 3, c outer, d inner);
// the halves' sums rounded to FP16 and added in FP16.
float16_t nv_norm(const float a[32]) {
    float16_t sh[2];
    for (int hi = 0; hi < 2; ++hi) {
        float sp[4];
        for (int i = 0; i < 4; ++i) sp[i] = 0.0;
        for (int c = 0; c < 8; ++c)
            for (int d = 0; d < 2; ++d) {
                const float v = a[16 * d + 2 * c + hi];
                sp[c & 3] = fma(v, v, sp[c & 3]);
            }
        sh[hi] = f16vec2(vec2((sp[0] + sp[1]) + (sp[2] + sp[3]), 0.0)).x;
    }
    const float16_t n2 = sh[0] + sh[1];
    return float16_t(inversesqrt(float(max(n2, float16_t(0.000062)))));
}

// Logits of query q against the 16 keys 16j .. 16j+15 of head h (K in nv_y4), and the probabilities before
// normalisation. The exponent trick (nr_swin_exp_baked) works on a pair, and with NR_EXP_NOHI the second value
// depends on the first, so the pairs are the emulated body's: keys (4c + hi, 4c + 2 + hi) of the block.
void nv_probs16(uint h, uint T, uint j, const uint q[16], out f16vec2 pr[8]) {
    float lg[16];
    for (int i = 0; i < 16; ++i) {
        const uint key = 16u * j + uint(i);
        float s = 0.0;
        for (int r = 0; r < 4; ++r) {
            const uvec4 k4 = nv_y4[256u * h + 4u * key + uint(r)];
            for (int e = 0; e < 4; ++e) {
                const f16vec2 kp = nv_h(k4[e]), qp = nv_h(q[4 * r + e]);
                s = (i & 1) != 0 ? NR_DOT2(s, kp.yx, qp.yx) : NR_DOT2(s, kp, qp);
            }
        }
        lg[i] = s;
    }
    const uint bb = (pc.b_off + h * 4096u) / 4u + T * 16u + 4u * j;
    float bs[16];
    for (int r = 0; r < 4; ++r) { const vec4 b4 = nv_f4[bb + uint(r)]; for (int e = 0; e < 4; ++e) bs[4 * r + e] = b4[e]; }
    for (int c = 0; c < 4; ++c)
        for (int hi = 0; hi < 2; ++hi) {
            const int a = 4 * c + hi;
            pr[2 * c + hi] = nr_swin_exp_baked(vec2(lg[a], lg[a + 2]), vec2(bs[a], bs[a + 2]));
        }
}

// Window attention of head h for query token T: q holds its 16 quantised Q pairs, cq gets the 16 quantised
// context pairs. K and V of the head in LDS (above).
void nv_attn(uint h, uint T, const uint q[16], out uint cq[16]) {
    const int opaque = int(gl_WorkGroupID.z);
    // pass 1: the probability sum in the emulated body's order: pair (4c + hi, 4c + 2 + hi) of block j into
    // partial [hi][c], j outer; then ((p0 + p1) + p2) + p3 a half, the halves added, then .x + .y, all FP16.
    f16vec2 part[2][4];
    for (int hi = 0; hi < 2; ++hi) for (int c = 0; c < 4; ++c) part[hi][c] = f16vec2(0.0hf);
    for (int j = 0; j < 4 + opaque; j = j + 1) {
        f16vec2 pr[8];
        nv_probs16(h, T, uint(j), q, pr);
        for (int c = 0; c < 4; ++c) for (int hi = 0; hi < 2; ++hi) part[hi][c] = part[hi][c] + pr[2 * c + hi];
    }
    f16vec2 tot[2];
    for (int hi = 0; hi < 2; ++hi) tot[hi] = ((part[hi][0] + part[hi][1]) + part[hi][2]) + part[hi][3];
    const f16vec2 t2 = tot[0] + tot[1];
    const float16_t sum = t2.x + t2.y;
    const float inv = float(float16_t(1.0 / float(max(sum, float16_t(6.103515625e-05)))));
    // pass 2: the same probabilities, normalised and rounded, times V.
    float ctx[32];
    for (int v = 0; v < 32; ++v) ctx[v] = 0.0;
    for (int j = 0; j < 4 + opaque; j = j + 1) {
        f16vec2 pr[8];
        nv_probs16(h, T, uint(j), q, pr);
        float16_t pk[16];
        for (int c = 0; c < 4; ++c)
            for (int hi = 0; hi < 2; ++hi) {
                const f16vec2 qp = nr_quant_pair(f16vec2(float16_t(float(pr[2 * c + hi].x) * inv),
                                                         float16_t(float(pr[2 * c + hi].y) * inv)));
                pk[4 * c + hi] = qp.x; pk[4 * c + 2 + hi] = qp.y;
            }
        for (int k = 0; k < 8; ++k) {
            const uint vrow = 256u * h + (8u * uint(j) + uint(k)) * 8u;
            const f16vec2 pp = f16vec2(pk[2 * k], pk[2 * k + 1]);
            for (int r = 0; r < 8; ++r) {
                const uvec4 v4 = nv_x4[vrow + uint(r)];
                for (int e = 0; e < 4; ++e) {
                    const int v = 4 * r + e;
                    const f16vec2 vp = nv_h(v4[e]);
                    ctx[v] = (v & 1) != 0 ? NR_DOT2(ctx[v], vp.yx, pp.yx) : NR_DOT2(ctx[v], vp, pp);
                }
            }
        }
    }
    for (int p = 0; p < 16; ++p) cq[p] = nv_p(nv_q16(ctx[2 * p]), nv_q16(ctx[2 * p + 1]));
}

// K and V of head h for token T into LDS (layout above). k, v: the token's 16 quantised pairs. V goes in key
// pairs, so lanes T and T ^ 1 (one wave) exchange theirs: the even token writes channels 0..15, the odd 16..31.
void nv_store_kv(uint h, uint T, const uint k[16], const uint v[16]) {
    for (int q = 0; q < 4; ++q) nv_y4[256u * h + 4u * T + uint(q)] = uvec4(k[4 * q], k[4 * q + 1], k[4 * q + 2], k[4 * q + 3]);
    const bool odd = (T & 1u) != 0u;
    uint dw[16];
    for (int p = 0; p < 16; ++p) {
        const uint mine = v[p], other = subgroupShuffleXor(mine, 1u);
        const f16vec2 lo = nv_h(odd ? other : mine), hi = nv_h(odd ? mine : other);
        if ((p < 8) != odd) { dw[2 * (p & 7)] = nv_p(lo.x, hi.x); dw[2 * (p & 7) + 1] = nv_p(lo.y, hi.y); }
    }
    const uint vb = 256u * h + (T >> 1u) * 8u + (odd ? 4u : 0u);
    for (int q = 0; q < 4; ++q) nv_x4[vb + uint(q)] = uvec4(dw[4 * q], dw[4 * q + 1], dw[4 * q + 2], dw[4 * q + 3]);
}

// Q (part 0, times the head's logit scale) or K (part 1) of one token from its 32 FP32 channels: the cosine
// norm, then the e4m3 rounding of the scaled FP32 value (nr_qscale_fast / nr_kscale_fast).
void nv_qk(const float a[32], int part, float16_t hscale, out uint o[16]) {
    const float16_t n = nv_norm(a);
    const float f = part == 0 ? float(n) * float(hscale) : float(n);
    for (int p = 0; p < 16; ++p) o[p] = packFloat2x16(nr_quant_pair32(vec2(a[2 * p], a[2 * p + 1]) * f));
}

#if NR_HWAVES
// acc[8s + j] += sum_k W[row0 + j][k] X[k][T_s] over KF fragments of k, rows row0..row0+7 (8-aligned, uniform),
// X an LDS window buffer. The fragment loop is kept rolled on purpose: one iteration is 128 v_dot2 on 64 scalar
// weight dwords, and the loops unrolled (by unroll_glsl.py, or by the driver, which unrolls every constant loop
// here) make a 300 KB shader that needs every VGPR. Its header is not one unroll_glsl.py unrolls, and `nv_opaque`
// (the workgroup's z, always 0) hides the trip count from the driver; the same for the other long loops.
#define NV_GEMM8(acc, XB, woff, KF, row0) { \
    for (int kf = 0; kf < (KF) + nv_opaque; kf = kf + 1) { \
        const uint xi = uint(kf) * 128u + lane; \
        const uvec4 xa0 = XB[xi], xa1 = XB[xi + 64u], xb0 = XB[xi + 32u], xb1 = XB[xi + 96u]; \
        const uint wb = NV_WROW(woff, KF, row0, kf); \
        for (int j = 0; j < 8; ++j) { \
            const uvec4 w0 = nv_w4[wb + 2u * uint(j)], w1 = nv_w4[wb + 2u * uint(j) + 1u]; \
            acc[j] = nv_dot8(acc[j], w0, w1, xa0, xa1); \
            acc[8 + j] = nv_dot8(acc[8 + j], w0, w1, xb0, xb1); \
        } \
    } }

void main() {
    const int nv_opaque = int(gl_WorkGroupID.z);
    // The wave index through readfirstlane: gl_SubgroupID alone stays a VGPR on gfx103x, and so would every weight
    // address derived from it (vector loads of one address instead of scalar loads).
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
            uvec4 ep[4];                                  // [2 s + half]: (e[2p], e[2p+1]) of rows 16 hf + ..
            for (int hb = 0; hb < 2; ++hb) {
                float acc[16];
                for (int j = 0; j < 16; ++j) acc[j] = 0.0;
                NV_GEMM8(acc, nv_x4, pc.e_off, NV_CF, w * 128u + uint(hf) * 16u + uint(hb) * 8u)
                for (int s = 0; s < 2; ++s)
                    for (int p = 0; p < 4; ++p)
                        ep[2 * s + hb][p] = packFloat2x16(nr_quant_pair32(vec2(
                            nr_act_horner(acc[8 * s + 2 * p]), nr_act_horner_b(acc[8 * s + 2 * p + 1]))));
            }
            // Wmid: tile row (32w + o) / 16, k fragment hf; odd rows k-pair swapped (`kswap`).
            for (int o = 0; o < 32; ++o) {
                const uint wb = NV_WROW(pc.mid_off, 8, 32u * w + uint(o), hf);
                const uvec4 w0 = nv_w4[wb], w1 = nv_w4[wb + 1u];
                for (int s = 0; s < 2; ++s)
                    mid[32 * s + o] = (o & 1) != 0 ? nv_dot8s(mid[32 * s + o], w0, w1, ep[2 * s], ep[2 * s + 1])
                                                   : nv_dot8(mid[32 * s + o], w0, w1, ep[2 * s], ep[2 * s + 1]);
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

    // ---- stages 3 to 5: head w. Q, K, V = Wqkv . y; cosine-normalised Q and K, attention -----------------
    uint yres[32];                                // [16 s + p]: the residual y of channels 32w..
    {
        const float16_t hscale = float16_t(wgt_f32[pc.s_off + w]);
        uint qe[2][16], ke[2][16], ve[2][16];
        for (int part = 0; part < 3; ++part) {    // Q, K, V: rows 96w + 32 part ..
            float a[2][32];
            for (int b = 0; b < 4; ++b) {
                float acc[16];
                for (int j = 0; j < 16; ++j) acc[j] = 0.0;
                NV_GEMM8(acc, nv_x4, pc.qkv_off, NV_CF, 96u * w + 32u * uint(part) + 8u * uint(b))
                for (int s = 0; s < 2; ++s)
                    for (int j = 0; j < 8; ++j) a[s][8 * b + j] = acc[8 * s + j];
            }
            for (int s = 0; s < 2; ++s) {
                if (part == 0) nv_qk(a[s], 0, hscale, qe[s]);
                else if (part == 1) nv_qk(a[s], 1, hscale, ke[s]);
                else for (int p = 0; p < 16; ++p) ve[s][p] = nv_p(nv_q16(a[s][2 * p]), nv_q16(a[s][2 * p + 1]));
            }
        }
        for (int s = 0; s < 2; ++s)
            for (int q = 0; q < 4; ++q) {
                const uvec4 y = nv_x4[(2u * w + uint(q >> 1)) * 128u + uint(q & 1) * 64u + lane + 32u * uint(s)];
                for (int i = 0; i < 4; ++i) yres[16 * s + 4 * q + i] = y[i];
            }
        barrier();                                // every wave is done with y and m: reuse their LDS per head
        for (int s = 0; s < 2; ++s) nv_store_kv(w, lane + 32u * uint(s), ke[s], ve[s]);
        subgroupMemoryBarrierShared();
        uint cq[2][16];
        for (int s = 0; s < 2; ++s) nv_attn(w, lane + 32u * uint(s), qe[s], cq[s]);
        subgroupMemoryBarrierShared();            // every lane's last K read before the context replaces it
        for (int s = 0; s < 2; ++s)
            for (int q = 0; q < 4; ++q)
                nv_y4[256u * w + uint(q >> 1) * 128u + uint(q & 1) * 64u + lane + 32u * uint(s)] =
                    uvec4(cq[s][4 * q], cq[s][4 * q + 1], cq[s][4 * q + 2], cq[s][4 * q + 3]);
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

#else   // C = 32, one head, two waves

// acc[j] (+)= W[row0 + j] . v for 16 rows from row0 (16-aligned) of a [rows][32] matrix (KF = 2), v the token's
// 16 pairs; odd rows swapped when `sw` (its odd rows are stored k-pair swapped against a swapped operand).
#define NV_ROWS32(acc, woff, row0, v, sw) \
    for (int j = 0; j < 16; ++j) { \
        const uint wa = NV_WROW(woff, 2, uint(row0) + uint(j), 0), wb = NV_WROW(woff, 2, uint(row0) + uint(j), 1); \
        const uvec4 v0 = uvec4(v[0], v[1], v[2], v[3]), v1 = uvec4(v[4], v[5], v[6], v[7]); \
        const uvec4 v2 = uvec4(v[8], v[9], v[10], v[11]), v3 = uvec4(v[12], v[13], v[14], v[15]); \
        if ((sw) && (j & 1) != 0) { \
            acc[j] = nv_dot8s(acc[j], nv_w4[wa], nv_w4[wa + 1u], v0, v1); \
            acc[j] = nv_dot8s(acc[j], nv_w4[wb], nv_w4[wb + 1u], v2, v3); \
        } else { \
            acc[j] = nv_dot8(acc[j], nv_w4[wa], nv_w4[wa + 1u], v0, v1); \
            acc[j] = nv_dot8(acc[j], nv_w4[wb], nv_w4[wb + 1u], v2, v3); \
        } \
    }

void main() {
    const int nv_opaque = int(gl_WorkGroupID.z);
#if NR_TCHAIN
    NR_TC_PROLOGUE
    // The frame tick, as the emulated body (fswin_t.comp main).
    if (nr_tc_rec != 0xFFFFFFFFu && nr_tc_w[nr_tc_rec + 1u] != 0u && gl_WorkGroupID.x == 0u &&
        gl_WorkGroupID.y == 0u && gl_LocalInvocationIndex == 0u)
        atomicAdd(nr_tc_u[nr_tc_w[nr_tc_rec + 4u]], 1u);
#endif
    const uint lane = gl_SubgroupInvocationID, w = subgroupBroadcastFirst(gl_SubgroupID);
    const uint T = 32u * w + lane, m = T >> 4u;
    const bool oob = nr_tile_oob(m);
    // x: the token's 32 channels (zero outside the image)
    uint x[16];
    {
        const uint xb = (pc.x_off + nr_tile_base(m) + (lane & 15u) * 16u) / 8u;
        for (int q = 0; q < 4; ++q) {
            const uvec4 v = oob ? uvec4(0u) : nv_a4[xb + uint(q >> 1) * 32u + uint(q & 1)];
            for (int i = 0; i < 4; ++i) x[4 * q + i] = v[i];
        }
    }
    // ---- the MLP, streamed: y = Ct . q(act(E . x)) + rs * x ----------------------------------------
    float y[32];
    for (int c = 0; c < 32; ++c) y[c] = float(nv_h(x[c >> 1])[c & 1]) * wgt_f32[pc.rs_off + uint(c)];
    for (int hf = 0; hf < 8 + nv_opaque; hf = hf + 1) {
        float e[16];
        for (int j = 0; j < 16; ++j) e[j] = 0.0;
        NV_ROWS32(e, pc.e_off, 16 * hf, x, false)
        uvec4 ep[2];
        for (int p = 0; p < 8; ++p)
            ep[p >> 2][p & 3] = packFloat2x16(nr_quant_pair32(vec2(nr_act_horner(e[2 * p]), nr_act_horner_b(e[2 * p + 1]))));
        // Ct: [32][128], tile row o / 16, k fragment hf; odd rows k-pair swapped (`kswap`).
        for (int o = 0; o < 32; ++o) {
            const uint wb = NV_WROW(pc.ct_off, 8, o, hf);
            y[o] = (o & 1) != 0 ? nv_dot8s(y[o], nv_w4[wb], nv_w4[wb + 1u], ep[0], ep[1])
                                : nv_dot8(y[o], nv_w4[wb], nv_w4[wb + 1u], ep[0], ep[1]);
        }
    }
    // yh: y in FP16 (the attention residual), yq: on the e4m3 grid (the QKV operand).
    uint yh[16], yq[16];
    for (int p = 0; p < 16; ++p) {
        yh[p] = nv_p(float16_t(y[2 * p]), float16_t(y[2 * p + 1]));
        yq[p] = packFloat2x16(nr_quant_pair(nv_h(yh[p])));
    }
    // ---- Q, K, V; Q and K rows are k-pair swapped where odd (`kswap`), V is not --------------------
    {
        const float16_t hscale = float16_t(wgt_f32[pc.s_off]);
        uint qe[16], ke[16], ve[16];
        float a[32];
        for (int part = 0; part < 3; ++part) {
            for (int c = 0; c < 32; ++c) a[c] = 0.0;
            float a0[16], a1[16];
            for (int j = 0; j < 16; ++j) { a0[j] = 0.0; a1[j] = 0.0; }
            NV_ROWS32(a0, pc.qkv_off, 32 * part, yq, part < 2)
            NV_ROWS32(a1, pc.qkv_off, 32 * part + 16, yq, part < 2)
            for (int j = 0; j < 16; ++j) { a[j] = a0[j]; a[16 + j] = a1[j]; }
            if (part == 0) nv_qk(a, 0, hscale, qe);
            else if (part == 1) nv_qk(a, 1, hscale, ke);
            else for (int p = 0; p < 16; ++p) ve[p] = nv_p(nv_q16(a[2 * p]), nv_q16(a[2 * p + 1]));
        }
        nv_store_kv(0u, T, ke, ve);
        barrier();                                // keys and values of both waves
        uint cq[16];
        nv_attn(0u, T, qe, cq);
        // ---- out = q(Wo . context + ars * yh); Wo's odd rows k-pair swapped (`kswap`) -------------------
        float o0[16], o1[16];
        for (int j = 0; j < 16; ++j) {
            o0[j] = float(nv_h(yh[j >> 1])[j & 1]) * wgt_f32[pc.ars_off + uint(j)];
            o1[j] = float(nv_h(yh[8 + (j >> 1)])[j & 1]) * wgt_f32[pc.ars_off + 16u + uint(j)];
        }
        NV_ROWS32(o0, pc.op_off, 0, cq, true)
        NV_ROWS32(o1, pc.op_off, 16, cq, true)
        if (!oob) {
            const uint ob = (pc.o_off + nr_tile_base(m) + (lane & 15u) * 16u) / 8u;
            nv_a4[ob] = nv_pack_q16(o0, 0);
            nv_a4[ob + 1u] = nv_pack_q16(o0, 8);
            nv_a4[ob + 32u] = nv_pack_q16(o1, 0);
            nv_a4[ob + 33u] = nv_pack_q16(o1, 8);
        }
    }
}
#endif
