import Foundation

/// 测试用的图库目录。用环境变量 `RAFHIF_TEST_DIR` 指定，**不写死路径** ——
/// 免得把开发者本机的目录结构带进公开仓库。
func testLibraryDir() -> URL {
    let env = ProcessInfo.processInfo.environment["RAFHIF_TEST_DIR"]
    guard let p = env, !p.isEmpty else {
        FileHandle.standardError.write(
            "请先设置环境变量 RAFHIF_TEST_DIR 指向含有 RAF/HIF 文件的目录\n"
                .data(using: .utf8)!)
        exit(1)
    }
    return URL(fileURLWithPath: p)
}

@main
struct MetaTest {
    static func main() {
        let dir = testLibraryDir().path
        let stems = CommandLine.arguments.count > 1
            ? Array(CommandLine.arguments.dropFirst())
            : ["DSCF0001"]
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
