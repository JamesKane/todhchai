// SPDX-License-Identifier: BSD-3-Clause

// Finds the @IPCLibrary enums in Swift source files, so idlc can describe
// them in C and Markdown.

import IPCModel
import SwiftParser
import SwiftSyntax

/// Everything idlc reads from a set of files.
public struct Interface {
  public var libraries: [LibraryModel] = []

  /// Every library's protocols, with the library each belongs to.
  public var protocols: [(library: LibraryModel, protocol: ProtocolModel)] {
    libraries.flatMap { l in l.protocols.map { (l, $0) } }
  }
}

/// A library idlc couldn't read, with where it is.
public struct IDLError: Error, CustomStringConvertible {
  public let description: String
}

/// Reads every @IPCLibrary enum in `sources` (path, contents).
public func scan(_ sources: [(path: String, text: String)]) throws(IDLError) -> Interface {
  var interface = Interface()
  for (path, text) in sources {
    let file = Parser.parse(source: text)
    for statement in file.statements {
      guard let e = statement.item.as(EnumDeclSyntax.self), let attribute = LibraryModel.attribute(of: e) else {
        continue
      }
      do {
        interface.libraries.append(try LibraryModel(e, attribute: attribute))
      } catch {
        throw IDLError(description: "\(path): library \(e.name.text): \(error)")
      }
    }
  }
  return interface
}
