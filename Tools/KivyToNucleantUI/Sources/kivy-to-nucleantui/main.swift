//
//  main.swift
//  kivy-to-nucleantui
//
//  kivy-to-nucleantui [file.kv]   — reads stdin without a file, prints Swift.
//

import Foundation
import KivyToNucleantUI

let arguments = CommandLine.arguments.dropFirst()
let source: String
if let path = arguments.first {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("kivy-to-nucleantui: cannot read \(path)\n".utf8))
        exit(1)
    }
    source = text
} else {
    source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

print(KivyToNucleantUI().convert(source), terminator: "")
