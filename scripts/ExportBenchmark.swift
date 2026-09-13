import Foundation
import Metal
@main struct Benchmark {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--self-test") { try MetalPixelValidation.run(); return }
            if CommandLine.arguments.contains("--horizon-pixel-test") { try HorizonPixelValidation.run(); return }
            if let index = CommandLine.arguments.firstIndex(of: "--parameter-test"), index+1 < CommandLine.arguments.count {
                try await StabilizationParameterValidation.run(fixture: URL(fileURLWithPath: CommandLine.arguments[index+1])); return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--orientation-test"), index+1 < CommandLine.arguments.count {
                try await OrientationValidation.run(fixture: URL(fileURLWithPath: CommandLine.arguments[index+1])); return
            }
            guard CommandLine.arguments.count > 1 else { throw InputError("Supply a recording COPY directory or --self-test; output is replaced on success.") }
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            let output = try await StabilizationProcessor.process(directory: directory, options: StabilizationOptions.load(directory: directory), control: ProcessingControl()) { _ in }
            print(output.path)
        } catch { print("FAILED: \(error)"); exit(1) }
    }
}
