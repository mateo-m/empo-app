import Foundation

extension Error {
    /// Whether this is a full disk. FileManager reports
    /// `NSFileWriteOutOfSpaceError`, and libc calls, such as the ones
    /// libarchive makes, report `ENOSPC`.
    public var isOutOfSpace: Bool {
        let error = self as NSError
        switch error.domain {
        case NSCocoaErrorDomain: return error.code == CocoaError.Code.fileWriteOutOfSpace.rawValue
        case NSPOSIXErrorDomain: return error.code == Int(POSIXErrorCode.ENOSPC.rawValue)
        default: return false
        }
    }
}
