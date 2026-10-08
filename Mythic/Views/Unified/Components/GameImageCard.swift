//
//  GameImageCard.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 1/12/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import Shimmer

struct GameImageCard: View {
    var game: Game?
    var url: URL?
    @Binding var isImageEmpty: Bool
    
    var withBlur: Bool
    @AppStorage("gameImageCardBlur") private var imageCardBlur: Double = 0.0
    
    /// - Note: `game` must be passed as a parameter in order to include fallback image URLs.
    init(game: Game? = nil, url: URL?, isImageEmpty: Binding<Bool>, withBlur: Bool = true) {
        self.game = game
        self.url = url
        self._isImageEmpty = isImageEmpty
        self.withBlur = withBlur
    }
    
    var body: some View {
        GeometryReader { geometry in
            if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .onAppear {
                                withAnimation { isImageEmpty = true }
                            }
                            .foregroundStyle(.quinary)
                            .shimmering(
                                animation: .easeInOut(duration: 1)
                                    .repeatForever(autoreverses: false),
                                bandSize: 1
                            )
                    case .success(let image):
                        ZStack {
                            // blurred image as background
                            // save resources by only create this image if it'll be used for blur
                            if withBlur && (imageCardBlur > 0) {
                                // save resources by decreasing resolution scale of blurred image
                                let renderer: ImageRenderer = {
                                    let renderer = ImageRenderer(content: image)
                                    renderer.scale = 0.2
                                    return renderer
                                }()
                                
                                if let image = renderer.cgImage {
                                    Image(image, scale: 1, label: .init(""))
                                        .resizable()
                                        .blur(radius: imageCardBlur)
                                }
                            }
                            
                            image
                                .resizable()
                                .modifier(FadeInModifier())
                                .onAppear {
                                    withAnimation { isImageEmpty = false }
                                }
                        }
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width,
                               height: geometry.size.height)
                    case .failure(let error):
                        // The game's own icon beats an error message, when there is one.
                        Group {
                            if let game, game.isFallbackImageAvailable {
                                GameImageCard.FallbackGameImageCard(game: .constant(game), withBlur: withBlur)
                                    .padding()
                            } else {
                                ImageUnavailableView(title: "Unable to load the image.", reason: error.localizedDescription)
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onAppear {
                            withAnimation { isImageEmpty = true }
                        }
                    @unknown default:
                        ImageUnavailableView(title: "Unable to load the image.",
                                             reason: "Please check your internet connection, and try again.")
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .onAppear {
                                withAnimation { isImageEmpty = true }
                            }
                    }
                }
                .frame(width: geometry.size.width,
                       height: geometry.size.height)
            } else if let game, game.isFallbackImageAvailable {
                GameImageCard.FallbackGameImageCard(game: .constant(game), withBlur: withBlur)
                    .padding()
                    .frame(width: geometry.size.width,
                           height: geometry.size.height)
            } else {
                ImageUnavailableView(
                    title: "Image Unavailable",
                    reason: String(localized: "This game doesn't have an image that Mythic can display in this style.")
                )
                .frame(width: geometry.size.width,
                       height: geometry.size.height)
            }
        }
        .background(.quinary)
        .clipShape(.rect(cornerRadius: 20))
    }
}

/// A short, readable stand-in for an image that isn't there. The reason goes in the tooltip: system error
/// descriptions run to several lines, which is far too much for the space on a card.
private struct ImageUnavailableView: View {
    var title: LocalizedStringKey
    var reason: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.title2)

            Text(title)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .foregroundStyle(.secondary)
        .padding()
        .help(reason ?? "")
    }
}

extension GameImageCard {
    // TODO: implement for windows .exes by implementing PEFile
    struct FallbackGameImageCard: View {
        @Binding var game: Game
        @AppStorage("gameImageCardBlur") private var imageCardBlur: Double = 0.0
        var withBlur: Bool = true
        
        var body: some View {
            if case .installed(let location, _) = game.installationState {
                
                let image = Image(nsImage: NSWorkspace.shared.icon(forFile: location.path))
                
                ZStack {
                    // blurred image as background
                    // save resources by only create this image if it'll be used for blur
                    if withBlur && (imageCardBlur > 0) {
                        // save resources by decreasing resolution scale of blurred image
                        let renderer: ImageRenderer = {
                            let renderer = ImageRenderer(content: image)
                            renderer.scale = 0.2
                            return renderer
                        }()
                        
                        if let image = renderer.cgImage {
                            Image(image, scale: 1, label: .init(""))
                                .resizable()
                                .clipShape(.rect(cornerRadius: 20))
                                .blur(radius: imageCardBlur)
                        }
                    }
                    
                    image
                        .resizable()
                        .scaledToFit()
                        .modifier(FadeInModifier())
                }
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.windowBackground)
                    .shimmering(
                        animation: .easeInOut(duration: 1)
                            .repeatForever(autoreverses: false),
                        bandSize: 1
                    )
            }
        }
    }
}

#Preview {
    HStack {
        GameImageCard(game: placeholderGame(type: LocalGame.self) as Game,
                      url: placeholderGame(type: LocalGame.self).horizontalImageURL,
                      isImageEmpty: .constant(false),
                      withBlur: true)
        .aspectRatio(16/9, contentMode: .fill)
        
        GameImageCard(game: placeholderGame(type: Game.self),
                      url: placeholderGame(type: Game.self).verticalImageURL,
                      isImageEmpty: .constant(false),
                      withBlur: true)
        .aspectRatio(3/4, contentMode: .fill)
    }
    .aspectRatio(contentMode: .fit)
    .padding()
}
