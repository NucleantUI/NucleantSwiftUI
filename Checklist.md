# Progress of Api compared to research/SwiftUI-api

## App & Scenes
- [x] App
- [x] Scene / SceneBuilder
- [x] WindowGroup
- [ ] Window
- [ ] Settings
- [ ] DocumentGroup
- [x] Commands / CommandsBuilder
- [x] CommandMenu
- [x] CommandGroup
- [x] .commands
- [x] .keyboardShortcut
- [ ] openWindow / dismissWindow

## View core
- [x] View
- [x] ViewBuilder
- [x] ViewModifier / ModifiedContent / .modifier
- [x] TupleView
- [x] EmptyView
- [x] AnyView
- [x] Group
- [x] ForEach
- [ ] PreferenceKey / .preference / .onPreferenceChange
- [ ] Layout protocol
- [ ] EquatableView / .equatable

## State & data flow
- [x] @State
- [x] @Binding
- [x] @Environment / EnvironmentKey / EnvironmentValues
- [x] .environment
- [x] @Observable models
- [x] @Bindable
- [x] DynamicProperty
- [ ] @FocusState
- [ ] @AppStorage / @SceneStorage
- [ ] .onChange
- [ ] .task

## Layout containers
- [x] HStack
- [x] VStack
- [x] ZStack
- [x] Spacer
- [x] Divider
- [x] ScrollView
- [ ] ScrollViewReader
- [ ] LazyVStack / LazyHStack
- [ ] LazyVGrid / LazyHGrid
- [ ] Grid / GridRow
- [ ] GeometryReader
- [ ] ViewThatFits

## Text & images
- [x] Text
- [x] Text .font / .fontWeight / .bold / .italic
- [x] Text .lineLimit / .multilineTextAlignment
- [ ] AttributedString / Text concatenation
- [x] Font
- [x] Image
- [x] .resizable / .aspectRatio / .scaledToFit / .scaledToFill
- [ ] Image("name") / Image(systemName:)
- [ ] AsyncImage
- [ ] Label

## Controls
- [x] Button
- [ ] .buttonStyle
- [x] Menu
- [x] DisclosureGroup / DisclosureGroupStyle
- [ ] Toggle
- [ ] Slider
- [ ] Stepper
- [ ] Picker
- [ ] TextField / SecureField / TextEditor
- [ ] DatePicker / ColorPicker
- [ ] ProgressView / Gauge
- [ ] Link
- [ ] ShareLink

## Collections
- [ ] List
- [ ] Section
- [ ] Form
- [ ] OutlineGroup
- [ ] Table

## Navigation & presentation
- [x] NavigationStack
- [x] NavigationLink
- [x] .navigationTitle
- [x] .navigationDestination(for:) / NavigationPath / NavigationLink(value:)
- [ ] .navigationDestination(isPresented:) / (item:)
- [ ] NavigationSplitView
- [ ] TabView
- [ ] .toolbar
- [x] .popover
- [x] .contextMenu
- [ ] .sheet / .fullScreenCover
- [ ] .alert / .confirmationDialog
- [ ] .inspector

## Shapes & drawing
- [x] Shape
- [x] Rectangle / RoundedRectangle / Circle / Ellipse / Capsule
- [x] Path
- [ ] UnevenRoundedRectangle
- [x] .fill / .stroke / StrokeStyle
- [ ] .trim / .inset / .strokeBorder
- [x] Color
- [x] Gradient
- [ ] AngularGradient
- [ ] LinearGradient / RadialGradient as views
- [ ] Material
- [ ] Canvas / GraphicsContext
- [x] .drawingGroup
- [x] Shader / ShaderLibrary / .shader

## Layout modifiers
- [x] .frame
- [x] .padding
- [x] .offset
- [ ] .position
- [ ] .fixedSize
- [ ] .layoutPriority
- [ ] .zIndex
- [ ] .ignoresSafeArea / .safeAreaInset
- [ ] .containerRelativeFrame

## Appearance modifiers
- [x] .background
- [x] .overlay
- [x] .border
- [x] .opacity
- [x] .hidden
- [x] .foregroundColor / .foregroundStyle
- [x] .tint
- [x] .colorScheme
- [x] .clipped / .clipShape / .cornerRadius
- [x] .rotationEffect / .scaleEffect
- [ ] .shadow
- [ ] .blur
- [ ] .blendMode / .compositingGroup / .mask

## Interaction
- [x] .onTapGesture
- [x] DragGesture / .gesture
- [ ] TapGesture / LongPressGesture / MagnifyGesture / RotateGesture
- [ ] .simultaneousGesture / .highPriorityGesture
- [x] .onHover
- [x] .disabled
- [x] .draggable / .dropDestination / Transferable / UTType
- [ ] .allowsHitTesting / .contentShape
- [ ] .focused / .onSubmit / .onKeyPress
- [x] .onAppear
- [x] .onDisappear

## Animation
- [x] withAnimation
- [x] .animation
- [x] Animation curves / spring
- [x] .transition
- [ ] matchedGeometryEffect
- [x] TimelineView

## Accessibility
- [ ] .accessibilityLabel / .accessibilityHint / etc.
