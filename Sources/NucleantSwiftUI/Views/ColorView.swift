//
//  ColorView.swift
//  NucleantSwiftUI
//
//  `Color` doubles as a view that fills whatever it is given — `Color.red` as a
//  background, `Color.clear` as a spacer that still takes space.
//

extension Color: View {
    public var body: Never {
        preconditionFailure("Color is a primitive view — its body is never evaluated.")
    }
}

extension Color: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let color = self
        return ViewNode(content: ShapeContent(
            makePath: { rect in
                var path = Path()
                path.addRect(rect)
                return path
            },
            fill: .color(color),
            stroke: nil,
            strokeStyle: StrokeStyle(),
            idealSize: nil
        ))
    }
}
