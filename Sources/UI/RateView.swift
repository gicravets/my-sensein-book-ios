import SwiftUI
import StoreKit

/// "Оценить" — playful rate screen, eBoox-style.
struct RateView: View {
    @State private var rating = 0
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.requestReview) private var requestReview

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        ZStack {
            theme.headerGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer().frame(height: 80)
                Text("Нравится Books?")
                    .font(.title.weight(.semibold)).foregroundStyle(.white)

                Text("🐱")
                    .font(.system(size: 110))
                    .padding(.top, 30)

                ZStack {
                    Brand.surface
                        .clipShape(.rect(topLeadingRadius: 140, topTrailingRadius: 140))
                        .ignoresSafeArea(edges: .bottom)
                    VStack(spacing: 24) {
                        Text("Дай пять!").font(.title2.weight(.bold)).foregroundStyle(.white)
                        HStack(spacing: 14) {
                            ForEach(1...5, id: \.self) { i in
                                Image(systemName: i <= rating ? "star.fill" : "star")
                                    .font(.system(size: 34))
                                    .foregroundStyle(i <= rating ? Brand.accent : .white.opacity(0.4))
                                    .onTapGesture { rating = i }
                            }
                        }
                        Button {
                            requestReview()
                        } label: {
                            Text("Оценить")
                                .font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(Brand.purple).clipShape(Capsule())
                        }
                        .padding(.horizontal, 40)
                        Spacer()
                        Text("Версия: \(version)")
                            .font(.footnote).foregroundStyle(.white.opacity(0.4))
                            .padding(.bottom, 110)
                    }
                    .padding(.top, 50)
                }
                .padding(.top, 20)
            }
        }
    }
}
