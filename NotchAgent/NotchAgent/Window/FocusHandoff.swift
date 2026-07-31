//
//  FocusHandoff.swift
//  NotchAgent
//
//  展开抢焦点、收起还焦点的那条规则。
//

import AppKit

/// 岛展开时抢走了谁的焦点，收起时又该还给谁。
///
/// 单独抽出来是因为这里有一条**很容易写错**的判断，值得能离线测：
/// 记下的是展开那一刻的前台 app，可用户完全可能在展开期间自己点去了别的窗口。
/// 无条件还回去 = 把他刚选好的窗口抢走。
struct FocusHandoff {
    private var previousApp: NSRunningApplication?

    /// 展开时记下当前前台 app。
    mutating func remember(_ app: NSRunningApplication?) {
        previousApp = app
    }

    /// 收起时该激活谁。**nil 表示谁都别动。**
    ///
    /// 岛已经不是前台，说明焦点在展开期间被用户自己交给别人了 ——
    /// 那是他的选择，收起岛不该顺手把它撤销。
    /// 无论还不还，记录都清掉：它只对这一次展开有效。
    mutating func appToRestore(islandIsFrontmost: Bool) -> NSRunningApplication? {
        defer { previousApp = nil }
        return islandIsFrontmost ? previousApp : nil
    }
}
