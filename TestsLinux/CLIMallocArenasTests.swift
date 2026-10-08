import Testing
@testable import CodexBarCLI

struct CLIMallocArenasTests {
    @Test
    func `malloc arena limit applies when glibc is not tuned explicitly`() {
        #expect(CodexBarCLI.glibcMallocArenaLimit(environment: [:]) == CodexBarCLI.defaultGlibcMallocArenaLimit)
        #expect(CodexBarCLI.glibcMallocArenaLimit(environment: ["GLIBC_TUNABLES": "glibc.malloc.tcache_count=0"])
            == CodexBarCLI.defaultGlibcMallocArenaLimit)
    }

    @Test
    func `explicit glibc arena tuning is left alone`() {
        #expect(CodexBarCLI.glibcMallocArenaLimit(environment: ["MALLOC_ARENA_MAX": "8"]) == nil)
        #expect(CodexBarCLI.glibcMallocArenaLimit(environment: ["GLIBC_TUNABLES": "glibc.malloc.arena_max=4"]) == nil)
    }
}
