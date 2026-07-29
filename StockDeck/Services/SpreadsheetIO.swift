import Foundation
import UniformTypeIdentifiers

enum SpreadsheetIO {

    /// Generates generic .xlsx file data given headers and string rows.
    static func generateXLSXData(headers: [String], rows: [[String]]) -> Data? {
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
            <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """

        let wbRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """

        var sheetDataXML = "  <sheetData>\n"
        sheetDataXML += "    <row r=\"1\">\n"
        for (cIdx, header) in headers.enumerated() {
            let colLetter = columnLetter(cIdx + 1)
            let escaped = escapeXML(header)
            sheetDataXML += "      <c r=\"\(colLetter)1\" t=\"inlineStr\"><is><t>\(escaped)</t></is></c>\n"
        }
        sheetDataXML += "    </row>\n"

        for (rIdx, row) in rows.enumerated() {
            let rowNum = rIdx + 2
            sheetDataXML += "    <row r=\"\(rowNum)\">\n"
            for (cIdx, val) in row.enumerated() {
                let colLetter = columnLetter(cIdx + 1)
                let escaped = escapeXML(val)
                if let num = Double(val), !val.contains("-") && val != num.description {
                    sheetDataXML += "      <c r=\"\(colLetter)\(rowNum)\"><v>\(num)</v></c>\n"
                } else if let num = Double(val) {
                    sheetDataXML += "      <c r=\"\(colLetter)\(rowNum)\"><v>\(num)</v></c>\n"
                } else {
                    sheetDataXML += "      <c r=\"\(colLetter)\(rowNum)\" t=\"inlineStr\"><is><t>\(escaped)</t></is></c>\n"
                }
            }
            sheetDataXML += "    </row>\n"
        }
        sheetDataXML += "  </sheetData>"

        let sheet1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \(sheetDataXML)
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

        let outFile = tmpDir.appendingPathComponent("export.xlsx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", outFile.path, "."]
        process.currentDirectoryURL = tmpDir
        try? process.run()
        process.waitUntilExit()

        return try? Data(contentsOf: outFile)
    }

    private static func columnLetter(_ index: Int) -> String {
        var n = index
        var result = ""
        while n > 0 {
            let rem = (n - 1) % 26
            result = String(UnicodeScalar(65 + rem)!) + result
            n = (n - 1) / 26
        }
        return result
    }

    private static func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Generates .xlsx file data for portfolios.
    static func generatePortfoliosXLSXData(_ portfolios: [Portfolio]) -> Data? {
        let headers = ["Portfolio Name", "Symbol", "Quantity", "Avg Price", "Purchase Date", "Leverage"]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var rows: [[String]] = []
        for p in portfolios {
            for h in p.holdings {
                let dateStr = h.purchaseDate.map { df.string(from: $0) } ?? ""
                rows.append([p.name, h.symbol, String(h.quantity), String(h.avgPrice), dateStr, String(h.effectiveLeverage)])
            }
        }
        return generateXLSXData(headers: headers, rows: rows)
    }

    /// Generates .xlsx file data for watchlists.
    @MainActor
    static func generateWatchlistsXLSXData(watchlists: [Watchlist], stockService: StockService) -> Data? {
        let headers = ["Watchlist Name", "Symbol", "Name", "Price", "Change", "Change %"]
        var rows: [[String]] = []
        for wl in watchlists {
            for sym in wl.symbols {
                let q = stockService.quotes[sym]
                rows.append([
                    wl.name,
                    sym,
                    q?.name ?? "",
                    q.map { String($0.price) } ?? "",
                    q.map { String($0.change) } ?? "",
                    q.map { String(format: "%.2f", $0.changePercent) } ?? ""
                ])
            }
        }
        return generateXLSXData(headers: headers, rows: rows)
    }

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

