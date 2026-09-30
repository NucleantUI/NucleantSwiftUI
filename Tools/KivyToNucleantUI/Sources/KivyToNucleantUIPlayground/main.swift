//
//  main.swift
//  KivyToNucleantUIPlayground
//
//  The converter, compiled to WebAssembly for the documentation's playground
//  page. It adds one function to the page:
//
//      kivyToNucleantUI(source, { comments: true, app: true, title: "…" })
//
//  and the page (Playground/index.html) does the editing, the examples and
//  the share link around it.
//

import JavaScriptKit
import KivyToNucleantUI

nonisolated(unsafe) let convert = JSClosure { arguments in
    let source = arguments.first?.string ?? ""
    var options = KivyToNucleantUI.Options()
    if arguments.count > 1, let settings = arguments[1].object {
        if let comments = settings.comments.boolean { options.includeComments = comments }
        if let app = settings.app.boolean { options.generateApp = app }
        if let title = settings.title.string, !title.isEmpty { options.windowTitle = title }
    }
    return .string(KivyToNucleantUI(options: options).convert(source))
}

JSObject.global.kivyToNucleantUI = .object(convert)
