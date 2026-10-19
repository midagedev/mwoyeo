// E3: does MLComputeUnits.cpuAndGPU stay off the Neural Engine? usage: e3 <model.mlmodel> <cpuAndGPU|all|cpuOnly> [predictions]
import CoreML
import Foundation

func stamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: e3 <model.mlmodel> <cpuAndGPU|all|cpuOnly> [n]"); exit(2) }
let units: MLComputeUnits = ["cpuAndGPU": .cpuAndGPU, "all": .all, "cpuOnly": .cpuOnly, "cpuAndNeuralEngine": .cpuAndNeuralEngine][args[2]] ?? .all
let n = args.count > 3 ? Int(args[3]) ?? 20 : 20
print("pid=\(getpid()) units=\(args[2]) begin=\(stamp())")
let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: args[1]))
let cfg = MLModelConfiguration(); cfg.computeUnits = units
let t0 = Date()
let model = try MLModel(contentsOf: compiled, configuration: cfg)
print("loaded in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
let x = try MLMultiArray(shape: [32, 64, 64], dataType: .float32)
for i in 0..<x.count { x[i] = NSNumber(value: Float(i % 17) / 17) }
let input = try MLDictionaryFeatureProvider(dictionary: ["x": x])
for i in 1...n {
    let t = Date()
    let out = try model.prediction(from: input)
    if i == 1 || i == n { print("prediction \(i): \(Int(Date().timeIntervalSince(t) * 1000)) ms, y.count=\(out.featureValue(for: "y")?.multiArrayValue?.count ?? -1)") }
}
print("pid=\(getpid()) units=\(args[2]) end=\(stamp())")
