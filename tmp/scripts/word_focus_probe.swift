// Offline word-level lens experiment. Coordinates are image pixels from top left.
// swift tmp/scripts/word_focus_probe.swift <image> <x> <y> [crop-width crop-height]
import Foundation
import ImageIO
import Vision

let args = CommandLine.arguments
guard args.count == 4 || args.count == 6,
      let x = Double(args[2]), let y = Double(args[3]) else {
    fputs("Usage: word_focus_probe.swift <image> <x> <y> [crop-width crop-height]\n", stderr)
    exit(2)
}
let cropWidth = args.count == 6 ? (Double(args[4]) ?? 320) : 320
let cropHeight = args.count == 6 ? (Double(args[5]) ?? 120) : 120
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Could not read image\n", stderr)
    exit(2)
}
let crop = CGRect(x: max(0, min(x - cropWidth / 2, Double(image.width) - cropWidth)),
                  y: max(0, min(y - cropHeight / 2, Double(image.height) - cropHeight)),
                  width: min(cropWidth, Double(image.width)),
                  height: min(cropHeight, Double(image.height))).integral
guard let cropped = image.cropping(to: crop) else { exit(2) }

let request = VNRecognizeTextRequest()
request.recognitionLevel = .fast
request.recognitionLanguages = ["en-US", "zh-Hans"]
request.usesLanguageCorrection = false
let start = CFAbsoluteTimeGetCurrent()
try VNImageRequestHandler(cgImage: cropped).perform([request])
let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000

struct Word {
    let text: String
    let box: CGRect
    let distance: CGFloat
}
var words: [Word] = []
let regex = try NSRegularExpression(pattern: "[A-Za-z]+(?:['’][A-Za-z]+)?")
for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let string = candidate.string
    let matches = regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    for match in matches {
        guard let range = Range(match.range, in: string),
              let wordBox = try? candidate.boundingBox(for: range) else { continue }
        let box = wordBox.boundingBox
        let frame = CGRect(x: crop.minX + box.minX * crop.width,
                           y: crop.minY + (1 - box.maxY) * crop.height,
                           width: box.width * crop.width,
                           height: box.height * crop.height)
        let dx = max(frame.minX - x, 0, x - frame.maxX)
        let dy = max(frame.minY - y, 0, y - frame.maxY)
        words.append(Word(text: String(string[range]), box: frame,
                          distance: hypot(dx, dy)))
    }
}
words.sort { $0.distance < $1.distance }
let chosen = words.first(where: { $0.distance <= 12 })
print(String(format: "crop=%.0f,%.0f %.0fx%.0f ocrMs=%.1f observations=%d words=%d",
             crop.minX, crop.minY, crop.width, crop.height, milliseconds,
             request.results?.count ?? 0, words.count))
if let chosen {
    print(String(format: "focused=%@ distance=%.1f box=%.0f,%.0f %.0fx%.0f",
                 chosen.text, chosen.distance, chosen.box.minX, chosen.box.minY,
                 chosen.box.width, chosen.box.height))
} else {
    print("focused=none")
}
