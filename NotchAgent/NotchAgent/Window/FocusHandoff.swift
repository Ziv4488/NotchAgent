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
///
/// **判断依据是「有没有别人抢过前台」这个事件，不是收起那一刻的 `NSApp.isActive`。**
/// 试过后者：岛是 `.nonactivatingPanel`，点它不激活 app，本以为
/// 「收起时我们不是前台」就等于「用户切走了」—— 实机上不成立，焦点照样被弹回去。
/// 一个已经发生过的事件比一个当下的快照可靠得多。
struct FocusHandoff {
    private var previousApp: NSRunningApplication?

    /// 展开时记下当前前台 app。
    mutating func remember(_ app: NSRunningApplication?) {
        previousApp = app
    }

    /// 记录空着的时候才记 —— 用户在展开期间从别的 app 点回岛上时用。
    ///
    /// 那条路上记录刚被 `someoneElseTookOver()` 作废（他切走过一次），
    /// 而他现在又主动把焦点交给了岛：收起时该还给他**刚才那个** app。
    /// 不覆盖已有记录：展开那一刻记下的那个才是这一轮的起点。
    mutating func rememberIfEmpty(_ app: NSRunningApplication?) {
        guard previousApp == nil else { return }
        previousApp = app
    }

    /// 展开期间**别人**成了前台。
    ///
    /// 那是用户自己的选择，我们的记录当场作废 —— 收起岛不该顺手把它撤销。
    mutating func someoneElseTookOver() {
        previousApp = nil
    }

    /// 收起时该激活谁。**nil 表示谁都别动。**
    ///
    /// 无论还不还，记录都清掉：它只对这一次展开有效。留着的话，
    /// 下一次「不该还」的收起会把上一次的记录翻出来用，bug 换个时机重现。
    mutating func appToRestore() -> NSRunningApplication? {
        defer { previousApp = nil }
        return previousApp
    }
}
