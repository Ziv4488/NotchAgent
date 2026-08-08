//
//  IslandBody.swift
//  NotchAgent
//
//  岛的填充轮廓，就是 `NotchShape`。
//

import SwiftUI

struct IslandBody: Shape {
    var bottomRadius: CGFloat
    var invertedRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        NotchShape(bottomRadius: bottomRadius, invertedRadius: invertedRadius)
            .path(in: rect)
    }
}
