import Foundation

struct CashFlow {
    let date: Date
    let amount: Double
}

enum XIRR {
    /// Solves for the annualized internal rate of return (XIRR) using Actual/365 day count.
    /// Uses Newton-Raphson with a Bisection fallback over [-0.999, 10.0].
    /// Returns nil if flows don't bracket a sign change or no root converges.
    static func rate(_ flows: [CashFlow]) -> Double? {
        guard flows.count >= 2 else { return nil }
        
        let hasPositive = flows.contains { $0.amount > 1e-9 }
        let hasNegative = flows.contains { $0.amount < -1e-9 }
        guard hasPositive && hasNegative else { return nil }
        
        let sortedFlows = flows.sorted { $0.date < $1.date }
        guard let earliestDate = sortedFlows.first?.date, let latestDate = sortedFlows.last?.date else { return nil }
        
        let totalSpanDays = latestDate.timeIntervalSince(earliestDate) / 86400.0
        guard totalSpanDays >= 1.0 else { return nil }
        
        // Calculate years offset t_i for each cash flow relative to earliestDate
        let timedFlows: [(t: Double, amount: Double)] = sortedFlows.map { flow in
            let t = flow.date.timeIntervalSince(earliestDate) / (86400.0 * 365.0)
            return (t: t, amount: flow.amount)
        }
        
        // NPV function
        func npv(_ r: Double) -> Double {
            var sum: Double = 0
            for flow in timedFlows {
                let base = 1.0 + r
                if base <= 0 { return .infinity }
                sum += flow.amount / pow(base, flow.t)
            }
            return sum
        }
        
        // Derivative of NPV function w.r.t r
        func npvPrime(_ r: Double) -> Double {
            var sum: Double = 0
            for flow in timedFlows {
                let base = 1.0 + r
                if base <= 0 { return .infinity }
                sum += (-flow.t * flow.amount) / pow(base, flow.t + 1.0)
            }
            return sum
        }
        
        // Attempt Newton-Raphson iteration
        var r = 0.10 // 10% initial guess
        let maxNewtonIterations = 50
        var newtonSuccess = false
        
        for _ in 0..<maxNewtonIterations {
            let fVal = npv(r)
            if abs(fVal) < 1e-7 {
                newtonSuccess = true
                break
            }
            
            let fPrimeVal = npvPrime(r)
            if abs(fPrimeVal) < 1e-12 || !fPrimeVal.isFinite {
                break
            }
            
            let nextR = r - (fVal / fPrimeVal)
            if !nextR.isFinite || nextR <= -0.999 || nextR > 10.0 {
                break
            }
            
            if abs(nextR - r) < 1e-7 {
                r = nextR
                newtonSuccess = true
                break
            }
            
            r = nextR
        }
        
        if newtonSuccess && r > -0.999 && r < 10.0 {
            return r
        }
        
        // Fallback: Bisection algorithm over [-0.999, 10.0]
        var low = -0.999
        var high = 10.0
        let npvLow = npv(low)
        let npvHigh = npv(high)
        
        guard npvLow.isFinite, npvHigh.isFinite else { return nil }
        guard (npvLow * npvHigh) <= 0 else { return nil }
        
        let maxBisectionIterations = 100
        for _ in 0..<maxBisectionIterations {
            let mid = (low + high) / 2.0
            let npvMid = npv(mid)
            
            if abs(npvMid) < 1e-7 || (high - low) < 1e-6 {
                return mid
            }
            
            if (npvLow * npvMid) <= 0 {
                high = mid
            } else {
                low = mid
            }
        }
        
        return (low + high) / 2.0
    }
}
