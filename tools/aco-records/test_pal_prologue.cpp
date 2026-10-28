// CPU tests of the PAL adapter (nr_pal_binary.hpp), no GPU:
//  1. every record in the given directories parses;
//  2. gfx12: the prologue of every record is byte-identical to the adapter before the gfx11 work (orig/);
//  3. gfx11 and gfx10.3: random argument layouts run through a small SGPR interpreter of the prologue's
//     instructions, starting from PAL's layout, end in exactly the registers ACO's code expects.
//
//   cl /std:c++17 /EHsc /O2 /I<core> /I<orig> test_pal_prologue.cpp && test_pal_prologue <records dir>...
#include "nr_pal_binary.hpp"
#include "nr_pal_binary_orig.hpp"
#include <cstdio>
#include <filesystem>
#include <map>
#include <random>

using nr::pal::Bytes;
static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { ++failures; std::printf("FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

struct Machine {
    bool g10;
    uint32_t s[128] = {};
    std::map<uint64_t, uint32_t> mem;
    uint64_t pc = 0x00007fff12340000ull;
    unsigned m0() const { return g10 ? 124 : 125; }
    // Runs until the branch over the padding; false on an instruction it does not know.
    bool run(const Bytes& code) {
        const uint32_t op_mov = g10 ? 0x03 : 0x00, op_getpc = g10 ? 0x1f : 0x47, null_reg = g10 ? 125 : 124;
        for (size_t p = 0; p + 4 <= code.size();) {
            uint32_t w = nr::pal::read<uint32_t>(code, p);
            if ((w >> 23) == 0x17d) {   // SOP1
                unsigned dst = (w >> 16) & 127, op = (w >> 8) & 255, src = w & 255;
                if (op == op_mov) s[dst] = s[src];
                else if (op == op_getpc) { s[dst] = uint32_t(pc); s[dst + 1] = uint32_t(pc >> 32); }
                else return false;
                p += 4;
            } else if ((w >> 30) == 2 && ((w >> 23) & 127) == 0) {   // SOP2 s_add_u32
                unsigned dst = (w >> 16) & 127, s1 = (w >> 8) & 255, s0 = w & 255;
                uint32_t a = s0 >= 128 && s0 <= 192 ? s0 - 128 : s[s0], b = s1 >= 128 && s1 <= 192 ? s1 - 128 : s[s1];
                s[dst] = a + b;
                p += 4;
            } else if ((w >> 26) == 0x3d) {   // SMEM s_load_b32
                uint32_t w2 = nr::pal::read<uint32_t>(code, p + 4);
                if (((w >> 18) & 255) != 0 || (w2 >> 25) != null_reg) return false;
                unsigned dst = (w >> 6) & 127, base = (w & 63) * 2;
                uint64_t addr = (uint64_t(s[base + 1]) << 32 | s[base]) + (w2 & 0x1fffff);
                if (!mem.count(addr)) return false;
                s[dst] = mem[addr];
                p += 8;
            } else if ((w >> 23) == 0x17f) {   // SOPP
                unsigned op = (w >> 16) & 127;
                const unsigned nop = 0, branch = g10 ? 2 : 0x20, wait = g10 ? 0x0c : 0x09;
                if (op == branch) return true;
                if (op != nop && op != wait) return false;
                p += 4;
            } else return false;
        }
        return false;
    }
};

static void layout_test(bool g10, std::mt19937& rng, int iterations) {
    const uint32_t mach = g10 ? 0x38 : 0x41;
    for (int it = 0; it < iterations; ++it) {
        nr::pal::Record r;
        const bool grid = rng() % 2, push = rng() % 4 == 0;
        unsigned n_inline = rng() % (push ? 6 : 14);
        // ACO's order (RADV): set 0, push pointer, inline push constants, grid size (3 values).
        unsigned reg = 0;
        r.set0 = int(reg++);
        if (push) r.push = int(reg++);
        std::vector<int> dws;
        for (int d = 0; d < 32; ++d) dws.push_back(d);
        std::shuffle(dws.begin(), dws.end(), rng);
        dws.resize(n_inline);
        std::sort(dws.begin(), dws.end());
        for (int d : dws) r.inlines.emplace_back(int(reg++), d);
        if (grid) { r.grid = int(reg); reg += 3; }
        r.user = reg;
        r.push_bytes = 128;
        uint32_t rsrc2 = r.user << 1;
        for (unsigned bit : {7u, 8u, 9u, 10u}) if (rng() % 2) rsrc2 |= 1u << bit;
        if (!g10 && rng() % 3 == 0) { rsrc2 |= 1; r.scratch = 256; }
        r.rsrc2 = rsrc2;
        const unsigned push_bytes = 128, slot = push_bytes / 4 + 1;
        nr::pal::Arguments a(r, slot);
        Bytes pro;
        try { pro = nr::pal::prologue(r, slot, mach); }
        catch (const std::exception& e) { CHECK(false, "prologue threw %s", e.what()); continue; }
        Machine m{g10};
        // PAL's side: user data entries by a.map, the spill table in memory, system SGPRs after a.user.
        const uint64_t spill = (m.pc & 0xffffffff00000000ull) | 0x00100000, gridp = 0x0000123400200000ull;
        auto entry = [&](unsigned e) { return 0xA0000000u + e; };   // user-data entry e's value
        for (unsigned e = 0; e < 64; ++e) m.mem[spill + 4 * e] = entry(e);
        for (unsigned j = 0; j < 3; ++j) m.mem[gridp + 4 * j] = 0xC0000000u + j;
        for (unsigned i = 0; i < 32; ++i) {
            uint64_t v = a.map[i];
            if (v == 0xffffffff) continue;
            if (v == 0x10000000) m.s[i] = 0x11111111;
            else if (v == 0x10000002) m.s[i] = uint32_t(spill);
            else if (v == 0x10000006) { m.s[i] = uint32_t(gridp); m.s[i + 1] = uint32_t(gridp >> 32); }
            else m.s[i] = entry(unsigned(v));
        }
        std::vector<uint32_t> sysv;
        unsigned k = 0;
        for (unsigned bit : {7u, 8u, 9u, 10u, 0u})
            if (rsrc2 & (1u << bit)) { m.s[a.user + k] = 0xD0000000u + bit; sysv.push_back(0xD0000000u + bit); ++k; }
        CHECK(m.run(pro), "%s: the prologue ran into an unknown instruction", g10 ? "gfx10.3" : "gfx11");
        CHECK(pro.size() % 256 == 0, "prologue not 256-byte aligned");
        // ACO's side.
        CHECK(m.s[r.set0] == entry(slot), "set0");
        for (auto [rg, dw] : r.inlines) CHECK(m.s[rg] == entry(dw + 1), "inline s%d = dw %d (got %08x)", rg, dw, m.s[rg]);
        if (r.push >= 0) CHECK(m.s[r.push] == uint32_t(spill) + 4, "push pointer");
        if (r.grid >= 0) for (unsigned j = 0; j < 3; ++j) CHECK(m.s[r.grid + j] == 0xC0000000u + j, "grid %u", j);
        for (unsigned i = 0; i < sysv.size(); ++i)
            CHECK(m.s[r.user + i] == sysv[i], "%s system SGPR %u (record user %u, PAL user %u): %08x",
                  g10 ? "gfx10.3" : "gfx11", i, r.user, a.user, m.s[r.user + i]);
        CHECK(m.s[m.m0()] == uint32_t(m.pc >> 32), "m0 = address32 high");
    }
}

int main(int argc, char** argv) {
    unsigned parsed = 0, gfx12 = 0;
    for (int i = 1; i < argc; ++i)
        for (const auto& f : std::filesystem::directory_iterator(argv[i])) {
            if (f.path().extension() != ".nrp") continue;
            const Bytes b = nr::pal::load(f.path().string());
            try {
                auto r = nr::pal::Record::parse(b);
                ++parsed;
                if (!r.mach) {
                    auto o = nr_orig::pal::Record::parse(b);
                    CHECK(nr::pal::prologue(r, 33) == nr_orig::pal::prologue(o, 33) &&
                          nr::pal::prologue(r, 33, 0x48) == nr_orig::pal::prologue(o, 33),
                          "gfx12 prologue changed: %s", f.path().string().c_str());
                    ++gfx12;
                }
            } catch (const std::exception& e) {
                CHECK(false, "%s: %s", f.path().string().c_str(), e.what());
            }
        }
    std::mt19937 rng(1234);
    layout_test(false, rng, 20000);
    layout_test(true, rng, 20000);
    std::printf("%u records parsed (%u gfx12 with an identical prologue), 40000 layouts, %d failures\n", parsed, gfx12,
                failures);
    return failures ? 1 : 0;
}
