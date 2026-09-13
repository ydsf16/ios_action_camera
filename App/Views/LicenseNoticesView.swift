import SwiftUI

struct LicenseNoticesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(contents("THIRD_PARTY_NOTICES", extension: "md"))
                NavigationLink("第三方依赖许可全文") {
                    LicenseTextView(text: contents("THIRD_PARTY_LICENSES", extension: "txt"))
                        .navigationTitle("第三方许可")
                }
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

private struct LicenseTextView: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .caption1)
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
}
