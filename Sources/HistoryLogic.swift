import Foundation

enum HistoryLogic {
    static func dayString(_ date: Date) -> String {
        dayFormatter().string(from: date)
    }

    static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    static func updatedDayLog(
        _ log: [String: Int],
        today: String,
        setsToday: Int,
        keepDays: Int = 30
    ) -> [String: Int] {
        var result = log
        result[today] = setsToday
        let formatter = dayFormatter()
        guard let todayDate = formatter.date(from: today),
              let cutoff = Calendar.current.date(
                  byAdding: .day,
                  value: -(keepDays - 1),
                  to: todayDate
              )
        else { return result }
        let cutoffKey = formatter.string(from: cutoff)
        return result.filter { $0.key >= cutoffKey }
    }
}
