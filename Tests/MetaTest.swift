import Foundation
@main
struct MetaTest {
    static func main() {
        let dir = "__TEST_DIR__"
        let stems = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : ["DSCF0001"]
        for stem in stems {
            let raf = URL(fileURLWithPath: "\(dir)/\(stem).RAF")
            let hif = URL(fileURLWithPath: "\(dir)/\(stem).HIF")
            print("═══ \(stem) ═══")
            let secs = MetaReader.sections(left: raf, right: hif, leftName: "RAF", rightName: "HIF")
            for s in secs {
                print(" [\(s.title)]")
                for r in s.rows {
                    print(String(format: "   %-12@ %-26@ %-26@ %@", r.label as NSString,
                                 r.left as NSString, r.right as NSString,
                                 (r.differs ? "  ← 不同" : "") as NSString))
                }
            }
            let n = secs.flatMap { $0.rows }.filter { $0.differs }.count
            print("   → 共 \(secs.flatMap { $0.rows }.count) 项，其中 \(n) 项不同\n")
        }
    }
}
