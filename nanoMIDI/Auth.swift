//
//  Auth.swift
//  nanoMIDI
//
//  Created by KrataiB on 23/8/2568 BE.
//

import Foundation
import Combine
import SwiftData

class AuthViewModel: ObservableObject {
    @Published var isSignedIn: Bool = true  // จะใช้หรือไม่ใช้ก็ได้ ไม่กระทบการบันทึก

    /// บันทึกโน้ตลง SwiftData
    func saveNote(_ text: String, in context: ModelContext) {
        // กันเคสเว้นว่างล้วน
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let memo = Memo(text: trimmed)
        context.insert(memo)

        // ถ้าต้องการบังคับเขียนลงดิสก์ทันที:
        // try? context.save()
    }
}
