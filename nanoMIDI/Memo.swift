//
//  Memo.swift
//  nanoMIDI
//
//  Created by KrataiB on 23/8/2568 BE.
//

import Foundation
import SwiftData

@Model
final class Memo {
    var text: String
    var createdAt: Date
    var updatedAt: Date

    init(text: String = "", createdAt: Date = .now, updatedAt: Date = .now) {
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
