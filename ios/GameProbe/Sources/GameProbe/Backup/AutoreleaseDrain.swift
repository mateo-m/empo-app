import Foundation

/// `FileHandle.readData` and `read(upToCount:)` hand back autoreleased
/// NSData. A long synchronous loop on a cooperative thread never
/// drains the pool, so a 1,4 GB ZIP held 3 GB and jetsam killed Empo.
/// Every chunk loop runs its body inside one pool.
@inline(__always)
func drainingAutoreleased<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
    #else
    try body()
    #endif
}
