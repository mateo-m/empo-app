import SwiftUI

struct GameLoadingView: View {
    let game: GameEntry

    var body: some View {
        ZStack {
            artworkBackground

            VStack(spacing: 16) {
                Text(game.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .shadow(radius: 4)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.2)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var artworkBackground: some View {
        if let path = game.artworkPath, let uiImage = UIImage(contentsOfFile: path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
                .blur(radius: 20)
                .overlay(Color.black.opacity(0.5))
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}
