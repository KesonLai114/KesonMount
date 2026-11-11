// makepdf —— 把排版好的 HTML 打成 A4 PDF
// 用法： swiftc -O -framework AppKit -framework WebKit -framework PDFKit tools/makepdf.swift -o /tmp/makepdf
//        /tmp/makepdf 输入.html 输出.pdf
//
// 思路：WKWebView 渲染成整页（一张超长页），再按 A4 高度逐页裁切重排。
// 不用 NSPrintOperation 是因为它在无窗口/沙盒环境里会被打印子系统拦住。

import AppKit
import WebKit
import CoreGraphics
import PDFKit

let CSS_W: CGFloat = 794          // A4 宽 @96dpi
let CSS_H: CGFloat = 1122         // A4 高 @96dpi（比 1123 少 1px，留舍入余量）
let PT_PER_PX: CGFloat = 72.0 / 96.0
/// createPDF 单页高度上限是 14400pt，超了会被整体压扁（页数就乱了）。
/// 内容太长时先缩小渲染、切完页再放大回去——PDF 是矢量的，放大不掉画质。
let MAX_SRC_H: CGFloat = 13800
/// 分批渲染时单批的 CSS 高度上限。createPDF 是 1pt = 1 CSS px，单页最高 14400pt，
/// 超过会被压扁（内容被缩掉、页数对不上），所以每批不超过 14000px（≈12 页）。
let MAX_CHUNK_PX: CGFloat = 14000

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: makepdf <输入.html> <输出.pdf>\n".data(using: .utf8)!)
    exit(64)
}
let inURL = URL(fileURLWithPath: args[1]).standardizedFileURL
let outURL = URL(fileURLWithPath: args[2]).standardizedFileURL

guard FileManager.default.fileExists(atPath: inURL.path) else {
    FileHandle.standardError.write("找不到输入文件: \(inURL.path)\n".data(using: .utf8)!)
    exit(66)
}

