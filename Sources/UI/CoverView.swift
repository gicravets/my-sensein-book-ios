import SwiftUI

/// A book cover thumbnail with a generated fallback when no cover image exists.
struct CoverView: View {
    let book: Book
    var cornerRadius: CGFloat = 6

    var body: some View {
        ZStack {
            if let url = book.coverURL,
               let data = try? Data(contentsOf: url),
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Brand.purple, Brand.accent],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(book.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
