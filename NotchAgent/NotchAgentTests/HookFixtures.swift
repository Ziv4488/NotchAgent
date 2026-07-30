//
//  HookFixtures.swift
//  NotchAgentTests
//
//  真实 hook payload 样本的加载。
//

import Foundation

/// 从磁盘读样本，**不走 test bundle 的资源**。
///
/// 这些 .json 放在测试源码旁边，Xcode 的同步文件夹会把它们当资源打包，
/// 但那条路要依赖构建配置；用 `#filePath` 直接定位源码目录更稳，
/// 而且样本改了立刻生效，不必等重新构建资源。
enum HookFixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/hooks")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: "\(name).json"))
    }

    static var allNames: [String] {
        get throws {
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".json") }
                .map { String($0.dropLast(5)) }
                .sorted()
        }
    }
}
