import Foundation

enum NativeLegacyAudio {
    /// Streams float32 or PCM16 into a derived PCM16 WAV. A stale source header
    /// from an interrupted capture is repaired using its complete frame count.
    static func copy(source: URL, target: URL, context: NativeRepositoryContext) throws -> Int {
        let identity = try NativeRepositoryContext.identity(source)
        let input = try FileHandle(forReadingFrom:source); defer { try? input.close() }
        let header = try input.read(upToCount:44) ?? Data()
        func fail() -> DesktopRuntimeError { DesktopRuntimeError("이전 녹음 형식을 변환하지 못했습니다. 원본은 보존되어 있습니다.",code:"MIGRATION_REQUIRED") }
        guard header.count == 44 else { throw fail() }
        func text(_ offset:Int,_ count:Int) -> String { String(decoding:header[offset..<offset+count],as:UTF8.self) }
        func u16(_ offset:Int) -> UInt16 { UInt16(header[offset]) | UInt16(header[offset+1]) << 8 }
        func u32(_ offset:Int) -> UInt32 { UInt32(header[offset]) | UInt32(header[offset+1]) << 8 | UInt32(header[offset+2]) << 16 | UInt32(header[offset+3]) << 24 }
        guard text(0,4) == "RIFF", text(8,8) == "WAVEfmt ", u32(16) == 16, text(36,4) == "data", u16(22) == 1, u32(24) == 16000 else { throw fail() }
        let float = u16(20) == 3 && u16(34) == 32, pcm = u16(20) == 1 && u16(34) == 16, bytesPerSample = float ? 4 : 2
        let count = try source.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0, payload = count - 44
        guard float || pcm, payload >= 0, payload % bytesPerSample == 0 else { throw fail() }
        let samples = payload / bytesPerSample
        guard UInt64(samples) * 2 <= UInt64(UInt32.max)-36 else { throw fail() }
        try context.files.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".migration-\(UUID().uuidString).wav")
        defer { try? context.files.removeItem(at:temporary) }
        try PCMRecordingWriter.header(samples:UInt64(samples),encoding:.signed16).write(to:temporary,options:.withoutOverwriting)
        let output = try FileHandle(forWritingTo:temporary); defer { try? output.close() }
        try output.seekToEnd()
        var remaining = payload
        while remaining > 0 {
            let length = min(65536,remaining)
            guard let chunk = try input.read(upToCount:length), chunk.count == length else { throw fail() }
            remaining -= length
            if pcm { try output.write(contentsOf:chunk); continue }
            var converted = Data(); converted.reserveCapacity(length/2)
            for offset in stride(from:0,to:chunk.count,by:4) {
                let bits = UInt32(chunk[offset]) | UInt32(chunk[offset+1]) << 8 | UInt32(chunk[offset+2]) << 16 | UInt32(chunk[offset+3]) << 24
                let value = Float(bitPattern:bits); guard value.isFinite else { throw fail() }
                let clamped = min(1,max(-1,Double(value))), scaled = clamped * (clamped < 0 ? 32768 : 32767)
                var sample = Int16(floor(scaled+0.5)).littleEndian
                withUnsafeBytes(of:&sample) { converted.append(contentsOf:$0) }
            }
            try output.write(contentsOf:converted)
        }
        try output.synchronize(); try output.close()
        guard try NativeRepositoryContext.sameIdentity(identity,NativeRepositoryContext.identity(source)) else { throw fail() }
        if context.files.fileExists(atPath:target.path) {
            guard try NativeSyncFormat.hash(target) == NativeSyncFormat.hash(temporary) else { throw fail() }
        } else { try context.files.moveItem(at:temporary,to:target); try context.syncDirectory(target.deletingLastPathComponent()) }
        return samples
    }
}