final class Maker: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    let out: URL
    var finished = false
    /// 渲染缩放（内容超高时 < 1）
    var zoom: CGFloat = 1
    /// 每页在文档里的位置：[顶部 CSS px, 高度 CSS px]
    var pages: [[Int]] = []
    /// 输出 PDF 上下文（分批渲染时共用）
    var outCtx: CGContext?
    /// 分批区间 [起, 止)
    var chunks: [(Int, Int)] = []
    var currentChunk = 0
    /// 当前批次里可见页的位置
    var visiblePages: [[Int]] = []
    var rendered = 0

    init(inURL: URL, out: URL) {
        self.out = out
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: CSS_W, height: CSS_H),
                            configuration: WKWebViewConfiguration())
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: CSS_W, height: CSS_H),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        window.orderBack(nil)
        webView.navigationDelegate = self
        webView.loadFileURL(inURL, allowingReadAccessTo: inURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等图片解码、字体就位
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.render() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("加载失败: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(70)
    }

    func render() {
        guard !finished else { return }
        finished = true

        // 只量高度、不做缩放：pageZoom < 1 会触发 WebKit 的「最小字号」限制，
        // 把 12.8px 的正文强行抬到 9/zoom（≈18px），字号层级全毁、页面被顶爆。
        // 所以缩放一律不用，内容太高就分批出 PDF（见 beginChunks）。
        webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in
            let total = CGFloat((value as? NSNumber)?.doubleValue ?? 0)
            print("文档高 \(Int(total))px（不缩放渲染）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.measurePages() }
        }
    }

    /// 读出每一页在文档里的真实位置（CSS px，从顶部算）。
    /// 不靠「每页固定 1122px」推算——页边距、页尾留白都会让推算偏掉，
    /// 一偏就整本错页（踩过）。
    func measurePages() {
        let js = """
        JSON.stringify(Array.from(document.querySelectorAll('.cover, .page')).map(function(e){
          var r = e.getBoundingClientRect();
          return [Math.round(r.top + window.scrollY), Math.round(r.height)];
        }))
        """
        webView.evaluateJavaScript(js) { value, _ in
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[Int]] else {
                FileHandle.standardError.write("读取页面位置失败\n".data(using: .utf8)!)
                exit(74)
            }
            self.pages = list
            print("检测到 \(list.count) 页，前 3 页位置: \(list.prefix(3))")
            let dump = ProcessInfo.processInfo.environment["MAKEPDF_DUMP"] == "1"
            self.checkOverflow {
                if dump { self.dumpLayout { self.beginChunks() } } else { self.beginChunks() }
            }
        }
    }

    /// 检查每一页的正文有没有压到页脚 / 被页底裁掉。
    ///
    /// `.page` 是固定 1122px 高 + `overflow:hidden`，正文一多就会顶到页脚
    /// （页脚是绝对定位，不会被撑开），PDF 里表现成「文字被盖住」。
    /// 这里量出每页正文最下沿，超过安全线就报警——比一页页肉眼翻可靠。
    /// MAKEPDF_DUMP=1 时打印每页每个直接子元素的高度，用来定位是谁把正文顶出页面
    func dumpLayout(_ done: @escaping () -> Void) {
        let js = """
        (function(){
          var out = [];
          Array.from(document.querySelectorAll('.cover, .page')).forEach(function(e, pi){
            var pr = e.getBoundingClientRect();
            var kids = [];
            Array.from(e.children).forEach(function(c){
              var cs = getComputedStyle(c);
              if (cs.position === 'absolute' || cs.position === 'fixed') return;
              var r = c.getBoundingClientRect();
              if (r.height < 1) return;
              var cls = c.className || c.tagName.toLowerCase();
              var txt = (c.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 18);
              kids.push(cls + '[' + Math.round(r.height) + '|底' + Math.round(r.bottom - pr.top) + '] fs=' + cs.fontSize + ' lh=' + cs.lineHeight + ' ' + txt);
            });
            out.push('p' + (pi + 1) + '\\n    ' + kids.join('\\n    '));
          });
          return out.join('\\n');
        })()
        """
        webView.evaluateJavaScript(js) { value, _ in
            if let s = value as? String { print(s) }
            done()
        }
    }

    func checkOverflow(_ done: @escaping () -> Void) {
        let safeBottom = CSS_H - 56          // 下内边距上沿，正文越过它就算压边
        let js = """
        JSON.stringify(Array.from(document.querySelectorAll('.cover, .page')).map(function(e){
          var pr = e.getBoundingClientRect();
          var maxBottom = 0;
          Array.from(e.children).forEach(function(c){
            var cs = getComputedStyle(c);
            if (cs.position === 'absolute' || cs.position === 'fixed') return;
            var r = c.getBoundingClientRect();
            if (r.height < 1) return;
            if (r.bottom - pr.top > maxBottom) maxBottom = r.bottom - pr.top;
          });
          return Math.round(maxBottom);
        }))
        """
        webView.evaluateJavaScript(js) { value, _ in
            defer { done() }
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let bottoms = try? JSONSerialization.jsonObject(with: data) as? [Int] else { return }
            var bad: [String] = []
            var rows: [String] = []
            for (i, bottom) in bottoms.enumerated() {
                let over = bottom - Int(safeBottom)
                if over > 0 {
                    // 第 1 个是封面，页码从 1 开始算它就是第 1 页
                    bad.append("第 \(i + 1) 页超出 \(over)px（正文底 \(bottom)，安全线 \(Int(safeBottom))）")
                    rows.append("p\(i + 1) ✗+\(over)")
                } else {
                    rows.append("p\(i + 1) 余\(-over)")
                }
            }
            print("每页余量：" + rows.joined(separator: "  "))
            if bad.isEmpty {
                print("排版检查：\(bottoms.count) 页全部在安全线内 ✅")
            } else {
                print("排版检查：⚠️ 有 \(bad.count) 页正文压到页脚，会被裁掉：")
                bad.forEach { print("   " + $0) }
            }
        }
    }

    // MARK: - 分批出 PDF
    //
    // createPDF 单页最高 14400pt（≈19200 CSS px），25 页文档有 28000px，
    // 一张装不下。以前是靠 pageZoom 整体缩小，但那会踩到 WebKit 的最小字号
    // 限制（9px），把正文字号统一抬到 18px，字号层级全乱。
    // 现在改成：一批只让一部分页参与排版（其余 display:none），逐批 createPDF，
    // 再统一裁成 A4 追加进同一个输出文件。全程 zoom=1，版式与 HTML 完全一致。

    func beginChunks() {
        var ranges: [(Int, Int)] = []          // [起, 止)
        var start = 0
        var acc: CGFloat = 0
        for (i, item) in pages.enumerated() {
            let h = CGFloat(item.count >= 2 ? item[1] : Int(CSS_H))
            if acc + h > MAX_CHUNK_PX && i > start {
                ranges.append((start, i)); start = i; acc = 0
            }
            acc += h
        }
        if start < pages.count { ranges.append((start, pages.count)) }

        var mediaBox = CGRect(x: 0, y: 0, width: CSS_W * PT_PER_PX, height: CSS_H * PT_PER_PX)
        guard let ctx = CGContext(out as CFURL, mediaBox: &mediaBox, nil) else {
            FileHandle.standardError.write("无法创建输出 PDF\n".data(using: .utf8)!)
            exit(73)
        }
        outCtx = ctx
        chunks = ranges
        let label = ranges.map { "\($0.0 + 1)–\($0.1)" }.joined(separator: " / ")
        print("共 \(pages.count) 页，分 \(ranges.count) 批渲染：\(label)")
        renderChunk(0)
    }

    func renderChunk(_ idx: Int) {
        currentChunk = idx
        if idx >= chunks.count { finishOutput(); return }
        let (a, b) = chunks[idx]
        // 只保留本批的页，其余隐藏（display:none 不占位，文档高度随之变短）
        let js = """
        (function(){
          Array.from(document.querySelectorAll('.cover, .page')).forEach(function(e, i){
            e.style.display = (i >= \(a) && i < \(b)) ? '' : 'none';
          });
          return 1;
        })()
        """
        webView.evaluateJavaScript(js) { _, _ in
            // 等一帧重排，再量本批各页的新位置
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.measureVisible { self.forceDecodeImages { self.exportChunk() } }
            }
        }
    }

    /// 强制把本批可见的图片解码完再出 PDF。
    /// 之前出现过整页截图在 PDF 里是白框：页面刚被 display:none 隐藏又显示回来时，
    /// 图片还没解码就 createPDF 了。这里等 decode() 全部完成再继续。
    func forceDecodeImages(_ done: @escaping () -> Void) {
        let js = """
        (function(){
          window.__imgReady = false;
          var imgs = Array.from(document.images);
          var jobs = imgs.map(function(im){
            if (im.complete && im.naturalWidth > 0) return Promise.resolve();
            return im.decode ? im.decode().catch(function(){}) : Promise.resolve();
          });
          Promise.all(jobs).then(function(){ window.__imgReady = true; });
          return imgs.length;
        })()
        """
        webView.evaluateJavaScript(js) { _, _ in
            self.pollImages(0, done)
        }
    }

    func pollImages(_ n: Int, _ done: @escaping () -> Void) {
        if n > 30 { done(); return }
        webView.evaluateJavaScript("window.__imgReady === true") { v, _ in
            if (v as? Bool) == true {
                // 再给一帧让解码结果真正画上去
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { done() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.pollImages(n + 1, done) }
            }
        }
    }

    /// 量出本批可见页在文档里的位置（隐藏后第一页顶在 0）
    func measureVisible(_ done: @escaping () -> Void) {
        let js = """
        JSON.stringify(Array.from(document.querySelectorAll('.cover, .page')).filter(function(e){
          return getComputedStyle(e).display !== 'none';
        }).map(function(e){
          var r = e.getBoundingClientRect();
          return [Math.round(r.top + window.scrollY), Math.round(r.height)];
        }))
        """
        webView.evaluateJavaScript(js) { value, _ in
            if let json = value as? String,
               let data = json.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[Int]] {
                self.visiblePages = list
            }
            done()
        }
    }

    func exportChunk() {
        webView.createPDF(configuration: WKPDFConfiguration()) { result in
            switch result {
            case .failure(let err):
                FileHandle.standardError.write("渲染失败: \(err.localizedDescription)\n".data(using: .utf8)!)
                exit(71)
            case .success(let data):
                self.drawChunk(data)
            }
        }
    }

    /// 把一批的整页 PDF 按每页真实位置切成 A4，追加到输出文件
    func drawChunk(_ data: Data) {
        guard let provider = CGDataProvider(data: data as CFData),
              let srcDoc = CGPDFDocument(provider),
              let srcPage = srcDoc.page(at: 1) else {
            FileHandle.standardError.write("无法解析渲染结果\n".data(using: .utf8)!)
            exit(72)
        }
        guard let ctx = outCtx else {
            FileHandle.standardError.write("输出上下文已失效\n".data(using: .utf8)!)
            exit(73)
        }

        let srcRect = srcPage.getBoxRect(.mediaBox)
        let pageW = CSS_W * PT_PER_PX
        let pageH = CSS_H * PT_PER_PX
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)

        // 本批 CSS px → 源 PDF pt 的比例（正常是 0.75，实测更保险）
        let chunkH = CGFloat(visiblePages.reduce(0) { $0 + ($1.count >= 2 ? $1[1] : 0) })
        let pxToPt = chunkH > 0 ? srcRect.height / chunkH : PT_PER_PX
        print("  批次 \(currentChunk + 1)：源 \(String(format: "%.1f×%.1f", srcRect.width, srcRect.height))pt，本批高 \(Int(chunkH))px，pxToPt=\(String(format: "%.4f", pxToPt))，页数 \(visiblePages.count)")

        for item in visiblePages where item.count >= 2 {
            let top = CGFloat(item[0])
            let h = CGFloat(item[1])
            // 这一页在源 PDF 里的下沿（源 PDF 坐标从底算）
            let yBottom = srcRect.height - (top + h) * pxToPt
            // 把 h 高的那一段放大到 A4 页高
            let k = pageH / (h * pxToPt)
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.clip(to: mediaBox)
            ctx.translateBy(x: 0, y: -k * yBottom)
            ctx.scaleBy(x: k, y: k)
            ctx.drawPDFPage(srcPage)
            ctx.restoreGState()
            ctx.endPDFPage()
        }

        rendered += visiblePages.count
        renderChunk(currentChunk + 1)
    }

    func finishOutput() {
        outCtx?.closePDF()
        outCtx = nil
        let pageW = CSS_W * PT_PER_PX
        let pageH = CSS_H * PT_PER_PX
        if let doc = PDFDocument(url: out) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            print("页数: \(doc.pageCount)（预期 \(pages.count)）")
            print("单页尺寸: \(String(format: "%.1f × %.1f pt（A4）", pageW, pageH))")
            print("文件大小: \(String(format: "%.0f KB", Double(bytes) / 1024))")
        }
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let maker = Maker(inURL: inURL, out: outURL)
withExtendedLifetime(maker) {
    RunLoop.main.run(until: Date().addingTimeInterval(30))
}
FileHandle.standardError.write("超时\n".data(using: .utf8)!)
exit(2)
