import SwiftUI

extension View {
    func toast(_ text: String, isPresented: Binding<Bool>, duration: TimeInterval = 1.0) -> some View {
        ZStack {
            self
            if isPresented.wrappedValue {
                Text(text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(radius: 4)
                    .transition(.opacity.combined(with: .scale))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                            withAnimation { isPresented.wrappedValue = false }
                        }
                    }
            }
        }
        .animation(.spring(duration: 0.25), value: isPresented.wrappedValue)
    }
}
