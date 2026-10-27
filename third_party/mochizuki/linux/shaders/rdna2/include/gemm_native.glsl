// Native RDNA2 body of the pointwise GEMM (gemm1x1.comp): NR_NATIVE=1 in pipelines.json.
//
// Same bindings, push block, workgroup grid and tile (NR_MTILE tokens x NR_NTILE channels, NR_WAVES waves), the
// same weights (the FP16 twin, N-pair packed), the same epilogues and the same tile-counter wait and signal as the
// emulated kernel; only the inside of the tile changes.
//
//   * A wave owns NR_NG_TW consecutive tokens and 32 x NR_NG_CL channels: lane l the channels 32c + l of its
//     channel group. The tokens are the same for every lane, so an activation row (16 k values of one token, the
//     tile-blocked arena's 32 bytes) is read at a uniform address: s_buffer_load_dwordx4, straight into v_dot2_f32_f16
//     as the scalar operand. A lane reads its own channel's weights (two uvec4 a k fragment, 512 contiguous bytes a
//     wave), one k fragment ahead of the products.
//   * Each output is one FP32 sum over the k pairs in k order through NR_DOT2 from 0, as the emulated NR_MMA chain
//     (coopmm.glsl) forms it, so the accumulator is the emulated one bit for bit, and the epilogue is the emulated
//     one element by element (the QKV norm's FP16 butterfly in the same pairing, across lanes l and l ^ 16 here).
//   * No LDS. The k loop stays rolled (its trip count comes from the push block).
//
// The activations are read through the scalar cache. That is safe here because nothing in this dispatch writes
// them and the RDNA2 host keeps the barriers between dispatches (no tile counters on the FP16 networks unless
// NR_TCHAIN=1, which the RDNA2 host ignores: nr_graph.cpp tchain_active()).
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_ballot : require
#extension GL_KHR_shader_subgroup_shuffle : require
#extension GL_EXT_control_flow_attributes : require

#if !NR_USE_FRAGMENT_EPI || !defined(NR_PACKED_WEIGHT_N2) || !defined(NR_TILED_A) || !defined(NR_A_DIRECT) || \
    !NR_KOFF_SPLIT || NR_ACC_F16 != 0 || NR_POOL || NR_OUT_PERM || NR_OUT_KPAIR || NR_XPIPE || NR_A_LDSV || \
    NR_B_LDSV || NR_A_KPAIR || NR_DIAG_APAIR || NR_KPAIR_ABL || NR_I4_SIDE || defined(NR_I4) || defined(NR_I4_OUT) || \
    defined(NR_EPILOGUE_NVIDIA) || defined(NR_OPERAND_F16) || NR_TC_WG_SIGNAL || NR_ABLATE_LOADS || NR_ABLATE_EPI || \
    (!NR_QKV_FUSED_NORM && !(defined(NR_OUT_E4M3) && defined(NR_OUT_TILED)))
#error "NR_NATIVE: the tiled e4m3 GEMMs (gemmproj, gemmprojc, gemmvact, gemmvqkvnorms) only"
#endif
#ifndef NR_NG_TW
#error "NR_NATIVE: NR_NG_TW (tokens a wave) and NR_NG_CL (channels a lane) come from pipelines.json"
#endif
#ifndef NR_NG_WAVES
#define NR_NG_WAVES NR_WAVES                    // waves a workgroup (gemm1x1.comp's local size)
#endif
#define NG_CW (32 * NR_NG_CL)                   // channels a wave
#define NG_CG (NR_NTILE / NG_CW)                // channel groups in the tile
#if NR_NTILE % NG_CW || NR_MTILE % NR_NG_TW || NG_CG * (NR_MTILE / NR_NG_TW) != NR_NG_WAVES || \
    NR_NG_WAVES < NR_WAVES || (NR_NG_TW < 16 && 16 % NR_NG_TW) || (NR_NG_TW > 16 && NR_NG_TW % 16)
#error "NR_NATIVE: NR_NG_TW x NR_NG_CL must cover the tile with NR_NG_WAVES waves"
#endif
#if NR_QKV_FUSED_NORM && NR_QKV_SOURCE_ORDER
#error "NR_NATIVE: the QKV norm in the default order (NR_QKV_SOURCE_ORDER=0) only"
#endif

// The arena's activations (binding 7) and the weights (binding 3) as uvec4: eight FP16 values.
layout(set = 0, binding = 7, std430) readonly buffer NgAct4 { uvec4 ng_x4[]; };
layout(set = 0, binding = 3, std430) readonly buffer NgWgt4 { uvec4 ng_w4[]; };

f16vec2 ng_h(uint u) { return unpackFloat2x16(u); }
// An FP16 value from lane ^ m (shuffled packed, as the emulated fold does).
float16_t ng_xor(float16_t v, uint m) { return unpackFloat2x16(subgroupShuffleXor(packFloat2x16(f16vec2(v, v)), m)).x; }

