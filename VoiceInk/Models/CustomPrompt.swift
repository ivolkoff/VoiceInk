import Foundation
import SwiftUI

typealias PromptIcon = String

extension PromptIcon {
    static let allCases: [PromptIcon] = [
        // Document & Text
        "doc.text.fill",
        "textbox",
        "checkmark.seal.fill",
        
        // Communication
        "bubble.left.and.bubble.right.fill",
        "message.fill",
        "envelope.fill",
        
        // Professional
        "person.2.fill",
        "person.wave.2.fill",
        "briefcase.fill",
        
        // Technical
        "curlybraces",
        "terminal.fill",
        "gearshape.fill",
        
        // Content
        "doc.text.image.fill",
        "note",
        "book.fill",
        "bookmark.fill",
        "pencil.circle.fill",
        
        // Media & Creative
        "video.fill",
        "mic.fill",
        "music.note",
        "photo.fill",
        "paintbrush.fill",
        
        // Productivity & Time
        "clock.fill",
        "calendar",
        "list.bullet",
        "checkmark.circle.fill",
        "timer",
        "hourglass",
        "star.fill",
        "flag.fill",
        "tag.fill",
        "folder.fill",
        "paperclip",
        "tray.fill",
        "chart.bar.fill",
        "flame.fill",
        "target",
        "list.clipboard.fill",
        "brain.head.profile",
        "lightbulb.fill",
        "megaphone.fill",
        "heart.fill",
        "map.fill",
        "house.fill",
        "camera.fill",
        "figure.walk",
        "dumbbell.fill",
        "cart.fill",
        "creditcard.fill",
        "graduationcap.fill",
        "airplane",
        "leaf.fill",
        "hand.raised.fill",
        "hand.thumbsup.fill"
    ]
}

struct CustomPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let promptText: String
    var isActive: Bool
    let icon: PromptIcon
    let description: String?
    let isPredefined: Bool
    let triggerWords: [String]
    let useSystemInstructions: Bool
    
    init(
        id: UUID = UUID(),
        title: String,
        promptText: String,
        isActive: Bool = true,
        icon: PromptIcon = "doc.text.fill",
        description: String? = nil,
        isPredefined: Bool = false,
        triggerWords: [String] = [],
        useSystemInstructions: Bool = true
    ) {
        self.id = id
        self.title = title
        self.promptText = promptText
        self.isActive = isActive
        self.icon = icon
        self.description = description
        self.isPredefined = isPredefined
        self.triggerWords = triggerWords
        self.useSystemInstructions = useSystemInstructions
    }

    enum CodingKeys: String, CodingKey {
        case id, title, promptText, isActive, icon, description, isPredefined, triggerWords, useSystemInstructions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        promptText = try container.decode(String.self, forKey: .promptText)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        icon = try container.decode(PromptIcon.self, forKey: .icon)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isPredefined = try container.decode(Bool.self, forKey: .isPredefined)
        triggerWords = try container.decode([String].self, forKey: .triggerWords)
        useSystemInstructions = try container.decodeIfPresent(Bool.self, forKey: .useSystemInstructions) ?? true
    }
    
    var finalPromptText: String {
        if useSystemInstructions {
            return String(format: AIPrompts.customPromptTemplate, self.promptText)
        } else {
            return self.promptText
        }
    }
}

