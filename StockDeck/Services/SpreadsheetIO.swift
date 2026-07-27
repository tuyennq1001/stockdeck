import Foundation
import UniformTypeIdentifiers

enum SpreadsheetIO {

    /// Generates a valid .xlsx file data with sample portfolios and holdings.
    static func generateSampleXLSXData() -> Data? {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """

        let types = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """

        let wb = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Portfolios" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """

        let wbRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """

        let sheet1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1">
              <c r="A1" t="inlineStr"><is><t>Portfolio Name</t></is></c>
              <c r="B1" t="inlineStr"><is><t>Symbol</t></is></c>
              <c r="C1" t="inlineStr"><is><t>Quantity</t></is></c>
              <c r="D1" t="inlineStr"><is><t>Avg Price</t></is></c>
              <c r="E1" t="inlineStr"><is><t>Purchase Date</t></is></c>
              <c r="F1" t="inlineStr"><is><t>Leverage</t></is></c>
            </row>
            <row r="2">
              <c r="A2" t="inlineStr"><is><t>Tech Growth Portfolio</t></is></c>
              <c r="B2" t="inlineStr"><is><t>AAPL</t></is></c>
              <c r="C2"><v>10</v></c>
              <c r="D2"><v>185.50</v></c>
              <c r="E2" t="inlineStr"><is><t>2024-01-15</t></is></c>
              <c r="F2"><v>1.0</v></c>
            </row>
            <row r="3">
              <c r="A3" t="inlineStr"><is><t>Tech Growth Portfolio</t></is></c>
              <c r="B3" t="inlineStr"><is><t>NVDA</t></is></c>
              <c r="C3"><v>5</v></c>
              <c r="D3"><v>120.00</v></c>
              <c r="E3" t="inlineStr"><is><t>2024-03-20</t></is></c>
              <c r="F3"><v>1.0</v></c>
            </row>
            <row r="4">
              <c r="A4" t="inlineStr"><is><t>Crypto Basket</t></is></c>
              <c r="B4" t="inlineStr"><is><t>BTC-USD</t></is></c>
              <c r="C4"><v>0.5</v></c>
              <c r="D4"><v>65000.00</v></c>
              <c r="E4" t="inlineStr"><is><t>2024-02-10</t></is></c>
              <c r="F4"><v>1.0</v></c>
            </row>
          </sheetData>
        </worksheet>
        """

        let relsDir = tmpDir.appendingPathComponent("_rels")
        let xlDir = tmpDir.appendingPathComponent("xl")
        let xlRelsDir = xlDir.appendingPathComponent("_rels")
        let xlWSDir = xlDir.appendingPathComponent("worksheets")

        try? FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: xlRelsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: xlWSDir, withIntermediateDirectories: true)

        try? types.write(to: tmpDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try? rels.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try? wb.write(to: xlDir.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)
        try? wbRels.write(to: xlRelsDir.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8)
        try? sheet1.write(to: xlWSDir.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)

        let outFile = tmpDir.appendingPathComponent("sample.xlsx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", outFile.path, "."]
        process.currentDirectoryURL = tmpDir
        try? process.run()
        process.waitUntilExit()

        return try? Data(contentsOf: outFile)
    }

