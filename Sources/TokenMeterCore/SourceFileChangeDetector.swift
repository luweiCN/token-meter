public enum SourceFileChange: Equatable {
    case unchanged
    case appended
    case rewritten
    case moved
}

public enum SourceFileChangeDetector {
    public static func change(previous: SourceFileFingerprint, current: SourceFileFingerprint) -> SourceFileChange {
        if previous == current {
            return .unchanged
        }

        if identityChanged(previous: previous, current: current) {
            if contentLooksMoved(previous: previous, current: current) {
                return .moved
            }
            return .rewritten
        }

        if current.sizeBytes >= previous.sizeBytes,
           previous.tailHash == current.tailHash {
            return .appended
        }

        return .rewritten
    }

    private static func identityChanged(previous: SourceFileFingerprint, current: SourceFileFingerprint) -> Bool {
        previous.dev != current.dev || previous.inode != current.inode
    }

    private static func contentLooksMoved(previous: SourceFileFingerprint, current: SourceFileFingerprint) -> Bool {
        previous.sizeBytes == current.sizeBytes
            && previous.tailHash != nil
            && previous.tailHash == current.tailHash
    }
}
