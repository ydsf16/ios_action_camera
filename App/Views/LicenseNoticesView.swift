import SwiftUI

struct LicenseNoticesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(contents("THIRD_PARTY_NOTICES", extension: "md"))
                Text(contents("LICENSE", extension: nil))
            }.font(.caption).textSelection(.enabled).padding()
        }.background(AppTheme.background).foregroundStyle(.primary).navigationTitle("开源许可")
    }
    private func contents(_ name: String, extension ext: String?) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "许可文件加载失败，请查看项目源代码中的 LICENSE。" }
        return text
    }
}
