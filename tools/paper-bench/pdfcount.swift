import PDFKit
// usage: pdfcount <pdf>   prints the number of pages
guard CommandLine.arguments.count > 1, let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else { exit(1) }
print(doc.pageCount)
