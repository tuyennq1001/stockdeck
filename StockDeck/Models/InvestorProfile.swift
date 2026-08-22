import Foundation

/// Khẩu vị rủi ro của nhà đầu tư.
public enum RiskTolerance: String, Codable, CaseIterable, Identifiable {
    case conservative
    case moderate
    case aggressive

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .conservative: return "Thận trọng (Bảo toàn vốn)"
        case .moderate: return "Cân bằng (Tăng trưởng vừa phải)"
        case .aggressive: return "Chấp nhận rủi ro cao (Tối đa tăng trưởng)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .conservative: return "Thận trọng"
        case .moderate: return "Cân bằng"
        case .aggressive: return "Rủi ro cao"
        }
    }

    public var description: String {
        switch self {
        case .conservative: return "Ưu tiên bảo toàn vốn, tài sản an toàn/cổ tức ổn định, hạn chế tối đa rủi ro sụt giảm."
        case .moderate: return "Cân đối giữa cổ phiếu tăng trưởng và tài sản phòng thủ / quỹ chỉ số."
        case .aggressive: return "Sẵn sàng chịu biến động lớn trong ngắn/trung hạn để tối ưu hoá lợi nhuận dài hạn."
        }
    }
}

/// Trường phái / phong cách đầu tư chính.
public enum InvestmentStyle: String, Codable, CaseIterable, Identifiable {
    case dcaBuyAndHold
    case growth
    case dividend
    case trading

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dcaBuyAndHold: return "Tích sản dài hạn (DCA / Buy & Hold)"
        case .growth: return "Cổ phiếu tăng trưởng (Growth)"
        case .dividend: return "Cổ tức & Dòng tiền (Dividend / Cashflow)"
        case .trading: return "Giao dịch linh hoạt / Lướt sóng (Trading)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .dcaBuyAndHold: return "Tích sản DCA"
        case .growth: return "Tăng trưởng"
        case .dividend: return "Cổ tức"
        case .trading: return "Lướt sóng"
        }
    }
}

/// Khung thời gian / kỳ hạn đầu tư.
public enum InvestmentHorizon: String, Codable, CaseIterable, Identifiable {
    case shortTerm
    case mediumTerm
    case longTerm

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .shortTerm: return "Ngắn hạn (< 3 năm)"
        case .mediumTerm: return "Trung hạn (3 - 10 năm)"
        case .longTerm: return "Dài hạn (> 10 năm)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .shortTerm: return "< 3 năm"
        case .mediumTerm: return "3 - 10 năm"
        case .longTerm: return "> 10 năm"
        }
    }
}

/// Hồ sơ cá nhân và mục tiêu đầu tư của người dùng, giúp AI tư vấn chính xác và phù hợp.
public struct InvestorProfile: Codable, Equatable {
    public var age: Int
    public var maritalStatus: String
    public var riskTolerance: RiskTolerance
    public var investmentStyle: InvestmentStyle
    public var investmentHorizon: InvestmentHorizon
    public var primaryGoal: String
    public var monthlyContribution: Double?
    public var customNotes: String
    public var updatedAt: Date

    public init(
        age: Int = 27,
        maritalStatus: String = "Độc thân",
        riskTolerance: RiskTolerance = .aggressive,
        investmentStyle: InvestmentStyle = .dcaBuyAndHold,
        investmentHorizon: InvestmentHorizon = .longTerm,
        primaryGoal: String = "10 năm sau mua nhà và 40 năm sau nghỉ hưu, sẵn sàng chấp nhận rủi ro",
        monthlyContribution: Double? = nil,
        customNotes: String = "",
        updatedAt: Date = Date()
    ) {
        self.age = age
        self.maritalStatus = maritalStatus
        self.riskTolerance = riskTolerance
        self.investmentStyle = investmentStyle
        self.investmentHorizon = investmentHorizon
        self.primaryGoal = primaryGoal
        self.monthlyContribution = monthlyContribution
        self.customNotes = customNotes
        self.updatedAt = updatedAt
    }

    /// Tóm tắt một dòng hiển thị trên badge header.
    public var summaryDescription: String {
        var parts: [String] = []
        if age > 0 { parts.append("\(age) tuổi") }
        if !maritalStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(maritalStatus.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        parts.append(riskTolerance.shortLabel)
        parts.append(investmentStyle.shortLabel)
        return parts.joined(separator: " · ")
    }

    /// Chuỗi văn bản chi tiết dùng để inject vào prompt của AI.
    public func promptContextText(preferredCurrency: String) -> String {
        var lines: [String] = []
        lines.append("INVESTOR PROFILE & GOALS")
        if age > 0 { lines.append("- Age: \(age)") }
        if !maritalStatus.isEmpty { lines.append("- Marital/Family Status: \(maritalStatus)") }
        lines.append("- Risk Tolerance: \(riskTolerance.label) (\(riskTolerance.description))")
        lines.append("- Investment Style: \(investmentStyle.label)")
        lines.append("- Investment Horizon: \(investmentHorizon.label)")
        if !primaryGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("- Stated Primary Goals: \(primaryGoal.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let monthly = monthlyContribution, monthly > 0 {
            lines.append("- Monthly Savings/Contribution: \(String(format: "%.0f", monthly)) \(preferredCurrency)")
        }
        if !customNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("- Additional Constraints / Notes: \(customNotes.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return lines.joined(separator: "\n")
    }
}