// s + the 8 k pairs of one 16-k fragment, pair by pair in k order (NR_DOT2: coopmm.glsl).
float ng_dot8(float s, uvec4 x0, uvec4 x1, uvec4 w0, uvec4 w1) {
    s = NR_DOT2(s, ng_h(x0.x), ng_h(w0.x)); s = NR_DOT2(s, ng_h(x0.y), ng_h(w0.y));
    s = NR_DOT2(s, ng_h(x0.z), ng_h(w0.z)); s = NR_DOT2(s, ng_h(x0.w), ng_h(w0.w));
    s = NR_DOT2(s, ng_h(x1.x), ng_h(w1.x)); s = NR_DOT2(s, ng_h(x1.y), ng_h(w1.y));
    s = NR_DOT2(s, ng_h(x1.z), ng_h(w1.z)); s = NR_DOT2(s, ng_h(x1.w), ng_h(w1.w));
    return s;
}

// One k fragment, written out with literal indices (NR_FOR_*: coopmm.glsl) so every array stays in registers.
// NG_WDST / NG_WSRC name the weight register set; ng_kt is the fragment.
#define NG_WLOAD_C(c) NG_WDST[c][0] = ng_w4[wq[c] + ng_kt * 64u]; NG_WDST[c][1] = ng_w4[wq[c] + ng_kt * 64u + 32u];
#define NG_WLOAD NR_FOR_J(NR_NG_CL, NG_WLOAD_C)
#define NG_XLOAD_T(i) ngx[i][0] = ng_x4[xq[i] + ng_kt * 32u]; ngx[i][1] = ng_x4[xq[i] + ng_kt * 32u + 1u];
#define NG_PROD_C(c) acc[ng_i][c] = ng_dot8(acc[ng_i][c], ngx[ng_i][0], ngx[ng_i][1], NG_WSRC[c][0], NG_WSRC[c][1]);
#define NG_PROD_T(i) { const int ng_i = i; NR_FOR_J(NR_NG_CL, NG_PROD_C) }
#define NG_TILE { uvec4 ngx[NR_NG_TW][2]; NR_FOR_K(NR_NG_TW, NG_XLOAD_T) NR_FOR_K(NR_NG_TW, NG_PROD_T) }