    /// Generates .xlsx file data with sample 投資信託 (Japanese mutual fund) trade history using standard English headers.
    static func generateJapaneseFundTemplateXLSXData() -> Data? {
        let headers = ["Portfolio Name", "Symbol", "Quantity", "Avg Price", "Purchase Date"]
        let rows: [[String]] = [
            ["NISA Portfolio", "eMAXIS Slim 米国株式(S&P500)", "32432", "30834", "2024-01-30"],
            ["NISA Portfolio", "iFreeNEXT NASDAQ100インデックス", "15884", "31478", "2024-03-11"],
            ["NISA Portfolio", "楽天・Ｓ＆Ｐ５００インデックス・ファンド", "74025", "13509", "2024-06-11"],
            ["Taxable Portfolio", "auAM Nifty50インド株ファンド", "81633", "12250", "2024-11-14"]
        ]
        return generateXLSXData(headers: headers, rows: rows)
    }

    /// Generates a sample Watchlist Excel (.xlsx) file data.
    static func generateWatchlistSampleXLSXData() -> Data? {
        let headers = ["Watchlist Name", "Symbol", "Notes"]
        let rows: [[String]] = [
            ["Tech Watchlist", "AAPL", "Apple Inc."],
            ["Tech Watchlist", "NVDA", "NVIDIA Corporation"],
            ["Tech Watchlist", "MSFT", "Microsoft Corporation"],
            ["Global Indices", "^GSPC", "S&P 500"],
            ["Japanese Funds", "eMAXIS Slim 米国株式(S&P500)", "03311187"]
        ]
        return generateXLSXData(headers: headers, rows: rows)
    }

    /// Parses a file (CSV or XLSX) into a list of (watchlistName, symbols).
    static func parseWatchlistFile(from fileURL: URL) -> (name: String, symbols: [String])? {
        let ext = fileURL.pathExtension.lowercased()
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        var symbols: [String] = []
        var wlName = fileName.isEmpty ? "Imported Watchlist" : fileName

        var rows: [[String]] = []

        if ext == "xlsx" {
            if let parsed = parseXLSXRows(fileURL: fileURL) {
                rows = parsed
            }
        } else {
            if let content = readTextFile(url: fileURL) {
                let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for line in lines {
                    let delimiter: Character = line.contains(";") ? ";" : (line.contains("\t") ? "\t" : ",")
                    let cols = splitCSVLine(line, delimiter: delimiter)
                    rows.append(cols)
                }
            }
        }

        guard !rows.isEmpty else { return nil }

        var startIdx = 0
        var symbolCol = 0
        var nameCol = -1

        for (cIdx, col) in rows[0].enumerated() {
            let lower = col.lowercased()
            if lower.contains("symbol") || lower.contains("ticker") || lower.contains("銘柄") || lower == "code" {
                symbolCol = cIdx
                startIdx = 1
            }
            if lower.contains("watchlist") || (lower.contains("name") && !lower.contains("symbol")) {
                nameCol = cIdx
            }
        }

        for idx in startIdx..<rows.count {
            let row = rows[idx]
            guard symbolCol < row.count else { continue }
            let sym = row[symbolCol].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sym.isEmpty && sym.lowercased() != "symbol" {
                symbols.append(sym)
                if nameCol >= 0 && nameCol < row.count {
                    let candidateName = row[nameCol].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidateName.isEmpty && candidateName.lowercased() != "watchlist name" {
                        wlName = candidateName
                    }
                }
            }
        }

        guard !symbols.isEmpty else { return nil }
        return (wlName, symbols)
    }

    /// Option 1: Standard symbol/portfolio file import (XLSX, CSV, JSON).
    static func parseStandardPortfolios(from fileURL: URL) -> [Portfolio]? {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "xlsx" {
            return parseXLSX(fileURL: fileURL)
        } else if ext == "csv" {
            guard let content = readTextFile(url: fileURL) else { return nil }
            return parseStandardCSV(content: content)
        }
        return nil
    }

    /// Option 2: 投資信託 (Japanese Funds Trade History CSV/XLSX) import.
    static func parseJapaneseFundCSV(from fileURL: URL) -> [Portfolio]? {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "xlsx" {
            if let rows = parseXLSXRows(fileURL: fileURL), !rows.isEmpty {
                return parseJapaneseBrokerCSV(rows: rows)
            }
            return nil
        }
        guard let content = readTextFile(url: fileURL) else { return nil }
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var rows: [[String]] = []
        for line in lines {
            let delimiter: Character = line.contains(";") ? ";" : (line.contains("\t") ? "\t" : ",")
            let cols = splitCSVLine(line, delimiter: delimiter)
            rows.append(cols)
        }
        return parseJapaneseBrokerCSV(rows: rows)
    }

