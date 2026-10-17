import Foundation

struct NativeDeadlineNotification: Equatable {
    let id: String
    let taskID: String
    let title: String
    let body: String
    let date: Date
}

enum NativeNotificationPlan {
    static func deadlines(tasks: [[String:Any]], settings: [String:Any], now: Date = Date(), calendar: Calendar = .current) -> [NativeDeadlineNotification] {
        guard settings["enabled"] as? Bool != false, settings["deadlines"] as? Bool != false else { return [] }
        let days = Set(settings["deadlineLeadDays"] as? [Int] ?? [3,1]).filter { [1,3,7].contains($0) }
        var result: [NativeDeadlineNotification] = []
        for task in tasks {
            guard task["status"] as? String != "done", let id = task["id"] as? String, let title = task["title"] as? String,
                  let raw = task["dueAt"] as? String, let due = date(raw,calendar:calendar) else { continue }
            for lead in days {
                guard var delivery = calendar.date(byAdding:.day,value:-lead,to:due) else { continue }
                if task["allDay"] as? Bool == true { delivery = calendar.date(bySettingHour:9,minute:0,second:0,of:delivery) ?? delivery }
                guard delivery > now else { continue }
                result.append(.init(id:"bandal.deadline.\(id).\(lead)",taskID:id,title:title,body:"마감까지 \(lead)일 남았습니다.",date:delivery))
            }
        }
        return Array(result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }.prefix(60))
    }
    static func date(_ raw: String, calendar: Calendar = .current) -> Date? {
        if raw.count == 10 {
            let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.calendar = Calendar(identifier:.gregorian); f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
            guard let value = f.date(from:raw), f.string(from:value) == raw else { return nil }; return value
        }
        let f = ISO8601DateFormatter(); if let value = f.date(from:raw) { return value }
        f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.date(from:raw)
    }
}

enum NativeCalendarExport {
    static func data(tasks: [[String:Any]], now: Date = Date()) -> Data {
        let format = DateFormatter(); format.locale = Locale(identifier:"en_US_POSIX"); format.calendar = Calendar(identifier:.gregorian); format.timeZone = TimeZone(secondsFromGMT:0); format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var lines = ["BEGIN:VCALENDAR","VERSION:2.0","PRODID:-//Bandal//Native Calendar//KO","CALSCALE:GREGORIAN"]
        for task in tasks {
            guard let id = task["id"] as? String, let title = task["title"] as? String, let due = task["dueAt"] as? String,
                  let dueDate = NativeNotificationPlan.date(due) else { continue }
            let start = task["startAt"] as? String ?? due
            let startDate = NativeNotificationPlan.date(start) ?? dueDate
            lines += ["BEGIN:VEVENT","UID:\(escape(id))@bandal","DTSTAMP:\(format.string(from:now))","SUMMARY:\(escape(title))"]
            if task["allDay"] as? Bool == true, start.count == 10, due.count == 10 {
                let day = DateFormatter(); day.locale = Locale(identifier:"en_US_POSIX"); day.calendar = Calendar(identifier:.gregorian); day.dateFormat = "yyyyMMdd"
                lines += ["DTSTART;VALUE=DATE:\(start.replacingOccurrences(of:"-",with:""))","DTEND;VALUE=DATE:\(day.string(from:Calendar.current.date(byAdding:.day,value:1,to:dueDate) ?? dueDate))"]
            } else {
                lines += ["DTSTART:\(format.string(from:startDate))","DTEND:\(format.string(from:max(dueDate,startDate.addingTimeInterval(60))))"]
            }
            if let notes = task["notes"] as? String, !notes.isEmpty { lines.append("DESCRIPTION:\(escape(notes))") }
            if task["status"] as? String == "done" { lines.append("STATUS:CONFIRMED") }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return Data((lines.map(fold).joined(separator:"\r\n") + "\r\n").utf8)
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:";",with:"\\;").replacingOccurrences(of:",",with:"\\,")
    }
    private static func fold(_ line: String) -> String {
        var result = "", count = 0
        for scalar in line.unicodeScalars {
            let value = String(scalar), bytes = value.utf8.count
            if count + bytes > 75 { result += "\r\n "; count = 1 }
            result += value; count += bytes
        }
        return result
    }
}
