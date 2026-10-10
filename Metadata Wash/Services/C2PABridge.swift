//
//  C2PABridge.swift
//  Metadata Wash
//
//  Imports only the C2PA module so its `Stream` type is not shadowed by
//  Foundation's `Stream` (NSStream); the module and its main enum share a name,
//  which makes `C2PA.Stream` unusable elsewhere.
//

import C2PA

typealias C2PAStream = Stream