void main() {
    NR_PROF_BEGIN()
    nr_chain_wait()
    NR_TC_PROLOGUE
    const uint lane = gl_SubgroupInvocationID;
    // gl_SubgroupID stays a VGPR on gfx103x; broadcast keeps the wave's token rows scalar.
    const uint wave = subgroupBroadcastFirst(gl_SubgroupID);
#if NR_GEMM_REMAP_PC
    uint nr_gm = gl_WorkGroupID.x, nr_gn = gl_WorkGroupID.y;
    if (pc.remap != 0u) {
        const uint gx = gl_NumWorkGroups.x, gy = gl_NumWorkGroups.y;
        const uint lin = gl_WorkGroupID.x + gx * gl_WorkGroupID.y;
        const uint G = pc.remap;
        const uint grp = lin / (G * gy), bm = grp * G, gt = min(G, gx - bm);
        const uint r = lin - grp * G * gy;
        nr_gm = bm + r % gt; nr_gn = r / gt;
    }
    const uint mg0 = nr_gm * uint(NR_MTILE);
    const uint ng0 = nr_gn * uint(NR_NTILE);
#else
    const uint mg0 = gl_WorkGroupID.x * uint(NR_MTILE);
    const uint ng0 = gl_WorkGroupID.y * uint(NR_NTILE);
#endif
    nr_tchain_wait(mg0 / 16u, NR_MTILE / 16)
    NR_PROF_ITEM_START()

    const uint t0 = mg0 + (wave / uint(NG_CG)) * uint(NR_NG_TW);      // the wave's first token
    const uint nb = ng0 + (wave % uint(NG_CG)) * uint(NG_CW);         // its first channel (a multiple of 32)
    const uint KT = pc.K / 16u;                                        // k fragments

    float acc[NR_NG_TW][NR_NG_CL];
    [[unroll]] for (int i = 0; i < NR_NG_TW; ++i) [[unroll]] for (int c = 0; c < NR_NG_CL; ++c) acc[i][c] = 0.0;

    // The emulated kernel skips the epilogue of a 16-token tile at or past M (and computes it anyway).
    if ((t0 & ~15u) < pc.M) {
        // Weights: channel 32p + l of the N-pair record p, k fragment kt: uvec4 (k 0-7) and +32 (k 8-15).
        uint wq[NR_NG_CL];
        [[unroll]] for (int c = 0; c < NR_NG_CL; ++c)
            wq[c] = pc.w_off / 8u + (nb / 32u + uint(c)) * KT * 64u + (lane & 15u) * 2u + (lane >> 4u);
        // Activations: token t's 16 k values of fragment kt (tile-blocked [t/16][kt] 16x16 FP16 tiles).
        uint xq[NR_NG_TW];
        [[unroll]] for (int i = 0; i < NR_NG_TW; ++i) {
            const uint t = t0 + uint(i);
            xq[i] = pc.x_off / 8u + (t >> 4u) * KT * 32u + (t & 15u) * 2u;
        }
        // Two k fragments an iteration, so the weights of the next fragment load into the other register set
        // (no copies). KT is even for every GEMM of the network (K a multiple of 32).
        uvec4 wa[NR_NG_CL][2], wb[NR_NG_CL][2];
#define NG_WDST wa
        { const uint ng_kt = 0u; NG_WLOAD }
        for (uint kt = 0u; kt < KT; kt = kt + 2u) {
#undef NG_WDST
#define NG_WDST wb
#define NG_WSRC wa
            { const uint ng_kt = kt + 1u; NG_WLOAD }
            { const uint ng_kt = kt; NG_TILE }
#undef NG_WDST
#undef NG_WSRC
#define NG_WDST wa
#define NG_WSRC wb
            { const uint ng_kt = min(kt + 2u, KT - 1u); NG_WLOAD }
            { const uint ng_kt = kt + 1u; NG_TILE }
#undef NG_WSRC
        }
#undef NG_WDST

        // Epilogue, element (token t, channel ch) at tile ((t/16) * N/16 + ch/16), row t % 16, column ch % 16.
        [[unroll]] for (int c = 0; c < NR_NG_CL; ++c) {
            const uint hb = nb + 32u * uint(c);                        // the 32-channel group (a QKV head)
            const uint ch = hb + lane;
#if !NR_QKV_FUSED_NORM && !defined(NR_NO_RESIDUAL)
            const NR_F16 g = wgt_f16[pc.g_off + ch];
#endif
#if NR_QKV_FUSED_NORM
            const NR_F16 scale = NR_F16(qkv_scale[pc.r_off + hb / 32u]);
#endif
            [[unroll]] for (int i = 0; i < NR_NG_TW; ++i) {
                const uint t = t0 + uint(i);
                const uint e = ((t >> 4u) * (pc.N / 16u) + ch / 16u) * 256u + (t & 15u) * 16u + (ch & 15u);
                const float raw = acc[i][c];
#if NR_QKV_FUSED_NORM
                // fragment j (channels hb + n) in lanes n < 16, fragment j + 1 (hb + 16 + n) in lanes 16 + n: the
                // emulated pair sum sx + sy is lane n's square plus lane n + 16's, then the xor 8, 4, 2, 1 folds.
                precise NR_F16 x = NR_F16(raw);
                if (hb < 2048u) {
                    precise NR_F16 sq = x * x;
                    NR_F16 sum = sq + ng_xor(sq, 16u);
                    sum = sum + ng_xor(sum, 8u);
                    sum = sum + ng_xor(sum, 4u);
                    sum = sum + ng_xor(sum, 2u);
                    sum = sum + ng_xor(sum, 1u);
                    const NR_F16 inv = NR_F16(inversesqrt(float(max(sum, NR_F16(0.000062)))));
                    if (hb < 1024u) x = x * NR_F16(sqrt(32.0));
                    x = x * inv;
                    if (hb < 1024u) x = x * scale;
                }
                act_e4m3[pc.o_off + e] = nr_quant_e4m3(x);
#else
#ifdef NR_NO_RESIDUAL
                const NR_F16 v = NR_F16(NR_ACT_APPLY(raw));
#else
                const NR_F16 r = act_e4m3[pc.r_off + e];
                const NR_F16 v = NR_F16(NR_ACT_APPLY(raw + float(g) * float(r)));
#endif
                act_e4m3[pc.o_off + e] = nr_quant_e4m3(v);
#endif
            }
        }
    }
    NR_OCC_USE(pc.K == 0u, act_f32[0] = 0.0)
    nr_chain_signal()
    // Wave w < NR_WAVES signals the token tiles the emulated wave w signals (its NR_MFRAG tiles at row w / NR_WN), so
    // every token tile gets the same count; the barrier puts every wave's stores before any of them.
#if NR_TCHAIN
    if (nr_tc_sig != 0xFFFFFFFFu) {
        memoryBarrier(gl_ScopeDevice, gl_StorageSemanticsBuffer, gl_SemanticsRelease);
        barrier();
    }
#endif
    if (wave < uint(NR_WAVES)) nr_tchain_signal_wave(mg0 / 16u + (wave / uint(NR_WN)) * uint(NR_MFRAG), NR_MFRAG)
    NR_PROF_ITEM_END(pc.o_off | 0x80000000u, 0u)
    NR_PROF_END(pc.o_off)
}