    /// Helper to read text files with fallback encodings (UTF-8, Shift-JIS, DOS Japanese).
    static func readTextFile(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let str = String(data: data, encoding: .utf8), !str.contains("") {
            return str
        }
        if let str = String(data: data, encoding: .shiftJIS), !str.contains("") {
            return str
        }
        let cfEncoding = CFStringEncodings.dosJapanese.rawValue
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding))
        if let str = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)), !str.contains("") {
            return str
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
    }

    /// Parses CSV content lines for standard symbol format.
    static func parseStandardCSV(content: String) -> [Portfolio]? {
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var rows: [[String]] = []
        for line in lines {
            let delimiter: Character = line.contains(";") ? ";" : (line.contains("\t") ? "\t" : ",")
            let cols = splitCSVLine(line, delimiter: delimiter)
            rows.append(cols)
        }
        return convertRowsToPortfolios(rows: rows)
    }

    /// Parses a file (XLSX, CSV, or JSON) into a list of Portfolio objects.
    static func parsePortfolios(from fileURL: URL) -> [Portfolio]? {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "xlsx" {
            return parseXLSX(fileURL: fileURL)
        } else if ext == "csv" {
            if let content = readTextFile(url: fileURL) {
                return parseCSV(content: content)
            }
        }
        return nil
    }

    /// Extracts raw string rows from an .xlsx file sheet XML using Python with fallback to Swift.
    static func parseXLSXRows(fileURL: URL) -> [[String]]? {
        if let rows = parseXLSXWithPython(fileURL: fileURL), !rows.isEmpty {
            return rows
        }
        return parseXLSXRowsWithSwift(fileURL: fileURL)
    }

    /// Extracts portfolios from an .xlsx file for standard portfolio import.
    static func parseXLSX(fileURL: URL) -> [Portfolio]? {
        guard let rows = parseXLSXRows(fileURL: fileURL), !rows.isEmpty else { return nil }
        return convertRowsToPortfolios(rows: rows)
    }

    private static func parseXLSXWithPython(fileURL: URL) -> [[String]]? {
        let script = """
        import zipfile, xml.etree.ElementTree as ET, json, sys

        def clean_tag(elem):
            return elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag

        def parse(file_path):
            with zipfile.ZipFile(file_path, "r") as z:
                shared_strings = []
                if "xl/sharedStrings.xml" in z.namelist():
                    ss_tree = ET.fromstring(z.read("xl/sharedStrings.xml"))
                    for elem in ss_tree.iter():
                        if clean_tag(elem) == "si":
                            t_texts = [e.text or "" for e in elem.iter() if clean_tag(e) == "t"]
                            shared_strings.append("".join(t_texts))

                sheets = [n for n in z.namelist() if n.startswith("xl/worksheets/sheet") and n.endswith(".xml")]
                if not sheets: return []
                sheet_tree = ET.fromstring(z.read(sheets[0]))
                rows = []
                for row in sheet_tree.iter():
                    if clean_tag(row) != "row":
                        continue
                    row_dict = {}
                    for c in row:
                        if clean_tag(c) != "c":
                            continue
                        r_ref = c.attrib.get("r", "")
                        col_letter = "".join([ch for ch in r_ref if ch.isalpha()])
                        t_type = c.attrib.get("t", "")
                        
                        val = ""
                        if t_type == "s":
                            for child in c:
                                if clean_tag(child) == "v" and child.text:
                                    try:
                                        idx = int(child.text)
                                        if idx < len(shared_strings):
                                            val = shared_strings[idx]
                                    except: pass
                        elif t_type == "inlineStr":
                            for child in c.iter():
                                if clean_tag(child) == "t" and child.text:
                                    val = child.text
                        else:
                            for child in c:
                                if clean_tag(child) == "v" and child.text:
                                    val = child.text
                        if col_letter:
                            row_dict[col_letter] = val
                    
                    max_c = 6
                    for k in row_dict.keys():
                        n = 0
                        for ch in k:
                            if 'A' <= ch <= 'Z':
                                n = n * 26 + (ord(ch) - ord('A') + 1)
                        if n > max_c: max_c = n
                    cols = []
                    for idx in range(1, max_c + 1):
                        temp = idx
                        letters = ""
                        while temp > 0:
                            rem = (temp - 1) % 26
                            letters = chr(65 + rem) + letters
                            temp = (temp - 1) // 26
                        cols.append(letters)
                    r_vals = [row_dict.get(col, "") for col in cols]
                    if any(r_vals):
                        rows.append(r_vals)
                return rows

        print(json.dumps(parse(sys.argv[1])))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, fileURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let jsonRows = try? JSONDecoder().decode([[String]].self, from: data) else { return nil }
        return jsonRows
    }

    private static func parseXLSXRowsWithSwift(fileURL: URL) -> [[String]]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", fileURL.path, "xl/worksheets/sheet1.xml"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let xmlString = String(data: data, encoding: .utf8), !xmlString.isEmpty else { return nil }

        let taskSS = Process()
        taskSS.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        taskSS.arguments = ["-p", fileURL.path, "xl/sharedStrings.xml"]
        let pipeSS = Pipe()
        taskSS.standardOutput = pipeSS
        try? taskSS.run()
        taskSS.waitUntilExit()
        let dataSS = pipeSS.fileHandleForReading.readDataToEndOfFile()
        let sharedStrings = parseSharedStringsSwift(xml: String(data: dataSS, encoding: .utf8) ?? "")

        return parseSheetXMLSwift(xml: xmlString, sharedStrings: sharedStrings)
    }

    private static func parseXLSXWithSwift(fileURL: URL) -> [Portfolio]? {
        guard let rows = parseXLSXRowsWithSwift(fileURL: fileURL), !rows.isEmpty else { return nil }
        if let jpPortfolios = parseJapaneseBrokerCSV(rows: rows), !jpPortfolios.isEmpty {
            return jpPortfolios
        }
        return convertRowsToPortfolios(rows: rows)
    }

    private static func parseSharedStringsSwift(xml: String) -> [String] {
        var result: [String] = []
        let siPattern = "<si>(.*?)</si>"
        guard let siRegex = try? NSRegularExpression(pattern: siPattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let nsString = xml as NSString
        let matches = siRegex.matches(in: xml, options: [], range: NSRange(location: 0, length: nsString.length))

        let tRegex = try? NSRegularExpression(pattern: "<t[^>]*>(.*?)</t>", options: [.dotMatchesLineSeparators])

        for match in matches {
            let siContent = nsString.substring(with: match.range(at: 1))
            let nsSi = siContent as NSString
            let tMatches = tRegex?.matches(in: siContent, options: [], range: NSRange(location: 0, length: nsSi.length)) ?? []
            var fullText = ""
            for tMatch in tMatches {
                if tMatch.numberOfRanges > 1 {
                    fullText += nsSi.substring(with: tMatch.range(at: 1))
                }
            }
            result.append(fullText)
        }
        return result
    }

    private static func parseSheetXMLSwift(xml: String, sharedStrings: [String]) -> [[String]]? {
        let rowPattern = "<row[^>]*>(.*?)</row>"
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let nsXml = xml as NSString
        let rowMatches = rowRegex.matches(in: xml, options: [], range: NSRange(location: 0, length: nsXml.length))

        var parsedRows: [[String]] = []

        for rowMatch in rowMatches {
            let rowContent = nsXml.substring(with: rowMatch.range(at: 1))
            let cellPattern = "<c[^>]*>(.*?)</c>"
            guard let cellRegex = try? NSRegularExpression(pattern: cellPattern, options: [.dotMatchesLineSeparators]) else { continue }
            let nsRow = rowContent as NSString
            let cellMatches = cellRegex.matches(in: rowContent, options: [], range: NSRange(location: 0, length: nsRow.length))

            var rowValues: [String: String] = [:]
            for cellMatch in cellMatches {
                let cellFull = nsRow.substring(with: cellMatch.range(at: 0))
                
                // Get column letter from r="..."
                var colRef = ""
                if let rMatch = try? NSRegularExpression(pattern: "r=\"([A-Z]+)[0-9]+\"").firstMatch(in: cellFull, options: [], range: NSRange(location: 0, length: cellFull.utf16.count)),
                   rMatch.numberOfRanges > 1 {
                    colRef = (cellFull as NSString).substring(with: rMatch.range(at: 1))
                }
                guard !colRef.isEmpty else { continue }

                var type = ""
                if let tMatch = try? NSRegularExpression(pattern: "t=\"([^\"]+)\"").firstMatch(in: cellFull, options: [], range: NSRange(location: 0, length: cellFull.utf16.count)),
                   tMatch.numberOfRanges > 1 {
                    type = (cellFull as NSString).substring(with: tMatch.range(at: 1))
                }

                let body = nsRow.substring(with: cellMatch.range(at: 1))

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

            var maxColIdx = 6
            for colRef in rowValues.keys {
                var n = 0
                for ch in colRef.unicodeScalars {
                    if ch.value >= 65 && ch.value <= 90 {
                        n = n * 26 + Int(ch.value - 65 + 1)
                    }
                }
                if n > maxColIdx { maxColIdx = n }
            }

            var rowArray: [String] = []
            for cIdx in 1...maxColIdx {
                let colLetter = columnLetter(cIdx)
                rowArray.append(rowValues[colLetter] ?? "")
            }
            parsedRows.append(rowArray)
        }

        return parsedRows.isEmpty ? nil : parsedRows
    }

    /// Parses CSV content lines.
    static func parseCSV(content: String) -> [Portfolio]? {
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var rows: [[String]] = []
        for line in lines {
            let delimiter: Character = line.contains(";") ? ";" : (line.contains("\t") ? "\t" : ",")
            let cols = splitCSVLine(line, delimiter: delimiter)
            rows.append(cols)
        }

        let isJapaneseBrokerFile = content.contains("ファンド") || content.contains("銘柄") || content.contains("約定日") || content.contains("受渡日")
        if isJapaneseBrokerFile, let jpPortfolios = parseJapaneseBrokerCSV(rows: rows), !jpPortfolios.isEmpty {
            return jpPortfolios
        }

        return convertRowsToPortfolios(rows: rows)
    }

    private static func splitCSVLine(_ line: String, delimiter: Character = ",") -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == delimiter && !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result.map { $0.replacingOccurrences(of: "\"", with: "") }
    }

    static let japaneseFundNameToCodeMap: [String: String] = [
        "楽天・プラス・Ｓ＆Ｐ５０0インデックス・ファンド": "9I31223A",
        "楽天・プラス・Ｓ＆Ｐ５００インデックス・ファンド": "9I31223A",
        "楽天・プラス・S&P500インデックス・ファンド": "9I31223A",
        "楽天・プラス・Ｓ＆Ｐ５００": "9I31223A",
        "楽天・プラス・S&P500": "9I31223A",
        "楽天・Ｓ＆Ｐ５００インデックス・ファンド": "9I31223A",
        "楽天・Ｓ＆Ｐ５00インデックス・ファンド": "9I31223A",
        "楽天・Ｓ＆Ｐ５００": "9I31223A",
        "楽天・S&P500": "9I31223A",
        "eMAXIS Slim米国株式(S&P500)": "03311187",
        "eMAXIS Slim 米国株式(S&P500)": "03311187",
        "iFreeNEXT NASDAQ100インデックス": "04317188",
        "iFreeNEXT NASDAQ100": "04317188",
        "auAM Nifty50インド株ファンド": "AY311238",
        "auAM Nifty50": "AY311238",
        "eMAXIS Slim 全世界株式(オール・カントリー)": "0331418A",
        "eMAXIS Slim全世界株式(オール・カントリー)": "0331418A",
        "eMAXIS Slimオルカン": "0331418A",
        "楽天・プラス・オールカントリー・インデックス・ファンド": "9I31123A",
        "楽天・プラス・オールカントリー": "9I31123A",
        "楽天・全米株式インデックス・ファンド": "9I312179",
        "eMAXIS Slim 国内リートインデックス": "0331119A"
    ]

    static func parseJapaneseBrokerCSV(rows: [[String]]) -> [Portfolio]? {
        guard !rows.isEmpty else { return nil }

        var headerIdx = -1
        var fundCol = -1, tradeCol = -1, qtyCol = -1, priceCol = -1, accountCol = -1, dateCol = -1

        for (idx, r) in rows.enumerated() {
            for (cIdx, cell) in r.enumerated() {
                let lowerCell = cell.lowercased()
                if lowerCell.contains("ファンド") || lowerCell.contains("銘柄") || lowerCell == "symbol" || lowerCell.contains("fund") { fundCol = cIdx }
                if lowerCell.contains("取引") || lowerCell.contains("売買") || lowerCell.contains("trade") || lowerCell.contains("type") { tradeCol = cIdx }
                if lowerCell.contains("数量") || lowerCell.contains("quantity") || lowerCell.contains("qty") || lowerCell.contains("units") { qtyCol = cIdx }
                if lowerCell.contains("単価") || lowerCell.contains("avg price") || lowerCell.contains("unit price") || lowerCell.contains("price") { priceCol = cIdx }
                if lowerCell.contains("口座") || lowerCell.contains("portfolio") || lowerCell.contains("account") { accountCol = cIdx }
                if lowerCell.contains("約定日") || lowerCell.contains("日付") || lowerCell.contains("purchase date") || lowerCell.contains("date") { dateCol = cIdx }
            }
            if fundCol != -1 && (qtyCol != -1 || priceCol != -1) {
                headerIdx = idx
                break
            }
        }

        guard headerIdx != -1 && fundCol != -1 else { return nil }

        struct TradeRecord {
            let account: String
            let fundName: String
            let symbol: String
            let isBuy: Bool
            let qty: Double
            let unitPrice: Double
            let date: Date?
        }

        var records: [TradeRecord] = []

        for i in (headerIdx + 1)..<rows.count {
            let r = rows[i]
            guard r.count > fundCol else { continue }

            let rawFundName = r[fundCol].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawFundName.isEmpty else { continue }

            let cleanFundName = rawFundName.components(separatedBy: "(")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let code = resolveJapaneseFundCode(from: rawFundName)
            let symbol = code ?? cleanFundName

            let tradeType = tradeCol != -1 && r.count > tradeCol ? r[tradeCol].lowercased() : "買付"
            let isBuy = tradeType.contains("買") || tradeType.contains("積立") || tradeType.contains("buy") || tradeType.contains("purchase") || tradeType.isEmpty || tradeType == "買付"

            let qtyStr = qtyCol != -1 && r.count > qtyCol ? r[qtyCol].replacingOccurrences(of: ",", with: "") : "0"
            let qty = Double(qtyStr) ?? 0.0

            let priceStr = priceCol != -1 && r.count > priceCol ? r[priceCol].replacingOccurrences(of: ",", with: "") : "0"
            let price = Double(priceStr) ?? 0.0

            let account = accountCol != -1 && r.count > accountCol && !r[accountCol].isEmpty ? r[accountCol] : "NISA / 投資信託"

            var pDate: Date? = nil
            if dateCol != -1 && r.count > dateCol {
                pDate = parseDate(r[dateCol])
            }

            if qty > 0 {
                records.append(TradeRecord(account: account, fundName: cleanFundName, symbol: symbol, isBuy: isBuy, qty: qty, unitPrice: price, date: pDate))
            }
        }

        struct PositionLot {
            let symbol: String
            var qty: Double
            let unitPrice: Double
            let date: Date?
        }

        var accountLotsMap: [String: [PositionLot]] = [:]

        for rec in records {
            var lots = accountLotsMap[rec.account] ?? []

            if rec.isBuy {
                lots.append(PositionLot(symbol: rec.symbol, qty: rec.qty, unitPrice: rec.unitPrice, date: rec.date))
            } else {
                // FIFO deduct from existing lots for this symbol
                var remainingToSell = rec.qty
                var updatedLots: [PositionLot] = []
                for var lot in lots {
                    if lot.symbol == rec.symbol && remainingToSell > 0 {
                        if lot.qty <= remainingToSell {
                            remainingToSell -= lot.qty
                            lot.qty = 0
                        } else {
                            lot.qty -= remainingToSell
                            remainingToSell = 0
                            updatedLots.append(lot)
                        }
                    } else {
                        updatedLots.append(lot)
                    }
                }
                lots = updatedLots.filter { $0.qty > 0 }
            }

            accountLotsMap[rec.account] = lots
        }

        var resultPortfolios: [Portfolio] = []

        for (accountName, lots) in accountLotsMap {
            let activeHoldings = lots.filter { $0.qty > 0 }.map { lot in
                Holding(symbol: lot.symbol, quantity: lot.qty, avgPrice: lot.unitPrice, purchaseDate: lot.date)
            }
            if !activeHoldings.isEmpty {
                resultPortfolios.append(Portfolio(id: UUID(), name: accountName, holdings: activeHoldings))
            }
        }

        return resultPortfolios.isEmpty ? nil : resultPortfolios
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

        for i in startIdx..<rows.count {
            let r = rows[i]
            guard r.count >= 4 else { continue }
            let pName = r[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Portfolio" : r[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let symbol = r[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !symbol.isEmpty else { continue }

            let qtyStr = r[2].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
            let priceStr = r[3].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)

            guard let qty = Double(qtyStr), let price = Double(priceStr), price >= 0 else { continue }

            var pDate: Date? = nil
            if r.count > 4, !r[4].isEmpty {
                pDate = parseDate(r[4])
            }

            var lev: Double? = nil
            if r.count > 5, !r[5].isEmpty {
                lev = Double(r[5].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines))
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

    private static func parseDate(_ str: String) -> Date? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let isoFormatter = ISO8601DateFormatter()
        if let d = isoFormatter.date(from: trimmed) { return d }

        let formats = [
            "yyyy/MM/dd",
            "yyyy-MM-dd",
            "dd/MM/yyyy",
            "MM/dd/yyyy",
            "dd-MMM-yyyy",
            "d-MMM-yyyy",
            "dd-MMM",
            "d-MMM"
        ]

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")

        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) {
                if !fmt.contains("yyyy") {
                    var components = Calendar.current.dateComponents([.month, .day], from: d)
                    components.year = Calendar.current.component(.year, from: Date())
                    return Calendar.current.date(from: components)
                }
                return d
            }
        }

        return nil
    }

    /// Parses raw batch text input (symbols, comma/space-separated, line-by-line, or 投資信託 names) into Holdings.
    static func parseBatchHoldings(from text: String) -> [Holding] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !lines.isEmpty else { return [] }

        var result: [Holding] = []

        for line in lines {
            let lowerLine = line.lowercased()
            if lowerLine.hasPrefix("symbol") || lowerLine.hasPrefix("ticker") || lowerLine.hasPrefix("code") || lowerLine.contains("portfolio") || lowerLine.hasPrefix("約定日") || lowerLine.hasPrefix("受渡日") {
                continue
            }

            var parts: [String] = []
            let isDelimiterSeparated = line.contains(",") || line.contains("\t") || line.contains(";")
            if line.contains(",") {
                parts = splitCSVLine(line, delimiter: ",")
            } else if line.contains("\t") {
                parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if line.contains(";") {
                parts = splitCSVLine(line, delimiter: ";")
            } else {
                parts = line.components(separatedBy: .whitespaces).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }

            guard !parts.isEmpty else { continue }

            // If the first token is a date (e.g., "2024/1/30" or "2024-01-30"), strip it so parts[0] is symbol/name
            let datePattern = #"^\d{4}[/-]\d{1,2}[/-]\d{1,2}$"#
            if parts.count >= 2 && parts[0].range(of: datePattern, options: .regularExpression) != nil {
                parts.removeFirst()
            }

            guard !parts.isEmpty else { continue }

            if isDelimiterSeparated {
                let secondNum: Double? = parts.count >= 2 ? Double(parts[1].replacingOccurrences(of: ",", with: "")) : nil
                if let qty = secondNum {
                    let rawSym = parts[0]
                    let code = resolveSymbolOrFundCode(rawSym)
                    if !code.isEmpty {
                        var price = 0.0
                        if parts.count >= 3 {
                            let priceStr = parts[2].replacingOccurrences(of: ",", with: "")
                            price = Double(priceStr) ?? 0.0
                        }
                        result.append(Holding(symbol: code, quantity: qty, avgPrice: price))
                    }
                } else {
                    for rawSym in parts {
                        let code = resolveSymbolOrFundCode(rawSym)
                        guard !code.isEmpty else { continue }
                        result.append(Holding(symbol: code, quantity: 1, avgPrice: 0))
                    }
                }
            } else {
                let count = parts.count
                let lastNum = count >= 1 ? Double(parts[count - 1].replacingOccurrences(of: ",", with: "")) : nil
                let secLastNum = count >= 2 ? Double(parts[count - 2].replacingOccurrences(of: ",", with: "")) : nil

                if count >= 3, let price = lastNum, let qty = secLastNum {
                    let rawSym = parts[0..<(count - 2)].joined(separator: " ")
                    let code = resolveSymbolOrFundCode(rawSym)
                    if !code.isEmpty {
                        result.append(Holding(symbol: code, quantity: qty, avgPrice: price))
                    }
                } else if count >= 2, let qty = lastNum {
                    let rawSym = parts[0..<(count - 1)].joined(separator: " ")
                    let code = resolveSymbolOrFundCode(rawSym)
                    if !code.isEmpty {
                        result.append(Holding(symbol: code, quantity: qty, avgPrice: 0))
                    }
                } else {
                    for rawSym in parts {
                        let code = resolveSymbolOrFundCode(rawSym)
                        guard !code.isEmpty else { continue }
                        result.append(Holding(symbol: code, quantity: 1, avgPrice: 0))
                    }
                }
            }
        }

        return result
    }

    private static func normalizeFundName(_ str: String) -> String {
        let clean = str.components(separatedBy: "(")[0]
                       .components(separatedBy: "（")[0]
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        let transformed = clean.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? clean
        return transformed.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "・", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "‐", with: "")
    }

    static func resolveJapaneseFundCode(from rawText: String) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let datePattern = #"^\d{4}[/-]\d{1,2}[/-]\d{1,2}\s*"#
        let cleanText = trimmed.replacingOccurrences(of: datePattern, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.isEmpty { return nil }

        let targetNorm = normalizeFundName(cleanText)

        // 1. Direct match on normalized keys
        for (k, v) in japaneseFundNameToCodeMap {
            if normalizeFundName(k) == targetNorm {
                return v
            }
        }

        // 2. Substring match sorted by key length DESCENDING so longer, specific keys match first!
        let sortedEntries = japaneseFundNameToCodeMap.sorted { $0.key.count > $1.key.count }
        for (k, v) in sortedEntries {
            let keyNorm = normalizeFundName(k)
            if !keyNorm.isEmpty && (targetNorm.contains(keyNorm) || keyNorm.contains(targetNorm)) {
                return v
            }
        }

        return nil
    }

    private static func resolveSymbolOrFundCode(_ input: String) -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        if let fundCode = resolveJapaneseFundCode(from: trimmed) {
            return fundCode
        }

        let datePattern = #"^\d{4}[/-]\d{1,2}[/-]\d{1,2}\s*"#
        trimmed = trimmed.replacingOccurrences(of: datePattern, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let upper = trimmed.uppercased()
        let jpStockRegex = "^[0-9]{3}[0-9A-Z]$"
        if upper.count == 4 && upper.range(of: jpStockRegex, options: .regularExpression) != nil {
            return upper + ".T"
        }

        return upper
    }
}
