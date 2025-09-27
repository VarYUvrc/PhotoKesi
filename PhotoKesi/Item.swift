//
//  Item.swift
//  PhotoKesi
//
//  Created by VarYU on 2025/09/27.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