// MARK: - UI Extensions
extension CustomPrompt {
    func promptIcon(isSelected: Bool, isEnabled: Bool = true, onTap: @escaping () -> Void, onEdit: ((CustomPrompt) -> Void)? = nil, onDelete: ((CustomPrompt) -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            gradient: isSelected && isEnabled ?
                                Gradient(colors: [
                                    Color.accentColor.opacity(0.9),
                                    Color.accentColor.opacity(0.7)
                                ]) :
                                Gradient(colors: [
                                    Color(NSColor.controlBackgroundColor).opacity(isEnabled ? 0.95 : 0.5),
                                    Color(NSColor.controlBackgroundColor).opacity(isEnabled ? 0.85 : 0.4)
                                ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        isSelected && isEnabled ?
                                            Color.white.opacity(0.3) : Color.white.opacity(0.07),
                                        isSelected && isEnabled ?
                                            Color.white.opacity(0.1) : Color.white.opacity(0.03)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: isSelected && isEnabled ?
                            Color.accentColor.opacity(0.4) : Color.black.opacity(0.04),
                        radius: isSelected && isEnabled ? 10 : 4,
                        x: 0,
                        y: 3
                    )

                if !isEnabled {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.ultraThinMaterial)
                            .opacity(0.3)

                        Image(systemName: "slash.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }

                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                isSelected && isEnabled ?
                                    Color.white.opacity(0.15) : Color.white.opacity(0.04),
                                Color.clear
                            ]),
                            center: .center,
                            startRadius: 1,
                            endRadius: 25
                        )
                    )
                    .frame(width: 50, height: 50)
                    .offset(x: -15, y: -15)
                    .blur(radius: 2)

                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: isSelected && isEnabled ?
                                [Color.white, Color.white.opacity(0.9)] :
                                [Color.primary.opacity(isEnabled ? 0.9 : 0.35), Color.primary.opacity(isEnabled ? 0.7 : 0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(
                        color: isSelected && isEnabled ?
                            Color.white.opacity(0.5) : Color.clear,
                        radius: 4
                    )
                    .shadow(
                        color: isSelected && isEnabled ?
                            Color.accentColor.opacity(0.5) : Color.clear,
                        radius: 3
                    )
            }
            .frame(width: 48, height: 48)

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected && isEnabled ?
                        .primary : .secondary.opacity(isEnabled ? 0.8 : 0.4))
                    .lineLimit(1)
                    .frame(maxWidth: 70)

                ZStack(alignment: .center) {
                    if !triggerWords.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 7))
                                .foregroundColor(isSelected && isEnabled ? .accentColor.opacity(0.9) : .secondary.opacity(isEnabled ? 0.7 : 0.3))

                            if triggerWords.count == 1 {
                                Text("\"\(triggerWords[0])...\"")
                                    .font(.system(size: 8, weight: .regular))
                                    .foregroundColor(isSelected && isEnabled ? .primary.opacity(0.8) : .secondary.opacity(isEnabled ? 0.7 : 0.3))
                                    .lineLimit(1)
                            } else {
                                Text("\"\(triggerWords[0])...\" +\(triggerWords.count - 1)")
                                    .font(.system(size: 8, weight: .regular))
                                    .foregroundColor(isSelected && isEnabled ? .primary.opacity(0.8) : .secondary.opacity(isEnabled ? 0.7 : 0.3))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: 70)
                    }
                }
                .frame(height: 16)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .scaleEffect(isSelected && isEnabled ? 1.05 : 1.0)
        .onTapGesture(count: 2) {
            if let onEdit = onEdit {
                onEdit(self)
            }
        }
        .onTapGesture(count: 1) {
            onTap()
        }
        .contextMenu {
            if onEdit != nil || onDelete != nil {
                if let onEdit = onEdit {
                    Button {
                        onEdit(self)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }

                if let onDelete = onDelete, !isPredefined {
                    Button(role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Delete Prompt?")
                        alert.informativeText = String(localized: "Are you sure you want to delete '\(self.title)' prompt? This action cannot be undone.")
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: String(localized: "Delete"))
                        alert.addButton(withTitle: String(localized: "Cancel"))

                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            onDelete(self)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
    
    // Static method to create an "Add New" button with the same styling as the prompt icons
    static func addNewButton(action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            ZStack {
                // Dynamic background with blur effect - same styling as promptIcon
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(NSColor.controlBackgroundColor).opacity(0.95),
                                Color(NSColor.controlBackgroundColor).opacity(0.85)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.15),
                                        Color.white.opacity(0.05)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: Color.black.opacity(0.1),
                        radius: 6,
                        x: 0,
                        y: 3
                    )
                
                // Decorative background elements (same as in promptIcon)
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.08),
                                Color.clear
                            ]),
                            center: .center,
                            startRadius: 1,
                            endRadius: 25
                        )
                    )
                    .frame(width: 50, height: 50)
                    .offset(x: -15, y: -15)
                    .blur(radius: 2)
                
                // Plus icon with same styling as the normal icons
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 48, height: 48)
            
            // Text label with matching styling
            VStack(spacing: 2) {
                Text("Add New")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 70)
                
                // Empty space matching the trigger word area height
                Spacer()
                    .frame(height: 16)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}