    /// Parses a file (XLSX, CSV, or JSON) into a list of Portfolio objects.
    static func parsePortfolios(from fileURL: URL) -> [Portfolio]? {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "xlsx" {
            return parseXLSX(fileURL: fileURL)
        } else if ext == "csv" {
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                return parseCSV(content: content)
            }
        }
        return nil
    }

    /// Extracts rows from an .xlsx file sheet XML and sharedStrings.
    static func parseXLSX(fileURL: URL) -> [Portfolio]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", fileURL.path, "xl/worksheets/sheet1.xml"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let xmlString = String(data: data, encoding: .utf8), !xmlString.isEmpty else { return nil }

        // Also fetch sharedStrings if present
        let taskSS = Process()
        taskSS.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        taskSS.arguments = ["-p", fileURL.path, "xl/sharedStrings.xml"]
        let pipeSS = Pipe()
        taskSS.standardOutput = pipeSS
        try? taskSS.run()
        taskSS.waitUntilExit()
        let dataSS = pipeSS.fileHandleForReading.readDataToEndOfFile()
        let sharedStrings = parseSharedStrings(xml: String(data: dataSS, encoding: .utf8) ?? "")

        return parseSheetXML(xml: xmlString, sharedStrings: sharedStrings)
    }

    private static func parseSharedStrings(xml: String) -> [String] {
        var result: [String] = []
        let pattern = "<t[^>]*>(.*?)</t>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let nsString = xml as NSString
        let matches = regex.matches(in: xml, options: [], range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            if match.numberOfRanges > 1 {
                let text = nsString.substring(with: match.range(at: 1))
                result.append(text)
            }
        }
        return result
    }

    private static func parseSheetXML(xml: String, sharedStrings: [String]) -> [Portfolio]? {
        let rowPattern = "<row[^>]*>(.*?)</row>"
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let nsXml = xml as NSString
        let rowMatches = rowRegex.matches(in: xml, options: [], range: NSRange(location: 0, length: nsXml.length))

        var parsedRows: [[String]] = []

        for rowMatch in rowMatches {
            let rowContent = nsXml.substring(with: rowMatch.range(at: 1))
            let cellPattern = "<c r=\"([A-Z]+)[0-9]+\"[^>]*(?:t=\"([^\"]+)\")?[^>]*>(.*?)</c>"
            guard let cellRegex = try? NSRegularExpression(pattern: cellPattern, options: [.dotMatchesLineSeparators]) else { continue }
            let nsRow = rowContent as NSString
            let cellMatches = cellRegex.matches(in: rowContent, options: [], range: NSRange(location: 0, length: nsRow.length))

            var rowValues: [String: String] = [:]
            for cellMatch in cellMatches {
                let colRef = nsRow.substring(with: cellMatch.range(at: 1))
                var type = ""
                if cellMatch.range(at: 2).location != NSNotFound {
                    type = nsRow.substring(with: cellMatch.range(at: 2))
                }
                let body = nsRow.substring(with: cellMatch.range(at: 3))

                var val = ""
                if type == "inlineStr" {
                    let tPattern = "<t[^>]*>(.*?)</t>"
                    if let tRegex = try? NSRegularExpression(pattern: tPattern, options: [.dotMatchesLineSeparators]),
                       let tMatch = tRegex.firstMatch(in: body, options: [], range: NSRange(location: 0, length: (body as NSString).length)) {
                        val = (body as NSString).substring(with: tMatch.range(at: 1))
                    }
                } else if type == "s" {
                    let vPattern = "<v>(.*?)</v>"
                    if let vRegex = try? NSRegularExpression(pattern: vPattern, options: []),
                       let vMatch = vRegex.firstMatch(in: body, options: [], range: NSRange(location: 0, length: (body as NSString).length)) {
                        let idxStr = (body as NSString).substring(with: vMatch.range(at: 1))
                        if let idx = Int(idxStr), idx < sharedStrings.count {
                            val = sharedStrings[idx]
                        }
                    }
                } else {
                    let vPattern = "<v>(.*?)</v>"
                    if let vRegex = try? NSRegularExpression(pattern: vPattern, options: []),
                       let vMatch = vRegex.firstMatch(in: body, options: [], range: NSRange(location: 0, length: (body as NSString).length)) {
                        val = (body as NSString).substring(with: vMatch.range(at: 1))
                    }
                }
                rowValues[colRef] = val
            }

            let cols = ["A", "B", "C", "D", "E", "F"]
            var rowArray: [String] = []
            for col in cols {
                rowArray.append(rowValues[col] ?? "")
            }
            parsedRows.append(rowArray)
        }

        return convertRowsToPortfolios(rows: parsedRows)
    }

    /// Parses CSV content lines.
    static func parseCSV(content: String) -> [Portfolio]? {
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var rows: [[String]] = []
        for line in lines {
            let delimiter: Character = line.contains(";") ? ";" : ","
            let cols = line.split(separator: delimiter, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "") }
            rows.append(cols)
        }
        return convertRowsToPortfolios(rows: rows)
    }

    /// Converts tabular rows into Portfolio models.
    private static func convertRowsToPortfolios(rows: [[String]]) -> [Portfolio]? {
        guard !rows.isEmpty else { return nil }

        var startIdx = 0
        let firstRow = rows[0].map { $0.lowercased() }
        if firstRow.contains(where: { $0.contains("portfolio") || $0.contains("symbol") || $0.contains("quantity") || $0.contains("price") }) {
            startIdx = 1
        }

        var portfolioHoldingsMap: [String: [Holding]] = [:]
        var portfolioOrder: [String] = []

        let dateFormatter = ISO8601DateFormatter()
        let fallbackDateFormatter = DateFormatter()
        fallbackDateFormatter.dateFormat = "yyyy-MM-dd"

        for i in startIdx..<rows.count {
            let r = rows[i]
            guard r.count >= 4 else { continue }
            let pName = r[0].isEmpty ? "Imported Portfolio" : r[0]
            let symbol = r[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !symbol.isEmpty else { continue }

            let qtyStr = r[2].replacingOccurrences(of: ",", with: ".")
            let priceStr = r[3].replacingOccurrences(of: ",", with: ".")

            guard let qty = Double(qtyStr), let price = Double(priceStr), price >= 0 else { continue }

            var pDate: Date? = nil
            if r.count > 4, !r[4].isEmpty {
                pDate = dateFormatter.date(from: r[4]) ?? fallbackDateFormatter.date(from: r[4])
            }

            var lev: Double? = nil
            if r.count > 5, !r[5].isEmpty {
                lev = Double(r[5].replacingOccurrences(of: ",", with: "."))
            }

            let holding = Holding(symbol: symbol, quantity: qty, avgPrice: price, purchaseDate: pDate, leverage: lev)

            if portfolioHoldingsMap[pName] == nil {
                portfolioHoldingsMap[pName] = []
                portfolioOrder.append(pName)
            }
            portfolioHoldingsMap[pName]?.append(holding)
        }

        guard !portfolioOrder.isEmpty else { return nil }

        return portfolioOrder.map { name in
            Portfolio(id: UUID(), name: name, holdings: portfolioHoldingsMap[name] ?? [])
        }
    }
}
