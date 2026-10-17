import Foundation

enum NativeSettingsUsageRepository {
    static func summary(context: NativeRepositoryContext, request: [String:Any]) throws -> [String:Any] {
        let days = try NativeValue.int(request["windowDays"] ?? 30,"기간",min:0,max:36500)
        let from = days == 0 ? "" : ISO8601DateFormatter().string(from:Date().addingTimeInterval(-Double(days)*86400))
        let rows = try context.db.query("SELECT provider,COUNT(DISTINCT session_id) AS sessions,SUM(input_tokens) AS inputTokens,SUM(output_tokens) AS outputTokens,SUM(duration_ms)/1000.0 AS durationSeconds FROM agent_usage WHERE turn_at >= ? GROUP BY provider ORDER BY provider",params:[from])
        let totals = try context.db.query("SELECT COUNT(DISTINCT session_id) AS sessions,SUM(input_tokens) AS inputTokens,SUM(output_tokens) AS outputTokens,SUM(duration_ms)/1000.0 AS durationSeconds FROM agent_usage WHERE turn_at >= ?",params:[from]).first ?? [:]
        let all = try context.db.query("SELECT COUNT(*) AS sessions FROM agent_sessions WHERE deleted_at IS NULL AND COALESCE(last_used_at,created_at) >= ?",params:[from]).first?["sessions"] ?? 0
        return ["sessions":all,"measuredSessions":totals["sessions"] ?? 0,"inputTokens":totals["inputTokens"] ?? NSNull(),"outputTokens":totals["outputTokens"] ?? NSNull(),"durationSeconds":totals["durationSeconds"] ?? NSNull(),"providers":rows]
    }
}
